// ============================================================================
//  Traiectus.cpp — Windows 端统一入口（托盘）
// ----------------------------------------------------------------------------
//  作用：一个手动入口。双击后
//          · 启动 Traiectus-Server.exe（TCP 45789 + UDP 45791 控制通道）
//          · 启动 TraiectusBridge.ps1（把接收器的状态帧转发给 Mac 的 UDP 45790）
//          · 托盘显示状态：灰点 = 已停止，绿点 = 运行中，红点 = 异常
//        右键菜单：状态行 / 重启 / 打开日志目录 / 退出
//        （刻意不做「停止」这个中间态，运行中只能「重启」或「退出」）
//
//  为什么用 Job Object：
//        入口进程创建一个 Job，用 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
//        把服务端和桥接都放进去。入口进程一消失（正常退出、被强杀、崩溃），
//        内核会把 Job 里所有进程连同它们的子孙进程一起杀掉 —— 比逐个
//        taskkill 可靠得多，不会漏掉看门狗之类的子进程。
//
//  光标兜底：
//        ClipCursor 是 per-desktop 的全局状态。入口退出前自己调一次
//        ClipCursor(NULL)，所以即使服务端是被强杀的、来不及优雅解锁，
//        光标也不会被锁死。
//
//  安全红线（一条都没放松）：
//        · 不注册 Windows 服务（服务端依赖 Raw Input，必须在交互式会话里跑）
//        · 不加开机自启、不改注册表、不装驱动、不动防火墙
//        · 服务端逻辑、桥接逻辑、协议、端口一律不动
//
//  编译（mingw-w64 / w64devkit）：
//        g++ -std=c++17 -O2 -municode -mwindows -DUNICODE -D_UNICODE ^
//            -static -static-libgcc -static-libstdc++ ^
//            Traiectus.cpp -o Traiectus.exe ^
//            -lshell32 -lws2_32 -lgdi32 -luser32
//
//  关于 -static：必须加。不加的话 exe 会依赖 libstdc++-6.dll 之类的
//  动态库，一旦被复制到 %LOCALAPPDATA%\Traiectus\ 就双击打不开了。
// ============================================================================

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

// winsock2.h 必须排在 windows.h 前面。
// 反过来的话 windows.h 会先引入老的 winsock.h，再引入 winsock2.h
// 就会满屏重定义错误。
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>
#include <cmath>

#include "i18n.h"          // 界面文案的中英对照（表在 i18n.h 里）
#include "netinfo.h"       // 查当前默认路由那张网卡的 IP（托盘「本机 IP」那行用）

// ---------------------------------------------------------------------------
//  常量
// ---------------------------------------------------------------------------
#define WM_TRAY        (WM_APP + 1)
#define ID_TRAY        1
#define IDM_START      1001
#define IDM_RESTART    1003
#define IDM_LOGS       1004
#define IDM_EXIT       1005
#define IDM_UNPAIR     1006
#define IDM_HOTKEY     1007
#define IDM_DETECT     1008
#define IDM_LANG_ZH    1009
#define IDM_LANG_EN    1010
#define TIMER_HEALTH   1

#define APP_TITLE      L"Traiectus"
#define APP_WNDCLASS   L"Traiectus_TrayWnd"
#define APP_MUTEX      L"Traiectus_Launcher_SingleInstance"

// ---------------------------------------------------------------------------
//  配置
// ---------------------------------------------------------------------------

// 统一样式的对话框（定义在下面「改键小窗」那一节里，那里才有自绘字体/圆角按钮）。
// 托盘里**所有**提示都不再用系统 MessageBoxW —— 那玩意是方角系统脸，
// 和我们这套（配对弹框 / 改键小窗）不是一路；用户明确要求统一。
//   withCancel = false → 只有一个「确定」
//   withCancel = true  → 「取消」+「确定」，返回 true 表示点了确定
bool ShowStyledDialog(const std::wstring& title, const std::wstring& body, bool withCancel,
                      const std::wstring& okText = L"",
                      const std::wstring& cancelText = L"");
struct Config {
    std::wstring serverExe  = L"Traiectus-Server.exe";
    // 这里**不写设备串**：默认留空 = 不挑设备，服务端第一次运行会自动识别
    // "你真正在用的那只鼠标"并让托盘写回 config.ini（2026-10-03 起）。
    // 口令同理不用写：由配对生成，入口会把 --pair-file 显式传给服务端。
    std::wstring serverArgs = L"";
    // 2026-10-01（3b）：键盘状态帧已并进服务端，桥接退役 —— 默认**空 = 不启动**。
    //
    // 这里必须留空：ReadConfig() 的逻辑是"config.ini 里读不到值就保留这个默认值"，
    // 所以只要默认值非空，就算 config.ini 里写 `cmd=`（空），也会回退到默认、
    // 照样把桥接拉起来 —— 这正是第一次改完还会多出一个桥接进程的原因。
    //
    // 要做对照测试时，在 config.ini 的 [bridge] cmd 里写回完整命令即可。
    std::wstring bridgeCmd;
    std::wstring serverLog  = L"server.log";
    std::wstring bridgeLog  = L"bridge.log";
    int          tcpPort    = 45789;
    int          waitMs     = 15000;
    // config.ini 的 [ui] language："" = 跟随系统；"zh" / "en" = 用户手工指定。
    // 命令行 --lang 优先级更高，但不写回这里（只在本次运行生效）。
    std::wstring uiLanguage;
};

static Config       g_cfg;
static std::wstring g_exeDir;

// 语言来源（用于决定要不要把 --lang 传给服务端）
static bool         g_langFromCmdline = false;   // 命令行 --lang 指定的

static HANDLE       g_job     = NULL;
static HANDLE       g_hServer = NULL;
static HANDLE       g_hBridge = NULL;
static bool         g_running = false;
static bool         g_error   = false;
static std::wstring g_errorWhy;
// 「检测鼠标」：正在跑一轮设备识别（服务端加了 --detect），托盘的秒表在轮询日志
static bool         g_detecting    = false;
static ULONGLONG    g_detectStart  = 0;
static int          g_detectPolled = 0;

static NOTIFYICONDATAW g_nid = {};
static HICON        g_icoGreen = NULL;
static HICON        g_icoGray  = NULL;
static HICON        g_icoRed   = NULL;

// ---------------------------------------------------------------------------
//  路径工具
// ---------------------------------------------------------------------------
static std::wstring GetExeDir() {
    wchar_t buf[MAX_PATH] = {};
    ::GetModuleFileNameW(NULL, buf, MAX_PATH);
    std::wstring p = buf;
    const size_t pos = p.find_last_of(L"\\/");
    return (pos == std::wstring::npos) ? L"." : p.substr(0, pos);
}

// 找文件：先在 exe 同目录找，找不到再试几个常识位置。
// 这样同一份 config.ini 在两种布局下都能直接工作：
//   · 开发目录（launcher 与 phase3-tcp 同级）-> 服务端在 ..\phase3-tcp\build 里
//   · 安装目录  %LOCALAPPDATA%\Traiectus     -> 所有文件都平铺在这一层
// 注意：注释行结尾不要留反斜杠，否则编译器会把下一行也当成注释吞掉。
// 用字符串拼接而不是 swprintf —— 宽字符格式化里 %s 和 %ls 的坑不值得再踩一次。
static std::wstring ResolveFile(const std::wstring& name) {
    if (name.size() > 2 && name[1] == L':' && (name[2] == L'\\' || name[2] == L'/')) {
        return name;                       // 已经是绝对路径，原样用
    }
    const std::wstring probes[] = {
        g_exeDir + L"\\" + name,                            // 同目录（安装后）
        g_exeDir + L"\\..\\phase3-tcp\\build\\" + name,      // 开发目录
        g_exeDir + L"\\..\\" + name,                         // 开发目录的上一级
    };
    for (const std::wstring& p : probes) {
        if (::GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES) return p;
    }
    return probes[0];                      // 都没找到：返回同目录路径，错误信息里能看到它
}

// ---------------------------------------------------------------------------
//  小工具
// ---------------------------------------------------------------------------
static void SetTip(const wchar_t* text) {
    // szTip 是 WCHAR[128]，手写拷贝，避开 wcscpy_s 在 MinGW 下的可用性问题
    const size_t n = wcslen(text);
    const size_t max = ARRAYSIZE(g_nid.szTip) - 1;
    const size_t c = (n < max) ? n : max;
    wmemcpy(g_nid.szTip, text, c);
    g_nid.szTip[c] = L'\0';
}

// 提示条（toast）——用来替代托盘气泡。
//
//  ★ 为什么不用 Shell_NotifyIcon 的气泡（NIF_INFO）：Windows 11 会把它交给
//    系统通知中心，**专注助手/通知设置一关就完全不显示** —— 用户实测"没气泡"。
//    自绘一个右下角的小提示条是确定能看见的（不抢焦点、3 秒后自己消失）。
//  实现放在下面「统一样式的对话框」那一节（和 MsgDlg 共用一套样式），这里先声明。
void ShowToast(const std::wstring& title, const std::wstring& body, unsigned ms = 3000);

// 跑一条命令并等它结束（给 taskkill 用）
//
// 这里保持 CREATE_NO_WINDOW：它会附带一个 conhost，但 taskkill 只活几十毫秒，
// 任务管理器基本抓不到。不值得为这点收益去冒险（下面 SpawnInJob 里有踩坑记录）。
static void RunAndWait(const wchar_t* cmd, DWORD timeoutMs) {
    STARTUPINFOW si = { sizeof(si) };
    si.dwFlags     = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};
    std::wstring c = cmd;                  // CreateProcessW 需要可写缓冲
    if (::CreateProcessW(NULL, c.data(), NULL, NULL, FALSE,
                         CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        ::WaitForSingleObject(pi.hProcess, timeoutMs);
        ::CloseHandle(pi.hThread);
        ::CloseHandle(pi.hProcess);
    }
}

// 极端残留场景兜底。正常情况下 Job 已经保证不会残留，
// 这里只处理"上一次装的是旧版本、留了个野进程"这种情况。
static void CleanupStale() {
    RunAndWait(L"taskkill /F /IM Traiectus-Server.exe", 4000);
}

// 判断服务端是否已经进入"正在监听"状态。
//
// 早期写法是往 127.0.0.1:45789 连一下看能不能连上 —— 那是错的：
// 服务端同一时刻只服务一个客户端，而且新连接会无条件顶掉旧连接
// （见 main.cpp 的 accept 分支）。这个探测连接会把已经连上的 Mac 挤下线。
//
// 现在改成只读服务端自己的日志：它在 listen() 成功之后会打印
//    监听 0.0.0.0:45789（TCP）
// 我们只在这个文件里找 ASCII 子串 ":45789"，完全不去碰端口。
// 日志在每次启动时被截断，所以不会把上一次运行的旧行看成这次的成功。
static bool LogHasListenLine(const std::wstring& logPath, int port) {
    HANDLE h = ::CreateFileW(logPath.c_str(), GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;

    char buf[8192] = {};
    DWORD got = 0;
    const BOOL ok = ::ReadFile(h, buf, sizeof(buf) - 1, &got, NULL);
    ::CloseHandle(h);
    if (!ok || got == 0) return false;
    buf[got] = '\0';

    const std::string needle = ":" + std::to_string(port);
    return std::string(buf).find(needle) != std::string::npos;
}

static bool WaitServerReady(const std::wstring& logPath, int port, int timeoutMs) {
    const ULONGLONG start = ::GetTickCount64();
    while ((int)(::GetTickCount64() - start) < timeoutMs) {
        if (LogHasListenLine(logPath, port)) return true;
        if (g_hServer) {                   // 服务端还没就绪就死了 → 别白等
            DWORD code = 0;
            if (::GetExitCodeProcess(g_hServer, &code) && code != STILL_ACTIVE) return false;
        }
        ::Sleep(120);
    }
    return false;
}

// ---------------------------------------------------------------------------
//  托盘图标：运行时画一个纯色圆点，不依赖任何外部资源文件
// ---------------------------------------------------------------------------
static HICON MakeDotIcon(COLORREF color) {
    const int S = 16;
    HDC hdc = ::GetDC(NULL);
    BITMAPV5HEADER bi = {};
    bi.bV5Size        = sizeof(bi);
    bi.bV5Width       = S;
    bi.bV5Height      = -S;
    bi.bV5Planes      = 1;
    bi.bV5BitCount    = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask     = 0x00FF0000;
    bi.bV5GreenMask   = 0x0000FF00;
    bi.bV5BlueMask    = 0x000000FF;
    bi.bV5AlphaMask   = 0xFF000000;
    void* bits = NULL;
    HBITMAP hbm = ::CreateDIBSection(hdc, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ::ReleaseDC(NULL, hdc);
    if (!hbm || !bits) return ::LoadIconW(NULL, IDI_APPLICATION);

    DWORD* px = (DWORD*)bits;
    const double cx = S / 2.0 - 0.5, cy = S / 2.0 - 0.5, R = S / 2.0 - 1.0;
    // GetRValue / GetGValue / GetBValue 是 wingdi.h 里的宏，不能用 :: 限定
    const BYTE r = GetRValue(color), g = GetGValue(color), b = GetBValue(color);
    for (int y = 0; y < S; ++y) {
        for (int x = 0; x < S; ++x) {
            const double dx = x - cx, dy = y - cy;
            const double d  = std::sqrt(dx * dx + dy * dy);
            BYTE a = 0;
            if (d <= R - 1.0)      a = 255;
            else if (d <  R)       a = (BYTE)(255.0 * (R - d));
            px[y * S + x] = ((DWORD)a << 24) | ((DWORD)r << 16) | ((DWORD)g << 8) | b;
        }
    }
    HBITMAP hMask = ::CreateBitmap(S, S, 1, 1, NULL);
    ICONINFO ii = {};
    ii.fIcon    = TRUE;
    ii.hbmColor = hbm;
    ii.hbmMask  = hMask;
    HICON ic = ::CreateIconIndirect(&ii);
    ::DeleteObject(hbm);
    ::DeleteObject(hMask);
    return ic;
}

// ---------------------------------------------------------------------------
//  配置
// ---------------------------------------------------------------------------

// 入口自己的日志。只在"该留一句话、但弹框里不适合说"的极少数场合用（一直追加）。
// ★ 日志**保持中文**（和 server.log 一样）—— 它不是界面。
static void LauncherLog(const std::wstring& line) {
    const std::wstring p = g_exeDir + L"\\Traiectus-Launcher.log";
    HANDLE h = ::CreateFileW(p.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st{};
    ::GetLocalTime(&st);
    wchar_t stamp[32];
    ::swprintf(stamp, ARRAYSIZE(stamp), L"[%02u:%02u:%02u] ", st.wHour, st.wMinute, st.wSecond);
    const std::wstring out = std::wstring(stamp) + line + L"\r\n";
    const int need = ::WideCharToMultiByte(CP_UTF8, 0, out.c_str(), (int)out.size(), NULL, 0, NULL, NULL);
    if (need <= 0) { ::CloseHandle(h); return; }
    std::string bytes((size_t)need, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, out.c_str(), (int)out.size(), &bytes[0], need, NULL, NULL);
    DWORD wrote = 0;
    ::WriteFile(h, bytes.data(), (DWORD)bytes.size(), &wrote, NULL);
    ::CloseHandle(h);
}

// 语言三级优先：① 命令行 --lang zh|en ② config.ini 的 [ui] language ③ 系统 UI 语言
//   只有 ① ② 能指定；③ 只是"没指定时"的默认值（中文系统 → zh，其它 → en）。
//   注意：这里只**读**，写回由「语言」子菜单里的 SaveUiLanguageToConfig() 负责。
static void InitLanguage() {
    // ① 命令行 --lang
    int argc = 0;
    LPWSTR* argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
    if (argv) {
        for (int i = 1; i + 1 < argc; ++i) {
            if (::_wcsicmp(argv[i], L"--lang") == 0) {
                const std::wstring v = argv[i + 1];
                if (v == L"zh") { SetLang(Lang::Zh); g_langFromCmdline = true; }
                else if (v == L"en") { SetLang(Lang::En); g_langFromCmdline = true; }
                break;
            }
        }
        ::LocalFree(argv);
    }
    if (g_langFromCmdline) return;

    // ② config.ini 的 [ui] language
    const std::wstring ini = g_exeDir + L"\\config.ini";
    wchar_t buf[64] = {};
    ::GetPrivateProfileStringW(L"ui", L"language", L"", buf, ARRAYSIZE(buf), ini.c_str());
    std::wstring v = buf;
    while (!v.empty() && (v.back() == L' ' || v.back() == L'\t' || v.back() == L'\r')) v.pop_back();
    if (v == L"zh") { SetLang(Lang::Zh); return; }
    if (v == L"en") { SetLang(Lang::En); return; }

    // ③ 没指定 → 跟随系统 UI 语言的主语言
    SetLang((PRIMARYLANGID(::GetUserDefaultUILanguage()) == LANG_CHINESE) ? Lang::Zh : Lang::En);
}

// 没有 config.ini 时按当前语言选模板生成一份。
//   en → config.example.en.ini ；zh → config.example.ini
//   英文模板缺失 → 回退中文模板，并在入口日志里留一行中文说明。
//   ★ 只在 config.ini **不存在** 时执行 —— 已经存在的配置一个字节都不动。
static void EnsureConfigFile() {
    const std::wstring ini = g_exeDir + L"\\config.ini";
    if (::GetFileAttributesW(ini.c_str()) != INVALID_FILE_ATTRIBUTES) return;

    const bool wantEn = IsEnglish();
    std::wstring src = g_exeDir + L"\\" + (wantEn ? L"config.example.en.ini" : L"config.example.ini");
    bool fellBack = false;
    if (::GetFileAttributesW(src.c_str()) == INVALID_FILE_ATTRIBUTES) {
        src = g_exeDir + L"\\config.example.ini";
        fellBack = wantEn;
    }
    const std::wstring noTemplate =
        L("没能生成 config.ini：模板 config.example.ini 不存在。\n"
          L"现在用的是内置默认值，功能是完整的，只是设备过滤可能不匹配这台机器的鼠标。");
    if (::GetFileAttributesW(src.c_str()) == INVALID_FILE_ATTRIBUTES) {
        ShowStyledDialog(L("没有找到 config.ini"), noTemplate, false);
        return;
    }
    if (!::CopyFileW(src.c_str(), ini.c_str(), TRUE)) {
        ShowStyledDialog(L("没有找到 config.ini"), noTemplate, false);
        return;
    }
    const std::wstring base = src.substr(src.find_last_of(L"\\/") + 1);
    if (fellBack) {
        LauncherLog(L"英文模板 config.example.en.ini 不存在，已回退用中文模板 config.example.ini 生成 config.ini。");
    }
    ShowStyledDialog(L("配置已生成"),
                     L("已生成 config.ini（模板：") + base + L("）。改完再启动即可。"), false);
}

static void ReadConfig() {
    const std::wstring ini = g_exeDir + L"\\config.ini";
    EnsureConfigFile();

    wchar_t buf[2048];
    auto get = [&](const wchar_t* sec, const wchar_t* key, std::wstring& out) {
        buf[0] = L'\0';
        if (::GetPrivateProfileStringW(sec, key, L"", buf, ARRAYSIZE(buf), ini.c_str()) > 0) {
            out = buf;
        }
    };
    get(L"server", L"exe",  g_cfg.serverExe);
    get(L"server", L"args", g_cfg.serverArgs);
    get(L"server", L"log",  g_cfg.serverLog);
    get(L"bridge", L"cmd",  g_cfg.bridgeCmd);
    get(L"bridge", L"log",  g_cfg.bridgeLog);
    get(L"ui",     L"language", g_cfg.uiLanguage);
    g_cfg.tcpPort = (int)::GetPrivateProfileIntW(L"app", L"port", g_cfg.tcpPort, ini.c_str());
    g_cfg.waitMs  = (int)::GetPrivateProfileIntW(L"app", L"waitMs", g_cfg.waitMs, ini.c_str());

    // 老配置里可能还留着 --token（那个参数已经删了，传过去会让服务端报"不认识的参数"）。
    // 直接说清楚怎么改，别让人对着启动失败猜。
    if (g_cfg.serverArgs.find(L"--token") != std::wstring::npos) {
        ShowStyledDialog(L("config.ini 里有废弃的 --token"),
            L("这个参数已经不用了（留着会让服务端启动失败）。\n"
              L"把 --token 那一段删掉即可：口令由配对生成，不用自己设。\n"
              L"（文件：launcher\\config.ini 的 [server] args）"),
            false);
    }
}

// ---------------------------------------------------------------------------
//  进程
// ---------------------------------------------------------------------------
// 日志文件每次都截断重开：这样 server.log 永远只反映当前这一次运行，
// 上面那个"找 :45789"的就绪判断也不会把上一次运行的旧行误认为成功。
static HANDLE MakeLogHandle(const std::wstring& fullPath) {
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };   // 必须可继承
    return ::CreateFileW(fullPath.c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ | FILE_SHARE_WRITE,
                         &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static bool SpawnInJob(const std::wstring& cmdline,
                       const std::wstring& logFullPath,
                       bool noConsole,
                       HANDLE& outProc) {
    HANDLE hLog = MakeLogHandle(logFullPath);
    HANDLE hNul = ::CreateFileW(L"NUL", GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE,
                                NULL, OPEN_EXISTING, 0, NULL);

    STARTUPINFOW si = { sizeof(si) };
    si.dwFlags     = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    si.wShowWindow = SW_HIDE;
    si.hStdInput   = hNul;
    si.hStdOutput  = hLog;
    si.hStdError   = hLog;

    PROCESS_INFORMATION pi = {};
    std::wstring c = cmdline;

    // 关于 noConsole —— 这里踩过一次坑，写清楚免得以后又改错：
    //
    //   CREATE_NO_WINDOW 仍然会给「控制台子系统」的程序分配一个没有窗口的控制台，
    //   于是 Windows 必须额外起一个 conhost.exe 当宿主（实测多出约 7 MB）。
    //   DETACHED_PROCESS 让子进程干脆不关联任何控制台，就不会有 conhost。
    //   （宏名是 DETACHED_PROCESS，没有 CREATE_ 前缀 —— winbase.h 里就这么写的。）
    //
    //   但是！PowerShell 不行。实测：桥接用 DETACHED_PROCESS 启动后，
    //   powershell.exe 一行输出都不产生、bridge-console.log 是 0 字节、进程立刻消失；
    //   接着健康检查发现"桥接已退出"，按设计把服务端也一起收干净了 ——
    //   表面看像"服务端自己崩了"，其实是连锁反应。
    //
    //   所以分工：
    //     服务端（纯 printf 输出到重定向文件，不依赖控制台）→ noConsole = true
    //     桥接（powershell.exe，必须有控制台）            → noConsole = false
    const DWORD flags = (noConsole ? DETACHED_PROCESS : CREATE_NO_WINDOW) | CREATE_SUSPENDED;
    const BOOL ok = ::CreateProcessW(NULL, c.data(), NULL, NULL, TRUE,
                                     flags,
                                     NULL, g_exeDir.c_str(), &si, &pi);

    if (hLog && hLog != INVALID_HANDLE_VALUE) ::CloseHandle(hLog);
    if (hNul && hNul != INVALID_HANDLE_VALUE) ::CloseHandle(hNul);
    if (!ok) return false;

    // 先挂进 Job 再放行 —— 否则子进程可能在挂进去之前就先起了孙子进程，
    // 那些孙子进程就漏在 Job 外面了。
    if (g_job) ::AssignProcessToJobObject(g_job, pi.hProcess);
    ::ResumeThread(pi.hThread);
    ::CloseHandle(pi.hThread);
    outProc = pi.hProcess;
    return true;
}

// 把 config.ini 里的 bridge.cmd 展开成完整命令行：
//   · %SYS% 替换成 <exe目录>\TraiectusBridge.ps1 的完整路径
//   · 如果没写 %SYS%，按原样使用（留出完全自定义的余地）
static std::wstring ExpandBridgeCmd() {
    std::wstring cmd = g_cfg.bridgeCmd;
    const std::wstring bridgePath = ResolveFile(L"TraiectusBridge.ps1");
    const std::wstring tag = L"%SYS%";
    for (size_t pos = cmd.find(tag); pos != std::wstring::npos; pos = cmd.find(tag, pos)) {
        cmd.replace(pos, tag.size(), bridgePath);
    }
    return cmd;
}

// ---------------------------------------------------------------------------
//  生命周期
// ---------------------------------------------------------------------------
static void CenterCursor() {
    ::SetCursorPos(::GetSystemMetrics(SM_CXSCREEN) / 2,
                   ::GetSystemMetrics(SM_CYSCREEN) / 2);
}

// 只负责把子进程收干净，不碰光标。
// Job 是核心：关掉 Job 句柄，内核就会把 Job 内所有进程（含子孙进程）一起杀掉。
static void TeardownProcesses() {
    if (g_job) {
        ::CloseHandle(g_job);
        g_job = NULL;
        ::Sleep(300);          // 给内核一点时间收干净并释放端口
    }
    if (g_hServer) {
        ::WaitForSingleObject(g_hServer, 1500);
        ::CloseHandle(g_hServer);
        g_hServer = NULL;
    }
    if (g_hBridge) {
        ::WaitForSingleObject(g_hBridge, 1500);
        ::CloseHandle(g_hBridge);
        g_hBridge = NULL;
    }
}

// 光标兜底：ClipCursor 是 per-desktop 全局状态，不依赖服务端优雅退出。
// 只有确实被锁住过才把光标挪回屏幕中间 —— 避免平时退出时白动一下鼠标位置。
static void ReleaseCursor() {
    RECT rc = {};
    bool wasClipped = false;
    if (::GetClipCursor(&rc)) {
        wasClipped = ((rc.right - rc.left) <= 2) && ((rc.bottom - rc.top) <= 2);
    }
    ::ClipCursor(NULL);
    if (wasClipped) CenterCursor();
}

// 配对文件路径（args 里的 --pair-file，没有就用默认值）。
// 定义在下面「重新配对」那一节，StartServices 起动服务端时要用到。
static std::wstring PairFilePathFromConfig();

static bool StartServices() {
    if (g_running) return true;

    // 上一轮可能留下"半截"状态：例如服务端崩了、健康检查把状态标成异常，
    // 但桥接还在跑。重新拉起之前必须先收干净，否则会出现两个桥接
    // 同时往 Mac 发 UDP 的情况，而且旧 Job 句柄会泄漏。
    if (g_job || g_hServer || g_hBridge) TeardownProcesses();

    g_error = false;
    g_errorWhy.clear();

    g_job = ::CreateJobObjectW(NULL, NULL);
    if (!g_job) {
        ShowStyledDialog(L("启动失败"), L("创建 Job Object 失败，无法安全地管理子进程。"), false);
        return false;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
    jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    ::SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));

    // ---- 服务端 ----
    const std::wstring serverPath = ResolveFile(g_cfg.serverExe);
    if (::GetFileAttributesW(serverPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        ShowStyledDialog(L("找不到服务端程序"),
            L("路径：\n") + serverPath + L"\n\n" +
            L("请先跑一次 phase3-tcp\\build-mingw.bat 生成它，或检查 config.ini 里的 server.exe。"),
            false);
        ::CloseHandle(g_job); g_job = NULL;
        return false;
    }
    const std::wstring serverLogPath = g_exeDir + L"\\" + g_cfg.serverLog;
    // 配对文件路径由**入口**显式传给服务端（args 里已经有 --pair-file 就尊重它）。
    // 为什么要显式传：服务端是拿**它自己**的 exe 目录推默认路径，入口是拿**自己的**
    // 目录推。开发布局下两者不同（服务端在 phase3-tcp\build\ 里），一旦分叉，
    // 「重新配对」删的就不是服务端实际在用的那个文件。入口是唯一同时知道两种布局的
    // 地方，所以由它来定。（2026-10-01 真机配对时踩到过，见回报文档。）
    std::wstring serverArgs = g_cfg.serverArgs;
    if (serverArgs.find(L"--pair-file") == std::wstring::npos) {
        serverArgs += L" --pair-file \"" + PairFilePathFromConfig() + L"\"";
    }
// 「检测鼠标」期间：临时附一个 --detect，让服务端无视现有设备串、重跑一次识别。
    // 只影响这一次启动，config.ini 里的 args 不动。
    if (g_detecting) {
        serverArgs += L" --detect";
        g_detectStart = ::GetTickCount64();
    }
    // 语言透传给服务端（配对框 / 启动横幅 / --help / --list 用它）。
    // ★ 只加在这一次的命令行上，**不写进 config.ini** —— config.ini 里那份
    //   args 是用户的，托盘无权替他改。
    // ★ 服务端自己也会按 --lang > [ui] language > 系统语言 三级判断；
    //   这里显式传，是为了让"托盘切了语言"立刻对服务端生效。
    if (serverArgs.find(L"--lang") == std::wstring::npos) {
        serverArgs += IsEnglish() ? L" --lang en" : L" --lang zh";
    }
    const std::wstring serverCmd = L"\"" + serverPath + L"\" " + serverArgs;
    // 服务端：输出走重定向文件，不依赖控制台 → 用 DETACHED，省掉它的 conhost
    if (!SpawnInJob(serverCmd, serverLogPath, /*noConsole=*/true, g_hServer)) {
        ShowStyledDialog(L("启动服务端失败"),
            L("错误码 ") + std::to_wstring(::GetLastError()) + L("。\n命令行：\n") + serverCmd,
            false);
        ::CloseHandle(g_job); g_job = NULL;
        return false;
    }

    if (!WaitServerReady(serverLogPath, g_cfg.tcpPort, g_cfg.waitMs)) {
        ShowStyledDialog(L("服务端启动超时"),
            L("没有在 ") + std::to_wstring(g_cfg.waitMs / 1000) +
            L(" 秒内进入监听状态。\n\n请看日志：\n") + serverLogPath,
            false);
        // 不中断：也许只是慢，继续把桥接也拉起来，状态由托盘反映
    }

    // ---- 桥接（3b 之后已退役，默认不启动）----
    //
    //  2026-10-01：键盘状态帧的读取已经并进服务端（服务端自己读接收器 ->
    //  UDP 45790、自己发 HB、自己收回包），所以这个 PowerShell 桥接不再需要。
    //
    //  config.ini 里的 [bridge] cmd 留空 = 不启动（默认）。
    //  想临时跑回旧方案做对照，把它填回去即可：
    //      cmd=powershell -NoProfile -ExecutionPolicy Bypass -File "%SYS%" -MacIp <Mac的地址> -OutFile TraiectusBridge.log
    //
    //  注意：不启动桥接时 g_hBridge 保持 NULL，健康检查不会把它当成"子进程挂了"。
    if (g_cfg.bridgeCmd.empty()) {
        // 正常情况：什么都不做，也不记日志（托盘上没有多余状态）
    } else if (!SpawnInJob(ExpandBridgeCmd(),
                           g_exeDir + L"\\" + g_cfg.bridgeLog,
                           /*noConsole=*/false, g_hBridge)) {
        ShowStyledDialog(L("启动桥接失败"),
            L("错误码 ") + std::to_wstring(::GetLastError()) + L("。\n命令行：\n") +
            ExpandBridgeCmd() + L"\n\n" + L("鼠标转发仍然可用，但键盘跨机切换会失效。"),
            false);
    }

    g_running = true;
    return true;
}

static void StopServices() {
    TeardownProcesses();
    ReleaseCursor();
    g_running = false;
    g_error   = false;
    g_errorWhy.clear();
}

// ---------------------------------------------------------------------------
//  托盘
// ---------------------------------------------------------------------------
static void AddTray(HWND hwnd) {
    g_nid.cbSize           = sizeof(g_nid);
    g_nid.hWnd             = hwnd;
    g_nid.uID              = ID_TRAY;
    g_nid.uFlags           = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon            = g_icoGray;
    SetTip(L("Traiectus：已停止").c_str());
    ::Shell_NotifyIconW(NIM_ADD, &g_nid);
}

static void RemoveTray() {
    ::Shell_NotifyIconW(NIM_DELETE, &g_nid);
}

static void UpdateTray() {
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    if (g_error) {
        g_nid.hIcon = g_icoRed;
        SetTip(g_errorWhy.empty() ? L("Traiectus：异常").c_str() : g_errorWhy.c_str());
    } else if (g_running) {
        g_nid.hIcon = g_icoGreen;
        SetTip(L("Traiectus：运行中").c_str());
    } else {
        g_nid.hIcon = g_icoGray;
        SetTip(L("Traiectus：已停止").c_str());
    }
    ::Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

// ---------------------------------------------------------------------------
//  重新配对（配对流程 v1.2）
// ---------------------------------------------------------------------------
//  服务端**不缓存口令**（Mac 侧方案 D）：握手时现读配对文件。
//  所以托盘这边只要**把文件删掉**就行 —— 不需要 IPC、不用动协议。
//  生效时机是"下一次连接"，当前已连的会话不受影响。
//
//  口令的唯一来源就是配对文件（2026-10-01 删掉 --token 之后不再有第二条路），
//  所以「重新配对」**永远可点**、永远是"删掉那个文件"这一个动作。
//  路径：args 里**有 --pair-file** → 用那个；否则用默认 phase3-tcp\paired.json。
static std::wstring PairFilePathFromConfig() {
    const std::wstring def = g_exeDir + L"\\..\\phase3-tcp\\paired.json";
    const std::wstring a = g_cfg.serverArgs;
    const std::wstring key = L"--pair-file";
    size_t p = a.find(key);
    if (p == std::wstring::npos) return def;
    p += key.size();
    while (p < a.size() && (a[p] == L' ' || a[p] == L'\t')) ++p;
    std::wstring v;
    if (p < a.size() && a[p] == L'"') {
        ++p;
        while (p < a.size() && a[p] != L'"') v.push_back(a[p++]);
    } else {
        while (p < a.size() && a[p] != L' ' && a[p] != L'\t') v.push_back(a[p++]);
    }
    return v.empty() ? def : v;
}

static void DoUnpair(HWND hwnd) {
    const std::wstring p = PairFilePathFromConfig();
    const std::wstring ask =
        L("确定要重新配对吗？\n\n会删除这个文件：\n") + p +
        L("\n\n注意：对当前已连接的会话没有影响 ——\n"
          L"Mac 会在**下一次连接**时被要求重新点一次「允许」。");
    if (!ShowStyledDialog(L("重新配对"), ask, true, L("删除配对文件"), L("取消"))) return;

    if (::DeleteFileW(p.c_str())) {
        ShowStyledDialog(L("已清除配对"), L("Mac 下次连接时会重新询问。"), false);
    } else {
        const DWORD e = ::GetLastError();
        if (e == ERROR_FILE_NOT_FOUND) {
            ShowStyledDialog(L("没有配对文件"), L("本来就没有配对文件（可能已经是未配对状态）。"), false);
        } else {
            ShowStyledDialog(L("删除失败"),
                L("错误码 ") + std::to_wstring(e) + L("。\n\n") + p, false);
        }
    }
}

// ---------------------------------------------------------------------------
//  鼠标切换热键（可配置）
// ---------------------------------------------------------------------------
//  状态**不去解析 config.ini**，而是读服务端日志尾部那一行机器可读状态：
//      HOTKEY OK   Ctrl+Alt+M
//      HOTKEY FAIL Ctrl+Alt+M 1409      （1409 = 已被别的程序占用）
//      HOTKEY OFF
//  这样托盘和"实际注册成功没有"永远一致 —— 重启服务端后自动就是最新的。
//  不用新协议、不用新文件、不用新线程。

static std::wstring AsciiToWide(const std::string& s) {
    std::wstring w;
    w.reserve(s.size());
    for (char c : s) w.push_back((wchar_t)(unsigned char)c);
    return w;
}

// 只用于纯 ASCII 的串（热键写法永远是 ASCII）
static std::string WideToAscii(const std::wstring& s) {
    std::string a;
    a.reserve(s.size());
    for (wchar_t c : s) a.push_back((char)(unsigned char)(c & 0xFF));
    return a;
}

struct HotkeyStatus {
    int          state = 0;      // 0=不知道 1=OK 2=被占用 3=未设置
    std::wstring text;           // "Ctrl+Alt+M"
};

// 读日志最后 128 KB，找**最后一条**以 "HOTKEY " 开头的行
static HotkeyStatus ReadHotkeyStatus() {
    HotkeyStatus st;
    const std::wstring path = g_exeDir + L"\\" + g_cfg.serverLog;
    HANDLE h = ::CreateFileW(path.c_str(), GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return st;

    LARGE_INTEGER sz{};
    if (!::GetFileSizeEx(h, &sz)) { ::CloseHandle(h); return st; }
    const long long keep = 128 * 1024;
    long long from = (sz.QuadPart > keep) ? sz.QuadPart - keep : 0;
    LARGE_INTEGER li{}; li.QuadPart = from;
    ::SetFilePointerEx(h, li, NULL, FILE_BEGIN);

    std::string buf((size_t)(sz.QuadPart - from), '\0');
    DWORD got = 0;
    if (!buf.empty()) ::ReadFile(h, &buf[0], (DWORD)buf.size(), &got, NULL);
    ::CloseHandle(h);
    buf.resize(got);

    std::string best;
    for (size_t pos = 0; pos < buf.size();) {
        const size_t nl = buf.find('\n', pos);
        std::string line = (nl == std::string::npos) ? buf.substr(pos) : buf.substr(pos, nl - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("HOTKEY ", 0) == 0) best = line;
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    if (best.empty()) return st;

    // "HOTKEY OK Ctrl+Alt+M" / "HOTKEY FAIL Ctrl+Alt+M 1409" / "HOTKEY OFF"
    const std::string rest = best.substr(7);
    if (rest.rfind("OK ", 0) == 0) {
        st.state = 1;
        st.text  = AsciiToWide(rest.substr(3));
    } else if (rest.rfind("FAIL ", 0) == 0) {
        st.state = 2;
        std::string t = rest.substr(5);
        const size_t sp = t.find_last_of(' ');
        if (sp != std::string::npos) t.resize(sp);      // 去掉末尾的错误码
        st.text = AsciiToWide(t);
    } else if (rest == "OFF") {
        st.state = 3;
    }
    return st;
}

// 状态行后缀：给菜单第一行用
static std::wstring HotkeyMenuSuffix() {
    const HotkeyStatus st = ReadHotkeyStatus();
    switch (st.state) {
case 1:  return L("鼠标切换：") + st.text + L(" ✓");
case 2:  return L("鼠标切换：") + st.text + L(" ✗ 被占用");
case 3:  return L("鼠标切换：未设置");
    default: return L"";
    }
}

// 就地改 config.ini 里 args= 那一行的某个参数值（--hotkey / --device 共用）。
//   · 只动那一行里的这一个 token，其它行、其它参数**一个字节都不碰**
//   · 原样读字节、原样写回去（不转码，换行也不动）
//   · quote=true 时写成 "值"（设备串里有 &，必须带引号）
static bool SaveArgToConfig(const std::wstring& key, const std::wstring& value, bool quote) {
    const std::wstring ini = g_exeDir + L"\\config.ini";
    HANDLE h = ::CreateFileW(ini.c_str(), GENERIC_READ,
                             FILE_SHARE_READ, NULL, OPEN_EXISTING,
                             FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        ShowStyledDialog(L("读不到 config.ini"), ini, false);
        return false;
    }
    LARGE_INTEGER sz{};
    ::GetFileSizeEx(h, &sz);
    std::string raw((size_t)sz.QuadPart, '\0');
    DWORD got = 0;
    if (!raw.empty()) ::ReadFile(h, &raw[0], (DWORD)raw.size(), &got, NULL);
    ::CloseHandle(h);
    raw.resize(got);

    // 找以 "args="（可带前导空白）开头的那一行
    const size_t lineStart = [&]() -> size_t {
        for (size_t p = 0; p < raw.size();) {
            const size_t nl = raw.find('\n', p);
            const size_t end = (nl == std::string::npos) ? raw.size() : nl;
            size_t q = p;
            while (q < end && (raw[q] == ' ' || raw[q] == '\t')) ++q;
            if (end - q >= 5 && raw.compare(q, 5, "args=") == 0) return p;
            if (nl == std::string::npos) break;
            p = nl + 1;
        }
        return std::string::npos;
    }();
    if (lineStart == std::string::npos) {
        ShowStyledDialog(L("config.ini 格式不对"),
            L("找不到 [server] 的 args= 那一行，没有改动。"), false);
        return false;
    }
    size_t lineEnd = raw.find('\n', lineStart);
    if (lineEnd == std::string::npos) lineEnd = raw.size();
    size_t lineStop = lineEnd;                       // 不含行尾的 \r
    if (lineStop > lineStart && raw[lineStop - 1] == '\r') --lineStop;

    std::string line = raw.substr(lineStart, lineStop - lineStart);
    std::string k = WideToAscii(key);
    std::string val = WideToAscii(value);
    if (quote) val = "\"" + val + "\"";
    const size_t kp = line.find(k);
    if (kp == std::string::npos) {
        line += " " + k + " " + val;                 // 没有就追加到行尾
    } else {
        size_t vp = kp + k.size();
        while (vp < line.size() && (line[vp] == ' ' || line[vp] == '\t')) ++vp;
        // 值可能带引号：整段（含引号）一起换掉
        size_t ve = vp;
        if (ve < line.size() && line[ve] == '"') {
            ++ve;
            while (ve < line.size() && line[ve] != '"') ++ve;
            if (ve < line.size()) ++ve;
        } else {
            while (ve < line.size() && line[ve] != ' ' && line[ve] != '\t') ++ve;
        }
        line = line.substr(0, vp) + val + line.substr(ve);
    }

    std::string out = raw.substr(0, lineStart) + line + raw.substr(lineStop);

    HANDLE w = ::CreateFileW(ini.c_str(), GENERIC_WRITE, 0, NULL,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (w == INVALID_HANDLE_VALUE) {
        ShowStyledDialog(L("写 config.ini 失败"),
            L("文件被占用或只读？没有改动。"), false);
        return false;
    }
    DWORD wrote = 0;
    const BOOL ok = ::WriteFile(w, out.data(), (DWORD)out.size(), &wrote, NULL);
    ::CloseHandle(w);
    if (!ok || wrote != (DWORD)out.size()) {
        ShowStyledDialog(L("写 config.ini 不完整"), L("请检查文件。"), false);
        return false;
    }
    g_cfg.serverArgs = AsciiToWide(line.substr(line.find('=') + 1));
    while (!g_cfg.serverArgs.empty() && g_cfg.serverArgs.front() == L' ')
        g_cfg.serverArgs.erase(g_cfg.serverArgs.begin());
    return true;
}

static bool SaveHotkeyToConfig(const std::wstring& hk) {
    return SaveArgToConfig(L"--hotkey", hk, /*quote=*/false);
}

static bool SaveDeviceToConfig(const std::wstring& dev) {
    // 兜底：绝不让占位符/空值写进配置（服务端那边也会把它们排除在候选之外）
    if (dev.empty() || dev == L"<unknown-device>") return false;
    return SaveArgToConfig(L"--device", dev, /*quote=*/true);   // 设备串里有 &，必须带引号
}

// 就地改 config.ini 里 [ui] 段的 language= 的值（**只动这一行**，别的字节不碰）。
//   value = "zh" / "en"；空串 = 跟随系统（就写成 `language=`）。
//   段或行不存在就补一行 / 补一段 —— 老的 config.ini 里没有 [ui] 段是正常的。
static bool SaveUiLanguageToConfig(const std::wstring& value) {
    const std::wstring ini = g_exeDir + L"\\config.ini";
    HANDLE h = ::CreateFileW(ini.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        ShowStyledDialog(L("读不到 config.ini"), ini, false);
        return false;
    }
    LARGE_INTEGER sz{};
    ::GetFileSizeEx(h, &sz);
    std::string raw((size_t)sz.QuadPart, '\0');
    DWORD got = 0;
    if (!raw.empty()) ::ReadFile(h, &raw[0], (DWORD)raw.size(), &got, NULL);
    ::CloseHandle(h);
    raw.resize(got);

    const std::string val = WideToAscii(value);
    const std::string kLang = "language=";
    auto ciPrefix = [](const std::string& s, size_t at, const std::string& p) {
        if (at + p.size() > s.size()) return false;
        for (size_t i = 0; i < p.size(); ++i)
            if (::tolower((unsigned char)s[at + i]) != (unsigned char)p[i]) return false;
        return true;
    };

    bool   haveUi      = false;
    size_t uiLineEnd   = std::string::npos;   // "[ui]" 那一行的换行位置
    size_t langStart   = std::string::npos;   // language= 那一行的起点
    size_t langStop    = std::string::npos;   // 值的起点（= 号之后，跳过空白）
    size_t langValEnd  = std::string::npos;   // 值的终点（行尾，不含 \r）
    for (size_t p = 0; p < raw.size();) {
        const size_t nl  = raw.find('\n', p);
        const size_t end = (nl == std::string::npos) ? raw.size() : nl;
        size_t q = p;
        while (q < end && (raw[q] == ' ' || raw[q] == '\t')) ++q;
        if (q < end && raw[q] == '[') {
            if (haveUi) break;                 // 下一个 [xxx] = [ui] 段结束
            size_t rb = q;
            while (rb < end && raw[rb] != ']') ++rb;
            std::string name = raw.substr(q + 1, rb - q - 1);
            for (char& c : name) c = (char)::tolower((unsigned char)c);
            if (name == "ui") { haveUi = true; uiLineEnd = nl; }
        } else if (haveUi && ciPrefix(raw, q, kLang)) {
            langStart  = p;
            langStop   = q + kLang.size();
            langValEnd = end;
            if (langValEnd > langStop && raw[langValEnd - 1] == '\r') --langValEnd;
        }
        if (nl == std::string::npos) break;
        p = nl + 1;
    }

    std::string out;
    if (langStart != std::string::npos) {
        out = raw.substr(0, langStop) + val + raw.substr(langValEnd);
    } else if (haveUi) {
        // [ui] 段在，但没有 language= 行 → 插在 [ui] 那一行后面
        const size_t at = (uiLineEnd == std::string::npos) ? raw.size() : uiLineEnd + 1;
        const std::string nl2 = (uiLineEnd == std::string::npos) ? std::string("\r\n") : std::string();
        out = raw.substr(0, at) + nl2 + "language=" + val + "\r\n" + raw.substr(at);
    } else {
        // 连 [ui] 段都没有 → 追加一段（老配置升级到本版本时会走这条路）
        out = raw;
        if (!out.empty() && out.back() != '\n') out += "\r\n";
        out += "\r\n[ui]\r\nlanguage=" + val + "\r\n";
    }

    HANDLE w = ::CreateFileW(ini.c_str(), GENERIC_WRITE, 0, NULL,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (w == INVALID_HANDLE_VALUE) {
        ShowStyledDialog(L("写 config.ini 失败"),
            L("文件被占用或只读？没有改动。"), false);
        return false;
    }
    DWORD wrote = 0;
    const BOOL ok = ::WriteFile(w, out.data(), (DWORD)out.size(), &wrote, NULL);
    ::CloseHandle(w);
    if (!ok || wrote != (DWORD)out.size()) {
        ShowStyledDialog(L("写 config.ini 不完整"), L("请检查文件。"), false);
        return false;
    }
    g_cfg.uiLanguage = value;
    return true;
}

// ---------------------------------------------------------------------------
//  鼠标设备自动识别：读服务端日志里的机器可读行
// ---------------------------------------------------------------------------
//  和服务端约定（每行都**不带时间前缀**，按行首 grep）：
//      DEVICE PICK  <串>      只有一个设备动过
//      DEVICE MULTI <个数>    多个设备动过（后面跟若干 DEVICE CAND <串> <次数>）
//      DEVICE NONE            没人动
//      DEVICE MISS  <串>      配了串却一直没通过
//      DEVICE OK    <串>      配的串正常

struct DeviceStatus {
    int                       state = 0;   // 0=没信息 1=PICK 2=MULTI 3=NONE 4=MISS 5=OK
    std::wstring              pick;        // PICK/OK/MISS 的串
    std::vector<std::wstring> cand;        // MULTI 的候选
};

// 读日志最后 256 KB，扫出所有 DEVICE 行（只认最后一段连续的一组）
static DeviceStatus ReadDeviceStatus() {
    DeviceStatus st;
    const std::wstring path = g_exeDir + L"\\" + g_cfg.serverLog;
    HANDLE h = ::CreateFileW(path.c_str(), GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return st;

    LARGE_INTEGER sz{};
    if (!::GetFileSizeEx(h, &sz)) { ::CloseHandle(h); return st; }
    const long long keep = 256 * 1024;
    long long from = (sz.QuadPart > keep) ? sz.QuadPart - keep : 0;
    LARGE_INTEGER li{}; li.QuadPart = from;
    ::SetFilePointerEx(h, li, NULL, FILE_BEGIN);
    std::string buf((size_t)(sz.QuadPart - from), '\0');
    DWORD got = 0;
    if (!buf.empty()) ::ReadFile(h, &buf[0], (DWORD)buf.size(), &got, NULL);
    ::CloseHandle(h);
    buf.resize(got);

    std::vector<std::string> lines;
    for (size_t pos = 0; pos < buf.size();) {
        const size_t nl = buf.find('\n', pos);
        std::string line = (nl == std::string::npos) ? buf.substr(pos) : buf.substr(pos, nl - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("DEVICE ", 0) == 0) lines.push_back(line);
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    if (lines.empty()) return st;

    // 从后往前扫，遇到第一个"结论行"（PICK/MULTI/NONE/MISS/OK）就停 ——
    // 顺便把 MULTI 后面的候选收集起来
    for (size_t i = lines.size(); i-- > 0;) {
        const std::string& s = lines[i];
        if (s.rfind("DEVICE CAND ", 0) == 0) {
            const std::string rest = s.substr(12);
            const size_t sp = rest.find(' ');
            st.cand.push_back(AsciiToWide(sp == std::string::npos ? rest : rest.substr(0, sp)));
            continue;
        }
        if (s.rfind("DEVICE PICK ", 0) == 0)  { st.state = 1; st.pick = AsciiToWide(s.substr(12)); break; }
        if (s.rfind("DEVICE MULTI ", 0) == 0) { st.state = 2; break; }
        if (s == "DEVICE NONE")               { st.state = 3; break; }
        if (s.rfind("DEVICE MISS ", 0) == 0)  { st.state = 4; st.pick = AsciiToWide(s.substr(12)); break; }
        if (s.rfind("DEVICE OK ", 0) == 0)    { st.state = 5; st.pick = AsciiToWide(s.substr(10)); break; }
    }
    return st;
}

// 菜单第一行后面的"鼠标："后缀
static std::wstring DeviceMenuSuffix() {
    const DeviceStatus ds = ReadDeviceStatus();
    switch (ds.state) {
case 1:  return L("鼠标：") + ds.pick + L(" ✓");
case 5:  return L("鼠标：") + ds.pick + L(" ✓");
case 4:  return L("鼠标：✗ 未匹配（换鼠标了？点「检测鼠标」）");
case 2:  return L("鼠标：检测到 ") + std::to_wstring(ds.cand.size()) + L(" 个 → 点「检测鼠标」选一个");
case 3:  return L("鼠标：没检测到 → 点「检测鼠标」重试");
    default: {
        // 日志里还没有 DEVICE 行（刚启动、鼠标还没动过）→ 用配置里的 --device 兜底，
        // 免得菜单那一行整个消失（看起来像功能没了）
        const std::wstring a = g_cfg.serverArgs;
        const size_t p = a.find(L"--device");
if (p == std::wstring::npos) return L("鼠标：") + L("全部（未指定）");
        size_t q = p + 8;
        while (q < a.size() && (a[q] == L' ' || a[q] == L'\t')) ++q;
        std::wstring v;
        if (q < a.size() && a[q] == L'"') {
            ++q;
            while (q < a.size() && a[q] != L'"') v.push_back(a[q++]);
        } else {
            while (q < a.size() && a[q] != L' ' && a[q] != L'\t') v.push_back(a[q++]);
        }
if (v.empty()) return L("鼠标：") + L("全部（未指定）");
return L("鼠标：") + v;
    }
    }
}

// ---------------------------------------------------------------------------
//  「设置鼠标切换快捷键」小窗
// ---------------------------------------------------------------------------
//  一次性窗口：关掉就销毁，**不常驻、不留后台线程、不加自启** ——
//  这是"打游戏前退出 = 环境完全干净"那条硬要求的底线。
//  交互（按任务单）：
//    · 按下组合键立刻显示（用 Ctrl+Alt+M 这种写法，和 config.ini 一致）
//    · 只按主键没按修饰键 → 提示 + 保存按钮不可用
//    · Esc = 取消（什么都不改）
//    · Delete / Backspace = 清空 → 保存后写 off（不使用热键）

// ---------------------------------------------------------------------------
//  「设置鼠标切换快捷键」小窗
// ---------------------------------------------------------------------------
//  一次性窗口：关掉就销毁，**不常驻、不留后台线程、不加自启** ——
//  这是"打游戏前退出 = 环境完全干净"那条硬要求的底线。
//
//  视觉上跟配对确认框一套：无标题栏的圆角浮层、浅色面板、自绘圆角按钮、
//  没有颜色强调（用户明确要求过"不要有颜色"）。
//  交互（按任务单）：
//    · 按下组合键立刻显示（用 Ctrl+Alt+M 这种写法，和 config.ini 一致）
//    · 只按主键没按修饰键 → 提示 + 保存按钮不可用
//    · Esc / 关闭 = 取消（什么都不改）
//    · Delete / Backspace = 清空 → 保存后写 off（不使用热键）

const wchar_t* kHkDlgClass = L"Traiectus_HotkeyDlg_v1";
const int      kHkSaveId   = 3001;
const int      kHkCancelId = 3002;

// 客户区尺寸（96dpi 设计值，无标题栏 → 窗口大小就等于客户区大小）
// 版面照配对确认框那套：左右留白 28、按钮 108x34、底部留白 ~18
const int kHkClientW = 420;
const int kHkClientH = 252;

// 配色：和配对确认框同一套（Apple 浅色）
const COLORREF kUiBg      = RGB(0xFA, 0xFA, 0xFA);
const COLORREF kUiTitle   = RGB(0x1D, 0x1D, 0x1F);
const COLORREF kUiBody    = RGB(0x6E, 0x6E, 0x73);
const COLORREF kUiError   = RGB(0xC0, 0x30, 0x30);
const COLORREF kUiBorder  = RGB(0xD2, 0xD2, 0xD7);
const COLORREF kUiPress   = RGB(0xEC, 0xEC, 0xF0);

HBRUSH UiBgBrush() {
    static HBRUSH b = ::CreateSolidBrush(kUiBg);     // 进程内一份，不用释放
    return b;
}

HFONT UiFont(int pt, bool bold) {
    HDC dc = ::GetDC(NULL);
    LOGFONTW lf{};
    lf.lfHeight         = -::MulDiv(pt, ::GetDeviceCaps(dc, LOGPIXELSY), 72);
    ::ReleaseDC(NULL, dc);
    lf.lfWeight         = bold ? FW_SEMIBOLD : FW_NORMAL;
    lf.lfCharSet        = DEFAULT_CHARSET;
    lf.lfQuality        = CLEARTYPE_QUALITY;
    ::lstrcpynW(lf.lfFaceName, L"Segoe UI", LF_FACESIZE);
    return ::CreateFontIndirectW(&lf);
}

// Win11 的圆角窗口（老系统上这个调用不存在，静默跳过）
void UiRoundCorners(HWND hwnd) {
    HMODULE dwm = ::LoadLibraryW(L"dwmapi.dll");
    if (dwm == nullptr) return;
    typedef HRESULT (WINAPI *SetAttr)(HWND, DWORD, LPCVOID, DWORD);
    auto fn = reinterpret_cast<SetAttr>(
        reinterpret_cast<void*>(::GetProcAddress(dwm, "DwmSetWindowAttribute")));
    if (fn != nullptr) {
        const DWORD DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        const int   DWMWCP_ROUND = 2;
        fn(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &DWMWCP_ROUND, sizeof(DWMWCP_ROUND));
    }
    ::FreeLibrary(dwm);
}

struct HkDlg {
    std::wstring combo;        // 规范化写法；"off" = 不使用热键
    bool         haveValue = false;
    bool         accepted  = false;
    COLORREF     hintColor = RGB(0x6E, 0x6E, 0x73);
    HWND         hwnd = nullptr, captionText = nullptr, comboText = nullptr, hint = nullptr, saveBtn = nullptr;
    HFONT        fCaption = nullptr, fCombo = nullptr, fBody = nullptr, fSmall = nullptr;
};

// 把当前的修饰键状态 + 主键拼成规范写法（顺序固定 Ctrl+Alt+Shift+Win，和两端一致）
std::wstring ComposeHotkey(unsigned mods, unsigned vk) {
    std::wstring s;
    if (mods & MOD_CONTROL) s += L"Ctrl+";
    if (mods & MOD_ALT)     s += L"Alt+";
    if (mods & MOD_SHIFT)   s += L"Shift+";
    if (mods & MOD_WIN)     s += L"Win+";
    if (vk >= 'A' && vk <= 'Z')      s.push_back((wchar_t)vk);
    else if (vk >= '0' && vk <= '9') s.push_back((wchar_t)vk);
    else                             s += L"F" + std::to_wstring((int)vk - (int)VK_F1 + 1);
    return s;
}

void HkSetHint(HkDlg* d, const wchar_t* text, COLORREF color) {
    ::SetWindowTextW(d->hint, text);
    d->hintColor = color;
    ::InvalidateRect(d->hint, NULL, TRUE);
}

// 自绘按钮：圆角 6px、白底描边黑字，和配对确认框一致
void UiDrawButton(const DRAWITEMSTRUCT* di, HFONT font, const wchar_t* label) {
    HDC dc = di->hDC;
    RECT r = di->rcItem;
    const bool pressed = (di->itemState & ODS_SELECTED) != 0;
    const bool disabled = (di->itemState & ODS_DISABLED) != 0;

    HBRUSH  br  = ::CreateSolidBrush(pressed ? kUiPress : RGB(0xFF, 0xFF, 0xFF));
    HPEN    pen = ::CreatePen(PS_SOLID, 1, kUiBorder);
    HGDIOBJ ob  = ::SelectObject(dc, br);
    HGDIOBJ op  = ::SelectObject(dc, pen);
    ::RoundRect(dc, r.left, r.top, r.right, r.bottom, 12, 12);
    ::SelectObject(dc, ob);
    ::SelectObject(dc, op);
    ::DeleteObject(br);
    ::DeleteObject(pen);

    ::SetBkMode(dc, TRANSPARENT);
    ::SetTextColor(dc, disabled ? RGB(0xA0, 0xA0, 0xA5) : kUiTitle);
    HGDIOBJ of = ::SelectObject(dc, font);
    ::DrawTextW(dc, label, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    ::SelectObject(dc, of);
}

// ---------------------------------------------------------------------------
//  统一样式的对话框（替代托盘里所有系统 MessageBoxW）
// ---------------------------------------------------------------------------
//  外观和配对确认框/改键小窗完全一致：无标题栏圆角浮层、浅色面板、自绘圆角按钮。
//  文本里的 \n 会按行排；窗口高度随行数长。
//  回车 = 确定，Esc = 取消（单按钮时 Esc 也是关闭）。

const wchar_t* kMsgDlgClass = L"Traiectus_MsgDlg_v1";
const int      kMsgOkId     = 5001;
const int      kMsgCancelId = 5002;

struct MsgDlg {
    std::wstring title, body;
    std::wstring okText, cancelText;
    bool         withCancel = false;
    bool         accepted   = false;      // 点了确定/是
    HWND         hwnd = nullptr;
    HFONT        fTitle = nullptr, fBody = nullptr;
};

LRESULT CALLBACK MsgDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    MsgDlg* d = reinterpret_cast<MsgDlg*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
    case WM_NCCREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return TRUE;
    }
    case WM_CREATE: {
        d->fTitle = UiFont(13, true);
        d->fBody  = UiFont(11, false);

        // 正文按 \n 拆行，每行一个静态文本（12pt 行高 22）
        int y = 58;
        std::wstring line;
        std::vector<std::wstring> lines;
        for (wchar_t c : d->body) {
            if (c == L'\n') { lines.push_back(line); line.clear(); }
            else            line.push_back(c);
        }
        lines.push_back(line);
        for (const std::wstring& s : lines) {
            HWND c = ::CreateWindowExW(0, L"STATIC", s.c_str(),
                                       WS_CHILD | WS_VISIBLE | SS_LEFT,
                                       28, y, 404, 22, hwnd, NULL, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)d->fBody, TRUE);
            y += 22;
        }
        const int by = y + 14;

        auto button = [&](const wchar_t* s, int id, int x) {
            HWND c = ::CreateWindowExW(0, L"BUTTON", s,
                                       WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                       x, by, 108, 34, hwnd, (HMENU)(INT_PTR)id, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)d->fBody, TRUE);
        };
        if (d->withCancel) {
        button(d->cancelText.empty() ? L("取消").c_str() : d->cancelText.c_str(), kMsgCancelId, 116);
        button(d->okText.empty()     ? L("确定").c_str() : d->okText.c_str(),     kMsgOkId,     236);
        } else {
        button(d->okText.empty() ? L("确定").c_str() : d->okText.c_str(), kMsgOkId, 176);
        }

        if (!d->title.empty()) {
            HWND t = ::CreateWindowExW(0, L"STATIC", d->title.c_str(),
                                       WS_CHILD | WS_VISIBLE | SS_LEFT,
                                       28, 26, 404, 24, hwnd, NULL, NULL, NULL);
            ::SendMessageW(t, WM_SETFONT, (WPARAM)d->fTitle, TRUE);
        }
        return 0;
    }
    case WM_DRAWITEM: {
        auto* di = reinterpret_cast<DRAWITEMSTRUCT*>(lp);
        if (d == nullptr) return TRUE;
    if (di->CtlID == kMsgOkId)     UiDrawButton(di, d->fBody, d->okText.empty() ? L("确定").c_str() : d->okText.c_str());
    else if (di->CtlID == kMsgCancelId) UiDrawButton(di, d->fBody, d->cancelText.empty() ? L("取消").c_str() : d->cancelText.c_str());
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = reinterpret_cast<HDC>(wp);
        ::SetBkMode(dc, TRANSPARENT);
        ::SetTextColor(dc, kUiTitle);
        return (LRESULT)UiBgBrush();
    }
    case WM_COMMAND:
        if (LOWORD(wp) == kMsgOkId)          { d->accepted = true; ::DestroyWindow(hwnd); }
        else if (LOWORD(wp) == kMsgCancelId) { ::DestroyWindow(hwnd); }
        return 0;
    case WM_KEYDOWN:
        if ((unsigned)wp == VK_RETURN)      { d->accepted = true; ::DestroyWindow(hwnd); }
        else if ((unsigned)wp == VK_ESCAPE) { ::DestroyWindow(hwnd); }
        return 0;
    case WM_CLOSE:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (d != nullptr) {
            for (HFONT f : { d->fTitle, d->fBody })
                if (f != nullptr) ::DeleteObject(f);
            d->fTitle = d->fBody = nullptr;
            d->hwnd = nullptr;
        }
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wp, lp);
    }
}

bool ShowStyledDialog(const std::wstring& title, const std::wstring& body, bool withCancel,
                      const std::wstring& okText, const std::wstring& cancelText) {
    // 正文按像素宽度**硬换行**：路径这种没有空格的串，STATIC 不会自己折行，
    // 不处理就会被窗口右边裁掉（第一版就踩了：长路径显示成 ...phase3-tcp\pai）。
    // 放在建窗之前做，这样窗口高度能按换行后的行数算对。
    const int kTextPx = 396;                       // 460 宽 - 左右各 28 再留 4
    std::wstring wrapped;
    {
        HFONT f = UiFont(11, false);
        HDC dc = ::GetDC(NULL);
        HGDIOBJ old = ::SelectObject(dc, f);
        auto width = [&](const std::wstring& s) {
            if (s.empty()) return 0;
            SIZE sz{};
            ::GetTextExtentPoint32W(dc, s.c_str(), (int)s.size(), &sz);
            return (int)sz.cx;
        };
        std::wstring line;
        for (wchar_t c : body) {
            if (c == L'\n') { wrapped += line; wrapped += L'\n'; line.clear(); continue; }
            line.push_back(c);
            if (width(line) > kTextPx) {
                line.pop_back();
                wrapped += line; wrapped += L'\n';
                line.assign(1, c);
            }
        }
        wrapped += line;
        ::SelectObject(dc, old);
        ::ReleaseDC(NULL, dc);
        ::DeleteObject(f);
    }

    HINSTANCE hInst = ::GetModuleHandleW(NULL);
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_DROPSHADOW;
    wc.lpfnWndProc   = MsgDlgProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = kMsgDlgClass;
    wc.hCursor       = ::LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = UiBgBrush();
    if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    MsgDlg d;
    d.title      = title;
    d.body       = wrapped;
    d.okText     = okText.empty()     ? L("确定") : okText;
    d.cancelText = cancelText.empty() ? L("取消") : cancelText;
    d.withCancel = withCancel;

    int lineCount = 1;
    for (wchar_t c : wrapped) if (c == L'\n') ++lineCount;
    const int W = 460;
    const int H = 58 + lineCount * 22 + 14 + 34 + 20;
    const int x = (::GetSystemMetrics(SM_CXSCREEN) - W) / 2;
    const int y = (::GetSystemMetrics(SM_CYSCREEN) - H) / 2;

    HWND hwnd = ::CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kMsgDlgClass,
                                  title.empty() ? APP_TITLE : title.c_str(),
                                  WS_POPUP, x, y, W, H, NULL, NULL, hInst, &d);
    if (hwnd == nullptr) return false;
    d.hwnd = hwnd;
    UiRoundCorners(hwnd);
    ::ShowWindow(hwnd, SW_SHOWNORMAL);
    ::UpdateWindow(hwnd);
    ::SetForegroundWindow(hwnd);
    ::SetFocus(hwnd);

    MSG msg;
    while (::IsWindow(hwnd)) {
        while (::PeekMessageW(&msg, hwnd, 0, 0, PM_REMOVE)) {
            ::TranslateMessage(&msg);
            ::DispatchMessageW(&msg);
        }
        ::Sleep(5);
    }
    return d.accepted;
}

// ---------------------------------------------------------------------------
//  提示条 ShowToast：右下角冒出来、3 秒后自己消失、不抢焦点
// ---------------------------------------------------------------------------
//  用途：需要"立刻让人看到、但不想挡操作"的场合（比如开始检测鼠标）。
//  和 MsgDlg 共用配色/字体/圆角，但不带按钮 —— 点一下或按 Esc 可以提前关掉。

const wchar_t* kToastClass = L"Traiectus_Toast_v1";

struct Toast {
    std::wstring title, body;
    HWND         hwnd = nullptr;
    HFONT        fTitle = nullptr, fBody = nullptr;
};

LRESULT CALLBACK ToastProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    Toast* t = reinterpret_cast<Toast*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
    case WM_NCCREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return TRUE;
    }
    case WM_CREATE: {
        t->fTitle = UiFont(12, true);
        t->fBody  = UiFont(10, false);
        HWND a = ::CreateWindowExW(0, L"STATIC", t->title.c_str(),
                                   WS_CHILD | WS_VISIBLE | SS_LEFT,
                                   18, 14, 384, 20, hwnd, NULL, NULL, NULL);
        ::SendMessageW(a, WM_SETFONT, (WPARAM)t->fTitle, TRUE);
        HWND b = ::CreateWindowExW(0, L"STATIC", t->body.c_str(),
                                   WS_CHILD | WS_VISIBLE | SS_LEFT,
                                   18, 38, 384, 20, hwnd, NULL, NULL, NULL);
        ::SendMessageW(b, WM_SETFONT, (WPARAM)t->fBody, TRUE);
        return 0;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = reinterpret_cast<HDC>(wp);
        ::SetBkMode(dc, TRANSPARENT);
        ::SetTextColor(dc, kUiTitle);
        return (LRESULT)UiBgBrush();
    }
    case WM_TIMER:
        ::KillTimer(hwnd, 1);
        ::DestroyWindow(hwnd);
        return 0;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_KEYDOWN:
        if ((unsigned)wp == VK_ESCAPE) { ::DestroyWindow(hwnd); return 0; }
        return 0;
    case WM_CLOSE:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (t != nullptr) {
            for (HFONT f : { t->fTitle, t->fBody })
                if (f != nullptr) ::DeleteObject(f);
            t->fTitle = t->fBody = nullptr;
            t->hwnd = nullptr;
        }
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wp, lp);
    }
}

void ShowToast(const std::wstring& title, const std::wstring& body, unsigned ms) {
    HINSTANCE hInst = ::GetModuleHandleW(NULL);
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_DROPSHADOW;
    wc.lpfnWndProc   = ToastProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = kToastClass;
    wc.hCursor       = ::LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = UiBgBrush();
    if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;

    Toast t;
    t.title = title;
    t.body  = body;

    const int W = 420, H = 74;
    const int x = ::GetSystemMetrics(SM_CXSCREEN) - W - 24;      // 右下角，贴着托盘
    const int y = ::GetSystemMetrics(SM_CYSCREEN) - H - 72;      // 留出任务栏

    HWND hwnd = ::CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
    kToastClass, L("Traiectus 提示").c_str(),
                                  WS_POPUP, x, y, W, H, NULL, NULL, hInst, &t);
    if (hwnd == nullptr) return;
    t.hwnd = hwnd;
    UiRoundCorners(hwnd);
    // 注意：不改变 g_nid、不抢焦点（WS_EX_NOACTIVATE），只是"冒出来一条提示"
    ::SetTimer(hwnd, 1, ms, NULL);
    ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    ::UpdateWindow(hwnd);

    // 自己跑一小段消息循环，到点或点一下就消失；托盘的消息留在队列里不受影响
    MSG msg;
    while (::IsWindow(hwnd)) {
        while (::PeekMessageW(&msg, hwnd, 0, 0, PM_REMOVE)) {
            ::TranslateMessage(&msg);
            ::DispatchMessageW(&msg);
        }
        ::Sleep(5);
    }
}

LRESULT CALLBACK HkDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    HkDlg* d = reinterpret_cast<HkDlg*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_NCCREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return TRUE;
    }
    case WM_CREATE: {
        d->fCaption = UiFont(13, true);
        d->fCombo   = UiFont(20, true);
        d->fBody    = UiFont(11, false);
        d->fSmall   = UiFont(9,  false);

        auto label = [&](const wchar_t* s, HFONT f, int x, int y, int w, int hgt) {
            HWND c = ::CreateWindowExW(0, L"STATIC", s,
                                       WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE,
                                       x, y, w, hgt, hwnd, NULL, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)f, TRUE);
            return c;
        };
        auto button = [&](const wchar_t* s, int id, int x) {
            HWND c = ::CreateWindowExW(0, L"BUTTON", s,
                                       WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                       x, 200, 108, 34, hwnd, (HMENU)(INT_PTR)id, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)d->fBody, TRUE);
            return c;
        };

        // 版面：标题 → 动态提示 → 大字组合键 → 支持范围两行 → 按钮（居中）
        d->captionText = label(L("设置鼠标切换快捷键").c_str(), d->fCaption, 28, 24, 364, 24);
        d->hint = label(L("请按下你想要的组合键").c_str(), d->fBody, 28, 58, 364, 22);
        d->comboText = label(d->combo.empty() ? L"—" : d->combo.c_str(),
                             d->fCombo, 28, 92, 364, 46);
        label(L("修饰键：Ctrl / Alt / Shift / Win（至少 1 个）").c_str(), d->fSmall, 28, 150, 364, 18);
        label(L("主键：A–Z / 0–9 / F1–F24").c_str(), d->fSmall, 28, 170, 364, 18);

        d->saveBtn = button(L("保存").c_str(), kHkSaveId,   96);
        button(L("取消").c_str(), kHkCancelId, 216);
        ::EnableWindow(d->saveBtn, d->haveValue ? TRUE : FALSE);
        return 0;
    }
    case WM_DRAWITEM: {
        auto* di = reinterpret_cast<DRAWITEMSTRUCT*>(lp);
        if (d == nullptr) return TRUE;
        if (di->CtlID == kHkSaveId)        UiDrawButton(di, d->fBody, L("保存").c_str());
        else if (di->CtlID == kHkCancelId) UiDrawButton(di, d->fBody, L("取消").c_str());
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = reinterpret_cast<HDC>(wp);
        ::SetBkMode(dc, TRANSPARENT);
        if (d != nullptr && (HWND)lp == d->hint)        ::SetTextColor(dc, d->hintColor);
        else if (d != nullptr && (HWND)lp == d->comboText) ::SetTextColor(dc, kUiTitle);
        else if (d != nullptr && (HWND)lp == d->captionText) ::SetTextColor(dc, kUiTitle);
        else                                            ::SetTextColor(dc, kUiBody);
        return (LRESULT)UiBgBrush();
    }
    case WM_COMMAND:
        if (LOWORD(wp) == kHkSaveId && d->haveValue) {
            d->accepted = true;
            ::DestroyWindow(hwnd);
        } else if (LOWORD(wp) == kHkCancelId) {
            ::DestroyWindow(hwnd);
        }
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        const unsigned vk = (unsigned)wp;

        if (vk == VK_ESCAPE) {                                     // Esc = 取消
            ::DestroyWindow(hwnd);
            return 0;
        }
        if (vk == VK_RETURN) {                                     // 回车 = 保存（有效时）
            if (d->haveValue) { d->accepted = true; ::DestroyWindow(hwnd); }
            return 0;
        }
        if (vk == VK_DELETE || vk == VK_BACK) {                    // 清空 = off
            d->combo = L"off";
            d->haveValue = true;
    ::SetWindowTextW(d->comboText, L("不使用热键").c_str());
    HkSetHint(d, L("保存后不再占用任何组合键").c_str(), kUiBody);
            ::EnableWindow(d->saveBtn, TRUE);
            return 0;
        }
        // 只按修饰键：等主键，不做判定
        if (vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT ||
            vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL ||
            vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU ||
            vk == VK_LWIN || vk == VK_RWIN) {
    HkSetHint(d, L("继续按主键…").c_str(), kUiBody);
            return 0;
        }

        unsigned mods = 0;
        if (::GetKeyState(VK_CONTROL) & 0x8000) mods |= MOD_CONTROL;
        if (::GetKeyState(VK_MENU)    & 0x8000) mods |= MOD_ALT;
        if (::GetKeyState(VK_SHIFT)   & 0x8000) mods |= MOD_SHIFT;
        if ((::GetKeyState(VK_LWIN) & 0x8000) || (::GetKeyState(VK_RWIN) & 0x8000)) mods |= MOD_WIN;

        const bool isAlpha = (vk >= 'A' && vk <= 'Z');
        const bool isDigit = (vk >= '0' && vk <= '9');
        const bool isFunc  = (vk >= VK_F1 && vk <= VK_F24);
        if (!isAlpha && !isDigit && !isFunc) {
    HkSetHint(d, L("这个键不支持：主键只认 A–Z / 0–9 / F1–F24").c_str(), kUiError);
            return 0;
        }
        if (mods == 0) {
    HkSetHint(d, L("至少要有 1 个修饰键，否则会毁掉正常打字").c_str(), kUiError);
            d->haveValue = false;
            ::EnableWindow(d->saveBtn, FALSE);
            ::InvalidateRect(d->saveBtn, NULL, TRUE);
            return 0;
        }

        d->combo = ComposeHotkey(mods, vk);
        d->haveValue = true;
        ::SetWindowTextW(d->comboText, d->combo.c_str());
    HkSetHint(d, L("按「保存」后服务端会重启，新组合键立刻生效").c_str(), kUiBody);
        ::EnableWindow(d->saveBtn, TRUE);
        ::InvalidateRect(d->saveBtn, NULL, TRUE);
        return 0;
    }
    case WM_CLOSE:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (d != nullptr) {
            for (HFONT f : { d->fCaption, d->fCombo, d->fBody, d->fSmall })
                if (f != nullptr) ::DeleteObject(f);
            d->fCaption = d->fCombo = d->fBody = d->fSmall = nullptr;
            d->hwnd = nullptr;
        }
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wp, lp);
    }
}

// 返回 true = 用户点了保存（结果在 outCombo 里）；false = 取消
bool ShowHotkeyDialog(HWND owner, const std::wstring& current, std::wstring& outCombo) {
    (void)owner;
    HINSTANCE hInst = ::GetModuleHandleW(NULL);
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_DROPSHADOW;
    wc.lpfnWndProc   = HkDlgProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = kHkDlgClass;
    wc.hCursor       = ::LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = UiBgBrush();
    if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    HkDlg d;
    d.combo     = current;                   // 先显示当前值
    d.haveValue = !current.empty();          // 当前值可以直接点保存

    // 无标题栏 → 窗口大小就是客户区大小；放在**屏幕正中**（用户要求）
    const int W = kHkClientW, H = kHkClientH;
    const int x = (::GetSystemMetrics(SM_CXSCREEN) - W) / 2;
    const int y = (::GetSystemMetrics(SM_CYSCREEN) - H) / 2;

    HWND hwnd = ::CreateWindowExW(WS_EX_TOOLWINDOW, kHkDlgClass, L("设置鼠标切换快捷键").c_str(),
                                  WS_POPUP, x, y, W, H, NULL, NULL, hInst, &d);
    if (hwnd == nullptr) return false;
    d.hwnd = hwnd;

    UiRoundCorners(hwnd);
    ::ShowWindow(hwnd, SW_SHOWNORMAL);
    ::UpdateWindow(hwnd);
    ::SetForegroundWindow(hwnd);
    ::SetFocus(hwnd);                        // 按键必须落到这个窗上

    // 注意：**不能**用「按窗口过滤的 GetMessage」—— 窗口销毁后它永远等不到消息，
    // 循环条件再也不会被重新求值，托盘会直接冻住。用 PeekMessage 轮询最稳。
    MSG msg;
    while (::IsWindow(hwnd)) {
        while (::PeekMessageW(&msg, hwnd, 0, 0, PM_REMOVE)) {
            ::TranslateMessage(&msg);
            ::DispatchMessageW(&msg);
        }
        ::Sleep(5);
    }
    if (d.accepted) { outCombo = d.combo; return true; }
    return false;
}

// ---------------------------------------------------------------------------
//  设备候选选择窗（DEVICE MULTI 时弹：多个设备都动过，让用户点一个）
// ---------------------------------------------------------------------------
//  视觉和改键小窗一致：无标题栏圆角浮层 + 自绘圆角按钮；中间是设备串列表，
//  双击某一行等于直接确定。

const wchar_t* kDevDlgClass = L"Traiectus_DevicePick_v1";
const int      kDevListId   = 4001;
const int      kDevOkId     = 4002;
const int      kDevCancelId = 4003;

struct DevDlg {
    std::vector<std::wstring> items;
    std::wstring picked;
    bool         accepted = false;
    HWND         hwnd = nullptr, list = nullptr;
    HFONT        fTitle = nullptr, fBody = nullptr, fSmall = nullptr;
};

LRESULT CALLBACK DevDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    DevDlg* d = reinterpret_cast<DevDlg*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
    case WM_NCCREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        return TRUE;
    }
    case WM_CREATE: {
        d->fTitle = UiFont(13, true);
        d->fBody  = UiFont(11, false);
        d->fSmall = UiFont(9,  false);

        const size_t nItems = d->items.empty() ? 1 : (d->items.size() > 6 ? 6 : d->items.size());
        const int listH = (int)nItems * 22 + 10;
        auto label = [&](const wchar_t* s, HFONT f, int x, int y, int w, int hgt) {
            HWND c = ::CreateWindowExW(0, L"STATIC", s, WS_CHILD | WS_VISIBLE | SS_LEFT,
                                       x, y, w, hgt, hwnd, NULL, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)f, TRUE);
            return c;
        };
        // 标题别太长 —— 单行 STATIC 不会折行，超了会被窗口右边直接裁掉（实测踩过）
        label(L("检测到多个设备，请选一个").c_str(), d->fTitle, 28, 24, 404, 24);

        d->list = ::CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", NULL,
                                    WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_TABSTOP | LBS_NOTIFY,
                                    28, 56, 404, listH, hwnd, (HMENU)(INT_PTR)kDevListId, NULL, NULL);
        ::SendMessageW(d->list, WM_SETFONT, (WPARAM)d->fBody, TRUE);
        for (const std::wstring& s : d->items)
            ::SendMessageW(d->list, LB_ADDSTRING, 0, (LPARAM)s.c_str());
        if (!d->items.empty()) ::SendMessageW(d->list, LB_SETCURSEL, 0, 0);

        label(L("以后换鼠标：托盘右键 →「检测鼠标」再跑一次").c_str(), d->fSmall,
              28, 56 + listH + 8, 404, 18);

        const int by = 56 + listH + 8 + 18 + 12;
        auto button = [&](const wchar_t* s, int id, int x) {
            HWND c = ::CreateWindowExW(0, L"BUTTON", s,
                                       WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                       x, by, 108, 34, hwnd, (HMENU)(INT_PTR)id, NULL, NULL);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)d->fBody, TRUE);
            return c;
        };
        button(L("确定").c_str(), kDevOkId,     116);
        button(L("取消").c_str(), kDevCancelId, 236);
        return 0;
    }
    case WM_DRAWITEM: {
        auto* di = reinterpret_cast<DRAWITEMSTRUCT*>(lp);
        if (d == nullptr) return TRUE;
        if (di->CtlID == kDevOkId)          UiDrawButton(di, d->fBody, L("确定").c_str());
        else if (di->CtlID == kDevCancelId) UiDrawButton(di, d->fBody, L("取消").c_str());
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = reinterpret_cast<HDC>(wp);
        ::SetBkMode(dc, TRANSPARENT);
        ::SetTextColor(dc, kUiTitle);
        return (LRESULT)UiBgBrush();
    }
    case WM_COMMAND: {
        const int id = LOWORD(wp);
        const bool dbl = (id == kDevListId && HIWORD(wp) == LBN_DBLCLK);
        if (id == kDevOkId || dbl) {
            const int sel = (int)::SendMessageW(d->list, LB_GETCURSEL, 0, 0);
            if (sel != LB_ERR && sel >= 0 && sel < (int)d->items.size()) {
                d->picked   = d->items[(size_t)sel];
                d->accepted = true;
                ::DestroyWindow(hwnd);
            }
        } else if (id == kDevCancelId) {
            ::DestroyWindow(hwnd);
        }
        return 0;
    }
    case WM_KEYDOWN:
        if ((unsigned)wp == VK_ESCAPE) { ::DestroyWindow(hwnd); return 0; }
        if ((unsigned)wp == VK_RETURN) {
            const int sel = (int)::SendMessageW(d->list, LB_GETCURSEL, 0, 0);
            if (sel != LB_ERR && sel >= 0 && sel < (int)d->items.size()) {
                d->picked   = d->items[(size_t)sel];
                d->accepted = true;
                ::DestroyWindow(hwnd);
            }
            return 0;
        }
        return 0;
    case WM_CLOSE:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (d != nullptr) {
            for (HFONT f : { d->fTitle, d->fBody, d->fSmall })
                if (f != nullptr) ::DeleteObject(f);
            d->fTitle = d->fBody = d->fSmall = nullptr;
            d->hwnd = nullptr;
        }
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wp, lp);
    }
}

bool ShowDevicePicker(const std::vector<std::wstring>& cand, std::wstring& out) {
    HINSTANCE hInst = ::GetModuleHandleW(NULL);
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_DROPSHADOW;
    wc.lpfnWndProc   = DevDlgProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = kDevDlgClass;
    wc.hCursor       = ::LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = UiBgBrush();
    if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    DevDlg d;
    d.items = cand;

    const size_t nItems = d.items.empty() ? 1 : (d.items.size() > 6 ? 6 : d.items.size());
    const int listH = (int)nItems * 22 + 10;
    const int W = 460;
    const int H = 56 + listH + 8 + 18 + 12 + 34 + 20;
    const int x = (::GetSystemMetrics(SM_CXSCREEN) - W) / 2;
    const int y = (::GetSystemMetrics(SM_CYSCREEN) - H) / 2;

    HWND hwnd = ::CreateWindowExW(WS_EX_TOOLWINDOW, kDevDlgClass, L("选择鼠标设备").c_str(),
                                  WS_POPUP, x, y, W, H, NULL, NULL, hInst, &d);
    if (hwnd == nullptr) return false;
    d.hwnd = hwnd;
    UiRoundCorners(hwnd);
    ::ShowWindow(hwnd, SW_SHOWNORMAL);
    ::UpdateWindow(hwnd);
    ::SetForegroundWindow(hwnd);
    ::SetFocus(d.list);

    MSG msg;
    while (::IsWindow(hwnd)) {
        while (::PeekMessageW(&msg, hwnd, 0, 0, PM_REMOVE)) {
            ::TranslateMessage(&msg);
            ::DispatchMessageW(&msg);
        }
        ::Sleep(5);
    }
    if (d.accepted) { out = d.picked; return true; }
    return false;
}

// 切换界面语言：立刻重建菜单与 tooltip（不重启进程），并把选择写回 config.ini。
//   刻意**不重启服务端** —— 按约定「托盘菜单 / tooltip 立即生效，其它下一次打开时生效」。
//   下一次拉起服务端时，StartServices() 会把新的 --lang 透传过去。
static void SetLanguage(Lang l) {
    if (I18nLang() == l) return;                  // 已经是这个语言：不写盘、不折腾
    SetLang(l);
    SaveUiLanguageToConfig(IsEnglish() ? L"en" : L"zh");
    UpdateTray();
}

static void ShowMenu(HWND hwnd) {
    HMENU m = ::CreatePopupMenu();

    // 状态区三行：状态 / 鼠标切换 / 鼠标设备。
    // 为什么拆成三行而不是"一行里用空格缩进"：菜单用的是**比例字体**，
    // 空格根本对不齐（用户提过）；各自一行才天然左对齐。
    const std::wstring status = g_error   ? (g_errorWhy.empty() ? L("状态：异常") : g_errorWhy)
                              : g_running ? L("状态：运行中")
                                          : L("状态：已停止");
    ::AppendMenuW(m, MF_STRING | MF_GRAYED, 0, status.c_str());

    // 本机 IP：每次开菜单现查一次，随时和 ipconfig 对得上（2026-10-07 任务单 §2.4-2）。
    //   查"当前默认路由那张网卡"，所以不会显示 Tailscale / 虚拟网卡的地址。
    //   查不到就显示一个破折号 —— 只影响这一行，别的行照常。
    {
        const NetInfo ni = QueryDefaultRouteNet();
        const std::wstring ipLine = L("本机 IP：") + (ni.valid ? ni.ip : std::wstring(L"—"));
        ::AppendMenuW(m, MF_STRING | MF_GRAYED, 0, ipLine.c_str());
    }

    if (g_running && !g_error) {
        const std::wstring hk = HotkeyMenuSuffix();      // 读日志里的 HOTKEY 行
        if (!hk.empty()) ::AppendMenuW(m, MF_STRING | MF_GRAYED, 0, hk.c_str());
        const std::wstring dv = DeviceMenuSuffix();      // 读日志里的 DEVICE 行
        if (!dv.empty()) ::AppendMenuW(m, MF_STRING | MF_GRAYED, 0, dv.c_str());
    }
    ::AppendMenuW(m, MF_SEPARATOR, 0, NULL);

    // 菜单项**不带结尾的省略号**（用户 2026-10-07 要求去掉）。
    ::AppendMenuW(m, MF_STRING, IDM_HOTKEY, L("设置鼠标切换快捷键").c_str());
    const std::wstring detectItem = g_detecting ? L("正在检测鼠标…（动一下鼠标）") : L("检测鼠标");
    ::AppendMenuW(m, MF_STRING | (g_detecting ? MF_GRAYED : 0), IDM_DETECT, detectItem.c_str());
    ::AppendMenuW(m, MF_SEPARATOR, 0, NULL);

    if (g_running) {
        ::AppendMenuW(m, MF_STRING, IDM_RESTART, L("重启").c_str());
    } else {
        ::AppendMenuW(m, MF_STRING, IDM_START, L("启动 Traiectus").c_str());
    }

    // 顺序（用户 2026-10-01 指定）：「重新配对」在「打开日志目录」之前
    // 口令只有配对文件这一个来源 → 这一项永远可点（不再有"用 --token 所以置灰"的分支）
    ::AppendMenuW(m, MF_STRING, IDM_UNPAIR, L("重新配对").c_str());
    ::AppendMenuW(m, MF_STRING, IDM_LOGS, L("打开日志目录").c_str());
    ::AppendMenuW(m, MF_SEPARATOR, 0, NULL);

    // 「语言 / Language」子菜单：两项各自用本语言书写，**不翻译**。
    //   点一下立刻重建菜单与 tooltip（不重启进程），并写回 config.ini 的 [ui] language。
    //   DestroyMenu(m) 会把子菜单一起销毁，不用单独释放。
    HMENU langMenu = ::CreatePopupMenu();
    ::AppendMenuW(langMenu, MF_STRING | (IsEnglish() ? 0 : MF_CHECKED), IDM_LANG_ZH, L"中文");
    ::AppendMenuW(langMenu, MF_STRING | (IsEnglish() ? MF_CHECKED : 0), IDM_LANG_EN, L"English");
    ::AppendMenuW(m, MF_POPUP, (UINT_PTR)langMenu, L("语言").c_str());

    ::AppendMenuW(m, MF_STRING, IDM_EXIT, L("退出").c_str());

    POINT pt = {};
    ::GetCursorPos(&pt);
    ::SetForegroundWindow(hwnd);            // 不这样 TrackPopupMenu 关不干净
    ::TrackPopupMenu(m, TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, NULL);
    ::DestroyMenu(m);
}

static void OpenLogs() {
    ::ShellExecuteW(NULL, L"open", g_exeDir.c_str(), NULL, NULL, SW_SHOWNORMAL);
}

// ---------------------------------------------------------------------------
//  鼠标设备识别：入口 + 轮询
// ---------------------------------------------------------------------------
//  两种触发：
//    · 启动时 config.ini 里没有 --device → 服务端自己观察 8 秒并打 DEVICE PICK
//      → 托盘把它写回 config.ini 并重启一次（之后就只转发那一只鼠标）
//    · 用户点「检测鼠标」→ 这次启动临时附 --detect 强制重跑识别
//  都靠读日志里的机器可读行，不引入新协议/新文件。

static void StartDeviceDetect() {
    if (g_detecting) return;
    g_detecting    = true;
    g_detectPolled = 0;
    StopServices();
    StartServices();                 // StartServices 会看到 g_detecting 并附上 --detect
    UpdateTray();
    // 手动点这一项时**必须有立刻的反馈**（用户反馈"点了没反应"：
    // 其实检测是成功的，只是按方案 A 成功不弹框，看起来就像没动）。
    // 这里用托盘气泡：不挡那 8 秒的观察窗口，又能马上告诉用户该干什么。
    SetTip(L("Traiectus：正在检测鼠标…（请动一下鼠标）").c_str());
    ShowToast(L("正在检测鼠标"), L("请在 8 秒内晃动你要用的那只鼠标。"), 3000);
}

static void PollDeviceDetect() {
    const DeviceStatus ds = ReadDeviceStatus();

    if (!g_detecting) {
        // 启动时没配 --device：服务端自己挑出来的那只 → 写回 config.ini 并重启
        if (ds.state == 1 && g_running && !ds.pick.empty() &&
            g_cfg.serverArgs.find(ds.pick) == std::wstring::npos) {
            if (SaveDeviceToConfig(ds.pick)) {
                StopServices();
                StartServices();
                UpdateTray();
            }
        }
        return;
    }

// 用户点的「检测鼠标」：等这一轮的结论
    ++g_detectPolled;

    if (ds.state == 1) {
        g_detecting = false;
        const bool ok = SaveDeviceToConfig(ds.pick);
        StopServices(); StartServices(); UpdateTray();
// 手动点「检测鼠标」是**用户主动要求的操作**，成功也要给结果
        // （方案 A 的"成功静默"只针对启动时的自动识别 —— 那个不该打扰人）。
        if (ok) {
            ShowStyledDialog(L("已锁定这只鼠标"),
                ds.pick + L("\n\n已写进 config.ini，以后只转发它。"), false);
        } else {
            ShowStyledDialog(L("检测成功，但没写进配置"),
                L("检测到这只鼠标：\n") + ds.pick +
                L("\n\n但写 config.ini 失败（文件被占用/只读？）。"), false);
        }
        return;
    }
    if (ds.state == 2) {
        std::wstring picked;
        const bool ok = ShowDevicePicker(ds.cand, picked) && !picked.empty()
                        && SaveDeviceToConfig(picked);
        g_detecting = false;
        StopServices(); StartServices(); UpdateTray();
        (void)ok;      // 用户主动取消 → 什么都不提示（他知道自己点了取消）
        return;
    }
    if (ds.state == 3) {
        g_detecting = false;
        StopServices(); StartServices(); UpdateTray();
        ShowStyledDialog(L("没检测到鼠标"),
            L("这 8 秒里没有鼠标移动。\n\n请再点一次「检测鼠标」，"
              L"然后在这 8 秒里晃动你要用的那只鼠标。"), false);
        return;
    }
    if (g_detectPolled > 30) {          // 兜底：30 秒还没结论就别一直等
        g_detecting = false;
        StopServices(); StartServices(); UpdateTray();
        ShowStyledDialog(L("检测超时"),
            L("30 秒没有结论，已恢复正常运行。\n可以点「检测鼠标」重试。"), false);
    }
}

// 每秒看一次子进程是否还活着
static void CheckHealth() {
    if (!g_running) return;

    PollDeviceDetect();

    DWORD code = 0;
    bool serverDead = false, bridgeDead = false;
    if (g_hServer && ::GetExitCodeProcess(g_hServer, &code) && code != STILL_ACTIVE) serverDead = true;
    if (g_hBridge && ::GetExitCodeProcess(g_hBridge, &code) && code != STILL_ACTIVE) bridgeDead = true;
    if (!serverDead && !bridgeDead) return;

    // 刻意不留"半死不活"的中间态：任一子进程没了，就把另一部分也收干净。
    // 否则剩下那个会变成没人管的野进程 —— 桥接尤其明显，它会继续往 Mac 发 UDP。
    TeardownProcesses();
    g_running  = false;
    g_error    = true;
    g_errorWhy = serverDead ? L("Traiectus：异常（服务端已退出）")
                            : L("Traiectus：异常（桥接已退出）");
    UpdateTray();
}

// ---------------------------------------------------------------------------
//  窗口过程
// ---------------------------------------------------------------------------
static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_TRAY:
        if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU || lp == WM_LBUTTONDBLCLK) {
            ShowMenu(hwnd);
        }
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDM_START:   StartServices();                UpdateTray(); break;
        case IDM_RESTART: StopServices(); StartServices(); UpdateTray(); break;
        case IDM_LOGS:    OpenLogs();                                   break;
        case IDM_UNPAIR:  DoUnpair(hwnd);                               break;
        case IDM_HOTKEY: {
            // 当前值从日志里的 HOTKEY 行拿；拿不到就让用户直接按
            const HotkeyStatus st = ReadHotkeyStatus();
            const std::wstring cur = (st.state == 3) ? std::wstring(L"off") : st.text;
            std::wstring picked;
            if (ShowHotkeyDialog(hwnd, cur, picked)) {
                if (SaveHotkeyToConfig(picked)) {
                    // 改键只在重启后生效（不做热更新：改键必然发生在游戏之外）
                    if (g_running) { StopServices(); StartServices(); }
                    UpdateTray();
                }
            }
            break;
        }
        case IDM_DETECT:  StartDeviceDetect();                          break;
        case IDM_LANG_ZH: SetLanguage(Lang::Zh);                        break;
        case IDM_LANG_EN: SetLanguage(Lang::En);                        break;
        case IDM_EXIT:    ::DestroyWindow(hwnd);                        break;
        }
        return 0;

    case WM_TIMER:
        if (wp == TIMER_HEALTH) CheckHealth();
        return 0;

    case WM_DESTROY:
        StopServices();
        RemoveTray();
        ::PostQuitMessage(0);
        return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------------------------------------------------------------------------
//  入口
// ---------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, LPWSTR, int) {
    // 语言要**最先**定：下面任何一句弹框（包括"单实例锁失败"）都得按它显示。
    //   GetExeDir() 只依赖 GetModuleFileNameW，随时可调。
    //   config.ini 这时候可能还不存在（首次运行），那是正常的 ——
    //   InitLanguage() 读不到 [ui] language 就跟随系统 UI 语言。
    g_exeDir = GetExeDir();
    InitLanguage();

    // 单实例：会话内唯一即可（托盘程序本来就是每个登录会话一个）
    HANDLE mtx = ::CreateMutexW(NULL, TRUE, APP_MUTEX);
    if (mtx == NULL) {
        ShowStyledDialog(L("启动失败"), L("创建单实例锁失败。"), false);
        return 1;
    }
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND old = ::FindWindowW(APP_WNDCLASS, NULL);
        if (old) ::PostMessageW(old, WM_TRAY, 0, WM_LBUTTONDBLCLK);
        return 0;
    }

    WSADATA wsa = {};
    ::WSAStartup(MAKEWORD(2, 2), &wsa);     // 只为 WaitServerReady 里的辅助判断备用

    ReadConfig();

    g_icoGreen = MakeDotIcon(RGB(0x2E, 0xC4, 0x4E));
    g_icoGray  = MakeDotIcon(RGB(0x88, 0x88, 0x88));
    g_icoRed   = MakeDotIcon(RGB(0xE0, 0x40, 0x40));

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = APP_WNDCLASS;
    ::RegisterClassExW(&wc);

    // 这个窗口从不显示，只用来接收托盘回调消息
    HWND hwnd = ::CreateWindowExW(0, APP_WNDCLASS, APP_TITLE, WS_OVERLAPPED,
                                  0, 0, 0, 0, NULL, NULL, hInst, NULL);
    if (!hwnd) return 1;

    AddTray(hwnd);
    CleanupStale();
    StartServices();
    UpdateTray();

    ::SetTimer(hwnd, TIMER_HEALTH, 1000, NULL);

    MSG msg;
    while (::GetMessageW(&msg, NULL, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
    }

    StopServices();
    ::WSACleanup();
    if (mtx) ::CloseHandle(mtx);
    return 0;
}
