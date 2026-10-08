// ============================================================================
//  Traiectus Server（Phase 3）
//  Windows 端：只读捕获鼠标（Raw Input），按 PROTOCOL.md 把鼠标事件转发给 Mac 客户端
// ----------------------------------------------------------------------------
//  用法（详见同目录 README.md）：
//      Traiectus-Server.exe --device "VID_xxxx&PID_xxxx&MI_00"
//
//  安全设计（Phase 1 的红线一条都没放松）：
//    * 只读捕获：不 hook、不拦截、不阻断、不注入、不用驱动、不需要管理员
//    * 不修改系统设置 / 注册表 / G HUB / DPI / 固件，不碰防火墙
//    * 网络只是"额外抄一份发出去"：网断了、Mac 关了、本程序崩了，
//      本机鼠标键盘都完全不受影响（因为从未被改变）
//
//  为什么"位移只发相对增量"：绝对坐标要两端换算分辨率和缩放，算错就跳指针。
//  这条写进协议，见 PROTOCOL.md 第 3 节。
// ============================================================================

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <bcrypt.h>

#include <atomic>
#include <algorithm>
#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "i18n.h"          // 界面文案的中英对照（和 launcher 那份内容一致）
#include "netinfo.h"       // 查当前默认路由那张网卡（启动日志「本机网络」那行用）

#if defined(_MSC_VER)
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "ws2_32.lib")
#endif

namespace {

// ---------------------------------------------------------------------------
//  协议常量（与 PROTOCOL.md 对应）
// ---------------------------------------------------------------------------

constexpr int      kProtocolVersion   = 1;
constexpr size_t   kMaxLineBytes      = 256;
constexpr size_t   kMaxBufferedBytes  = 1024;
constexpr unsigned kDefaultPort       = 45789;
// 3b：服务端自己读键盘接收器的状态帧、自己转发给 Mac（原来由 PowerShell 桥接做）
constexpr unsigned       kDefaultKbPort = 45790;   // Mac 侧接收抢跑帧的 UDP 端口
constexpr unsigned       kDefaultDiscoverPort = 45791;  // 地址自动发现的 UDP 端口（Mac 广播 WHO）
constexpr unsigned short kKbdVid        = 0x1B1C;  // 键盘接收器（SLIPSTREAM）
constexpr unsigned short kKbdUsagePage  = 0xFF42;  // 厂商自定义 usage page
constexpr unsigned short kKbdUsage      = 0x0002;  // 状态帧那个接口
constexpr unsigned kHeartbeatMs       = 1000;   // 每秒一个 PING
constexpr unsigned kPeerTimeoutMs     = 3000;   // 3 秒收不到对端数据即判死
constexpr size_t   kDefaultQueueLines = 8192;

// ---------------------------------------------------------------------------
//  选项与全局
// ---------------------------------------------------------------------------

struct Options {
    bool         listDevices = false;
    bool         showWindow  = false;
    bool         verbose     = false;   // 逐条打印事件到控制台
    bool         help        = false;
    std::wstring deviceFilter;          // --device <子串>，小写
    std::wstring bindAddress = L"0.0.0.0";
    unsigned     port        = kDefaultPort;
    std::string  macIp;                               // --mac-ip：抢跑帧/心跳发给谁（空 = 用已连接客户端的 IP）
    std::wstring pairFile;                            // --pair-file：配对文件位置（空 = 用默认）
    unsigned     pairTimeoutSec = 60;                 // --pair-timeout：配对确认框等多久算超时（秒）
    std::wstring hotkey = L"Ctrl+Alt+M";              // --hotkey：鼠标切换热键（"off" = 不注册）
bool         detectDevice = false;                // --detect：强制重跑一次设备识别（托盘点「检测鼠标」用）
    unsigned     kbPort      = kDefaultKbPort;        // --kb-port：Mac 侧抢跑 UDP 端口（0 = 关闭读帧）
    unsigned     discoverPort = kDefaultDiscoverPort; // --discover-port：地址发现 UDP 端口（0 = 关闭）
    bool         noKbWatch   = false;                 // --no-kb：不读接收器状态帧（对照测试用）
    unsigned     statsMs     = 1000;
    size_t       maxQueue    = kDefaultQueueLines;
    bool         startInMacMode = false;   // --start-in-mac-mode：启动即进入 Mac 模式
    bool         watchdogMode   = false;   // --watchdog <pid>：作为看门狗运行（内部使用）
    unsigned long watchdogPid   = 0;
};

Options           g_opts;
HWND              g_hwnd      = nullptr;
std::atomic<bool> g_running{true};

// 网络相关
SOCKET            g_listener  = INVALID_SOCKET;
std::atomic<bool> g_clientPresent{false};   // TCP 已连上（未必握手完）
std::atomic<bool> g_clientReady{false};     // 握手完成，可以发事件了
std::atomic<double> g_lastRttMs{-1.0};
std::atomic<bool> g_outputOverflow{false};
// 已连接客户端（Mac）的 IPv4 地址，网络字节序；0 = 没连接。
// 键盘抢跑线程要用它决定把 KEY/HB 发到哪（也可以用 --mac-ip 写死）。
std::atomic<unsigned long> g_peerIp4{0};

std::mutex              g_outMutex;
std::deque<std::string> g_outQueue;
std::deque<unsigned long long> g_outQueueStamp;   // 与 g_outQueue 一一对应：入队时刻的 QPC tick
std::atomic<double> g_sendLatencyMaxMs{0.0};      // 本统计窗口内"入队 → 真正发出"的最大耗时

// ---------------------------------------------------------------------------
//  高精度计时（QueryPerformanceCounter）
// ---------------------------------------------------------------------------
//  为什么不用 GetTickCount64：它的粒度是系统 tick（约 15.6 ms），
//  测 1~15 ms 的往返时只能得到 0 / 16 / 31… 这种台阶，分辨不出真实抖动。
LARGE_INTEGER g_qpcFreq{};

inline unsigned long long QpcTicks() {
    LARGE_INTEGER t;
    ::QueryPerformanceCounter(&t);
    return (unsigned long long)t.QuadPart;
}

inline double TicksToMs(unsigned long long ticks) {
    return g_qpcFreq.QuadPart ? (double)ticks * 1000.0 / (double)g_qpcFreq.QuadPart : 0.0;
}

// 统计
std::atomic<unsigned long long> g_capturedInWindow{0};
std::atomic<unsigned long long> g_sentInWindow{0};
std::atomic<unsigned long long> g_capturedTotal{0};
std::atomic<unsigned long long> g_sentTotal{0};
std::atomic<long long>          g_dxTotal{0};
std::atomic<long long>          g_dyTotal{0};
std::atomic<unsigned long long> g_buttonEvents{0};

// ---------------------------------------------------------------------------
//  Phase 5/6：控制权切换（Ctrl+Alt+M）+ 光标锁定
// ---------------------------------------------------------------------------
//  语义：
//    Windows 模式（默认）= 不转发事件 + 不加锁 → Windows 完全原生（打游戏就是这个状态）
//    Mac 模式           = 转发事件 + ClipCursor 把光标钉在原地（1x1）
//                          → Windows 光标不会跑、不会乱点，但相对位移照常转发给 Mac
//
//  安全要求（必须成立）：
//    · 客户端断开、程序退出、Ctrl+C —— 一律回到 Windows 模式并解除锁定
//    · 任何情况下都不得让 Windows 鼠标处于"无法使用"的状态

std::atomic<bool> g_macMode{false};        // true = 正在控制 Mac
std::atomic<bool> g_cursorClipped{false};  // 是否已经加了 ClipCursor
const int         kHotkeyId = 0x4B4D;      // "MK"

// 仍处于"按下"状态的按键（切回 Windows 模式时要补发抬起，避免 Mac 上左键卡住）
std::mutex g_heldMutex;
bool       g_held[5] = { false, false, false, false, false };  // L R M X1 X2
const char* const kButtonNames[5] = { "L", "R", "M", "X1", "X2" };

int ButtonIndex(const char* name) {
    for (int i = 0; i < 5; ++i)
        if (::strcmp(name, kButtonNames[i]) == 0) return i;
    return -1;
}

// 只有"Mac 模式 + 客户端已握手"时才真的把事件发出去
inline bool ShouldForward() {
    return g_macMode.load() && g_clientReady.load();
}
std::atomic<unsigned long long> g_wheelEvents{0};
std::atomic<unsigned long long> g_protocolErrors{0};
std::atomic<unsigned long long> g_queueDrops{0};

ULONGLONG g_lastStats = 0;

// ---------------------------------------------------------------------------
//  小工具
// ---------------------------------------------------------------------------

std::string Narrow(const std::wstring& w) {
    if (w.empty()) return std::string();
    const int n = ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(),
                                        nullptr, 0, nullptr, nullptr);
    if (n <= 0) return std::string();
    std::string out((size_t)n, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(),
                          out.data(), n, nullptr, nullptr);
    return out;
}

// 界面文案（宽）→ UTF-8 字节。**只给界面用**：
//   控制台代码页可能是 936 也可能是 65001，直接 printf("%ls") 会按当前代码页再转一次，
//   英文界面上就会出现乱码。统一先转成 UTF-8 再按 %s 打出去，两种代码页下都对。
//   （日志行不受影响：它们本来就是 UTF-8 源码字面量，照原样 printf。）
std::string U8(const std::wstring& w) { return Narrow(w); }

std::wstring Lower(const std::wstring& s) {
    std::wstring out = s;
    for (wchar_t& c : out) c = (wchar_t)::towlower(c);
    return out;
}

std::string Upper(const std::string& s) {
    std::string out = s;
    for (char& c : out) c = (char)::toupper((unsigned char)c);
    return out;
}

std::string Timestamp() {
    SYSTEMTIME st{};
    ::GetLocalTime(&st);
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%02u:%02u:%02u.%03u",
                  (unsigned)st.wHour, (unsigned)st.wMinute,
                  (unsigned)st.wSecond, (unsigned)st.wMilliseconds);
    return std::string(buf);
}

// "\\?\HID#VID_xxxx&PID_xxxx#...#{...}"  ->  "VID_xxxx&PID_xxxx"
std::string ShortName(const std::string& full) {
    if (full.empty()) return std::string();
    size_t p = full.find("VID_");
    if (p == std::string::npos) p = full.find("vid_");
    if (p != std::string::npos) {
        const size_t e = full.find('#', p);
        return (e == std::string::npos) ? full.substr(p) : full.substr(p, e - p);
    }
    const size_t b = full.find_last_of('\\');
    return (b == std::string::npos) ? full : full.substr(b + 1);
}

void Log(const char* fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    ::printf("[%s] %s\n", Timestamp().c_str(), line);
    ::fflush(stdout);
}

// ---------------------------------------------------------------------------
//  发送队列（主线程往里塞，网络线程往外发）
// ---------------------------------------------------------------------------

void EnqueueLine(std::string line) {
    line.push_back('\n');
    std::lock_guard<std::mutex> lock(g_outMutex);
    if (g_outQueue.size() >= g_opts.maxQueue) {
        // 对端消费不过来。继续堆下去只会吃内存，交给网络线程断开并让客户端重连。
        g_outputOverflow = true;
        g_queueDrops.fetch_add(1);
        return;
    }
    g_outQueue.push_back(std::move(line));
    g_outQueueStamp.push_back(QpcTicks());
}

bool HasPendingOutput() {
    std::lock_guard<std::mutex> lock(g_outMutex);
    return !g_outQueue.empty();
}

size_t QueueDepth() {
    std::lock_guard<std::mutex> lock(g_outMutex);
    return g_outQueue.size();
}

void ClearOutputQueue() {
    std::lock_guard<std::mutex> lock(g_outMutex);
    g_outQueue.clear();
    g_outQueueStamp.clear();
}

// ---------------------------------------------------------------------------
//  事件 → 协议行（只有握手完成后才真的发）
// ---------------------------------------------------------------------------

void EmitMove(long dx, long dy) {
    if (dx == 0 && dy == 0) return;
    g_capturedInWindow.fetch_add(1);
    g_capturedTotal.fetch_add(1);
    g_dxTotal.fetch_add(dx);
    g_dyTotal.fetch_add(dy);
    if (!ShouldForward()) return;

    char buf[64];
    std::snprintf(buf, sizeof(buf), "MOVE %ld %ld", dx, dy);
    EnqueueLine(buf);
    if (g_opts.verbose) ::printf("   -> %s\n", buf);
}

void EmitButton(const char* name, bool down) {
    g_buttonEvents.fetch_add(1);
    if (!ShouldForward()) return;

    std::string line = down ? "DOWN " : "UP ";
    line += name;
    EnqueueLine(line);

    // 记录"已发出但还没抬起"的键，供切回 Windows 模式时补发抬起
    const int idx = ButtonIndex(name);
    if (idx >= 0) {
        std::lock_guard<std::mutex> lock(g_heldMutex);
        g_held[idx] = down;
    }

    if (g_opts.verbose) ::printf("   -> %s\n", line.c_str());
}

void EmitWheel(long delta, bool horizontal) {
    g_wheelEvents.fetch_add(1);
    if (!ShouldForward()) return;

    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s %ld", horizontal ? "HWHEEL" : "WHEEL", delta);
    EnqueueLine(buf);
    if (g_opts.verbose) ::printf("   -> %s\n", buf);
}

// ---------------------------------------------------------------------------
//  控制权切换（Phase 5/6）
// ---------------------------------------------------------------------------

// 把仍处于按下状态的键补发"抬起"。
// 必须在停止转发之前调用，否则这些抬起发不出去，Mac 上会出现"左键卡住"。
void ReleaseAllHeldButtons() {
    for (int i = 0; i < 5; ++i) {
        bool down = false;
        {
            std::lock_guard<std::mutex> lock(g_heldMutex);
            down = g_held[i];
        }
        if (down) EmitButton(kButtonNames[i], false);
    }
}

// ---------------------------------------------------------------------------
//  看门狗进程
// ---------------------------------------------------------------------------
//  实测确认：ClipCursor 的锁定在进程被强杀后【不会】自动解除
//  —— 那会导致 Windows 鼠标卡死在锁定区域里，属于项目红线禁止的情况。
//  所以进入 Mac 模式时额外启动一个看门狗：一旦主进程消失而锁定仍在，
//  它立刻调用 ClipCursor(nullptr) 解除（已验证跨进程可以解除）。

bool SpawnWatchdog() {
    wchar_t exe[MAX_PATH] = {};
    if (::GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) return false;

    wchar_t cmd[MAX_PATH + 64];
    // 注意：宽字符格式化里打印 wchar_t* 必须用 %ls。
    // 本文件是用 -D__USE_MINGW_ANSI_STDIO=1 编译的，这种模式下 %s 会被当成
    // char*，而宽字符串第一个字符后面就是 0 字节，于是命令行被截断成
    //     "C" --watchdog 1234
    // （实测过：2026-09-26 进 Mac 模式时看门狗的 CommandLine 就是这样。）
    //
    // 功能上一直没出问题，因为下面 CreateProcessW 的第一个参数
    // （lpApplicationName）另外传了完整路径，命令行被截断照样能启动。
    // 但这是安全相关代码：万一以后有人把那行改掉，看门狗就再也起不来，
    // 而它正是"主进程被强杀后把锁死的光标解开"的那道保险。
    ::swprintf(cmd, sizeof(cmd) / sizeof(cmd[0]), L"\"%ls\" --watchdog %lu",
               exe, (unsigned long)::GetCurrentProcessId());

    STARTUPINFOW si{};
    si.cb          = sizeof(si);
    si.dwFlags     = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi{};
    if (!::CreateProcessW(exe, cmd, nullptr, nullptr, FALSE,
                          CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        return false;
    }
    ::CloseHandle(pi.hThread);
    ::CloseHandle(pi.hProcess);
    return true;
}

int RunWatchdog(unsigned long pid) {
    HANDLE h = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (h == nullptr) {                 // 主进程已经不在了
        ::ClipCursor(nullptr);
        return 0;
    }

    const ULONGLONG deadline = ::GetTickCount64() + 12ull * 60 * 60 * 1000;  // 最长守 12 小时
    for (;;) {
        RECT c{};
        if (!::GetClipCursor(&c)) { ::CloseHandle(h); return 0; }
        const bool clipped = (c.right - c.left) <= 2 && (c.bottom - c.top) <= 2;
        if (!clipped) {                 // 主进程已正常解除锁定 → 看门狗收工
            ::CloseHandle(h);
            return 0;
        }
        if (::WaitForSingleObject(h, 200) == WAIT_OBJECT_0) {
            ::ClipCursor(nullptr);      // 主进程消失但锁定还在 → 立刻解除
            ::CloseHandle(h);
            return 0;
        }
        if (::GetTickCount64() > deadline) { ::CloseHandle(h); return 0; }
    }
}

void SetControlMode(bool macMode, const char* why) {
    if (g_macMode.load() == macMode) return;

    if (macMode) {
        // 先把光标移到屏幕中心再钉住（1x1），然后才开始转发 —— 顺序不能反，
        // 否则会有极短的时间窗口让 Windows 光标乱跑。
        // 钉在"中心"而不是"原位"：切换后两边光标位置对称，开始用时不会从角落起飞。
        const int cx = ::GetSystemMetrics(SM_CXSCREEN) / 2;
        const int cy = ::GetSystemMetrics(SM_CYSCREEN) / 2;
        ::SetCursorPos(cx, cy);
        POINT pt{ cx, cy };
        RECT r{ pt.x, pt.y, pt.x + 1, pt.y + 1 };
        if (::ClipCursor(&r)) {
            g_cursorClipped = true;
        } else {
            Log("警告：ClipCursor 失败（错误 %lu）—— 光标不会被锁定，事件仍会转发",
                ::GetLastError());
        }

        // 看门狗：ClipCursor 的锁定在强杀后不会自动解除，必须有人兜住
        if (g_cursorClipped.load()) {
            if (SpawnWatchdog()) {
                Log("   看门狗已启动：即使本进程被强杀，光标锁定也会在 200ms 内自动解除");
            } else {
                Log("   警告：看门狗启动失败 —— 若本进程被强杀，光标可能停留在锁定状态！");
            }
        }

        g_macMode = true;
        EnqueueLine("MODE Mac");
        Log("★ 控制权 → Mac（%s）：开始转发事件，Windows 光标已移到屏幕中心并锁定", why);
        Log("   再按一次 Ctrl+Alt+M 切回 Windows。");
    } else {
        // 顺序：先补发抬起（此时仍在转发）→ 通知 Mac → 停止转发 → 解除锁定
        ReleaseAllHeldButtons();
        EnqueueLine("MODE Win");
        g_macMode = false;
        if (g_cursorClipped.exchange(false)) {
            ::ClipCursor(nullptr);
        }
        // 交回 Windows 时也把光标归到屏幕中心：下次接管时两边位置一致
        ::SetCursorPos(::GetSystemMetrics(SM_CXSCREEN) / 2,
                       ::GetSystemMetrics(SM_CYSCREEN) / 2);
        Log("★ 控制权 → Windows（%s）：已停止转发，锁定解除，光标移到屏幕中心", why);
    }
}

// 无论以何种方式退出（客户端断开、Ctrl+C、正常退出），都必须回到 Windows 模式，
// 保证 Windows 鼠标不会停留在"被锁定 / 无法使用"的状态。
void ForceWindowsMode(const char* why) {
    if (g_macMode.load()) {
        SetControlMode(false, why);
    } else if (g_cursorClipped.exchange(false)) {
        ::ClipCursor(nullptr);   // 兜底：即使模式标记异常，也不让光标留在锁定状态
    }
}

// ---------------------------------------------------------------------------
//  Raw Input 设备查询（与 Phase 1 相同）
// ---------------------------------------------------------------------------

std::wstring QueryDeviceName(HANDLE hDevice) {
    UINT chars = 0;
    ::GetRawInputDeviceInfoW(hDevice, RIDI_DEVICENAME, nullptr, &chars);
    if (chars == 0) return std::wstring();

    std::vector<wchar_t> buf(chars);
    UINT written = chars;
    if (::GetRawInputDeviceInfoW(hDevice, RIDI_DEVICENAME, buf.data(), &written) == (UINT)-1)
        return std::wstring();

    buf.resize(::wcslen(buf.data()));
    return std::wstring(buf.begin(), buf.end());
}

bool QueryDeviceInfo(HANDLE hDevice, RID_DEVICE_INFO& out) {
    out = RID_DEVICE_INFO{};
    out.cbSize = sizeof(RID_DEVICE_INFO);
    UINT size = sizeof(RID_DEVICE_INFO);
    return ::GetRawInputDeviceInfoW(hDevice, RIDI_DEVICEINFO, &out, &size) != (UINT)-1;
}

struct DeviceName {
    HANDLE       handle = nullptr;
    std::wstring fullName;
    std::string  shortName;
};

std::map<HANDLE, DeviceName> g_deviceNames;

const DeviceName& LookupDevice(HANDLE hDevice) {
    auto it = g_deviceNames.find(hDevice);
    if (it != g_deviceNames.end()) return it->second;

    DeviceName d;
    d.handle    = hDevice;
    d.fullName  = QueryDeviceName(hDevice);
    d.shortName = ShortName(Narrow(d.fullName));
    if (d.shortName.empty()) d.shortName = "<unknown-device>";
    auto res = g_deviceNames.emplace(hDevice, std::move(d));
    return res.first->second;
}

bool PassesFilter(HANDLE hDevice) {
    if (g_opts.deviceFilter.empty()) return true;
    return Lower(LookupDevice(hDevice).fullName).find(g_opts.deviceFilter) != std::wstring::npos;
}

// ---------------------------------------------------------------------------
//  鼠标设备自动识别（目标：零配置，装好就能用）
// ---------------------------------------------------------------------------
//  为什么**不靠枚举设备列表**：列表里全是虚拟设备、接收器的第二个接口、
//  触控板……用户选不对。**"谁真的在动"才准** —— 所以这里只观察：
//  窗口内哪个设备真的产生了鼠标事件。
//
//  计数口径（照任务单，别自己发挥）：
//    · 只统计 WM_INPUT 里 dwType == RIM_TYPEMOUSE 的事件，按设备分组计次
//    · MOUSE_MOVE_ABSOLUTE 的设备直接排除（触控板 / 数位板那种）
//    · 一个设备 ≥ 3 条事件才算候选（避免"插上就冒一两条"的虚拟设备）
//
//  机器可读状态行（托盘 grep 它们，和 HOTKEY 一个路子）：
//      DEVICE PICK  <串>      只有一个设备动过 → 锁定它
//      DEVICE MULTI <个数>    多个设备动过 → 交给用户选，**不自动挑**
//      DEVICE NONE            窗口内没人动过
//      DEVICE MISS  <串>      配了串，但一直没有事件通过（换鼠标了）
//      DEVICE OK    <串>      配的串正常收到事件
//
//  探测期间照常转发（过滤为空 = 全部转发），观察本身不影响功能。

const unsigned kWatchWindowMs = 8000;    // 观察窗口 8 秒
const unsigned kMissAfterMs   = 10000;   // 配了串却一直没通过 → 10 秒后报警
const unsigned kCandidateMin  = 3;       // 候选门槛

std::mutex                      g_watchMutex;
std::map<std::string, unsigned> g_watchHits;      // 设备短串 → 事件数
bool                            g_watchActive   = false;
ULONGLONG                       g_watchStart    = 0;
unsigned long long              g_filterDropped = 0;
ULONGLONG                       g_filterDropAt  = 0;   // 第一条被丢弃的时刻（0 = 还没丢过）
bool                            g_deviceOkLogged = false;
bool                            g_missReported   = false;

void StartDeviceWatch(const char* why) {
    std::lock_guard<std::mutex> lk(g_watchMutex);
    g_watchHits.clear();
    g_watchActive = true;
    g_watchStart  = ::GetTickCount64();
    Log("设备识别：%s —— 请在 %u 秒内动一下你要用的那只鼠标…",
        why, kWatchWindowMs / 1000);
}

// 每个鼠标事件都调一次（绝对坐标的已在调用方排除）
void NoteDeviceEvent(HANDLE hDevice, bool passes) {
    const std::string name = LookupDevice(hDevice).shortName;

    if (passes) {
        // 只有"配了串"的时候才报 OK（没配串时全部通过，报 OK 没意义）
        if (!g_opts.deviceFilter.empty() && !g_deviceOkLogged) {
            g_deviceOkLogged = true;
            g_missReported   = false;
            // ★ 机器可读行必须**不带时间前缀**（托盘按行首 grep）→ 用 printf，不用 Log
            ::printf("DEVICE OK %s\n", name.c_str());
            ::fflush(stdout);
        }
    } else {
        ++g_filterDropped;
        if (g_filterDropAt == 0) g_filterDropAt = ::GetTickCount64();
    }

    std::lock_guard<std::mutex> lk(g_watchMutex);
    // 观察窗口内按设备计次。
    // ★ 名字查不出来的设备（<unknown-device>）**不计入候选**：
    //   实测用 SendInput 注入的移动在 Raw Input 里就落在一个查不出名字的设备上，
    //   如果那时真鼠标没动，它就会成为唯一候选、被"锁定"并写进 config.ini ——
    //   结果是把配置写坏（--device "<unknown-device>"），转发直接失效。
    if (g_watchActive && name != "<unknown-device>") ++g_watchHits[name];
}

// 观察窗口到点：出结论
void TickDeviceWatch() {
    if (!g_watchActive) return;
    if (::GetTickCount64() - g_watchStart < kWatchWindowMs) return;

    std::vector<std::pair<std::string, unsigned>> cand;
    {
        std::lock_guard<std::mutex> lk(g_watchMutex);
        g_watchActive = false;
        for (const auto& kv : g_watchHits)
            if (kv.second >= kCandidateMin) cand.push_back(kv);
    }
    std::sort(cand.begin(), cand.end(),
              [](const std::pair<std::string, unsigned>& a,
                 const std::pair<std::string, unsigned>& b) { return a.second > b.second; });

    if (cand.empty()) {
        ::printf("DEVICE NONE\n");
        ::fflush(stdout);
    Log("设备识别：%u 秒内没检测到鼠标移动。动一下鼠标，或点托盘「检测鼠标」重试。",
            kWatchWindowMs / 1000);
    } else if (cand.size() == 1) {
        ::printf("DEVICE PICK %s\n", cand[0].first.c_str());
        ::fflush(stdout);
        Log("设备识别：锁定 %s（只有它产生过事件）—— 托盘会把它写回 config.ini",
            cand[0].first.c_str());
    } else {
        ::printf("DEVICE MULTI %u\n", (unsigned)cand.size());
        ::fflush(stdout);
    Log("设备识别：有 %u 个设备动过，**不自动选** —— 请点托盘「检测鼠标」挑一个",
            (unsigned)cand.size());
        for (const auto& kv : cand) {
            ::printf("DEVICE CAND %s %u\n", kv.first.c_str(), kv.second);   // 也机器可读
            Log("  候选：%s（%u 条事件）", kv.first.c_str(), kv.second);
        }
        ::fflush(stdout);
    }
}

// 配了串、却一直没有事件通过 → 报警并重新识别一次
void TickDeviceMiss() {
    if (g_opts.deviceFilter.empty() || g_deviceOkLogged || g_missReported) return;
    if (g_filterDropAt == 0 || g_watchActive) return;
    if (::GetTickCount64() - g_filterDropAt < kMissAfterMs) return;

    g_missReported = true;
    const std::string want = Narrow(g_opts.deviceFilter);
    ::printf("DEVICE MISS %s\n", want.c_str());
    ::fflush(stdout);
    Log("设备识别：配的设备串「%s」%u 秒内一条都没通过 —— 换鼠标了？"
        "下面重新识别一次；也可以点托盘「检测鼠标」。",
        want.c_str(), kMissAfterMs / 1000);
    StartDeviceWatch("过滤串没匹配上，重新识别");
}

// ---------------------------------------------------------------------------
//  Raw Input 事件处理（只读，和 Phase 1 完全一致的读取逻辑）
// ---------------------------------------------------------------------------

union RawInputScratch {
    RAWINPUT raw;
    BYTE     bytes[4096];
};
RawInputScratch g_rawScratch;

void HandleRawInput(HRAWINPUT hRawInput) {
    UINT size = 0;
    ::GetRawInputData(hRawInput, RID_INPUT, nullptr, &size, (UINT)sizeof(RAWINPUTHEADER));
    if (size == 0 || size > (UINT)sizeof(g_rawScratch.bytes)) return;

    const UINT got = ::GetRawInputData(hRawInput, RID_INPUT, g_rawScratch.bytes, &size,
                                       (UINT)sizeof(RAWINPUTHEADER));
    if (got == (UINT)-1 || got != size) return;

    const RAWINPUT* raw = reinterpret_cast<const RAWINPUT*>(g_rawScratch.bytes);
    if (raw->header.dwType != RIM_TYPEMOUSE) return;      // 只注册了鼠标

    const RAWMOUSE& m = raw->data.mouse;
    const bool absolute = (m.usFlags & MOUSE_MOVE_ABSOLUTE) != 0;
    const bool passes   = PassesFilter(raw->header.hDevice);

    // ---- 设备识别：只统计"相对坐标"的鼠标（绝对坐标那种是触控板/数位板，排除）----
    if (!absolute) NoteDeviceEvent(raw->header.hDevice, passes);

    // ---- 按设备过滤（排除键盘的鼠标类 collection、以及不是我们要的那只鼠标）----
    if (!passes) {
        // 静默丢弃是"装好了完全没反应"的头号原因 —— 第一次丢就明确说清楚。
        static bool dropWarned = false;
        if (!dropWarned) {
            dropWarned = true;
            Log("注意：设备 %s 的事件被 --device 过滤掉了（当前配的是「%s」）。"
        "如果这只才是你要用的鼠标，改设备串或点托盘「检测鼠标」。",
                LookupDevice(raw->header.hDevice).shortName.c_str(),
                Narrow(g_opts.deviceFilter).c_str());
        }
        return;
    }

    if (m.usFlags & MOUSE_MOVE_ABSOLUTE) {
        static bool warned = false;
        if (!warned) {
            warned = true;
            Log("注意：该设备上报的是绝对坐标（远程桌面 / 数位板），本阶段无法转发，已忽略。");
        }
    } else {
        EmitMove(m.lLastX, m.lLastY);
    }

    const USHORT f = m.usButtonFlags;
    if (f & RI_MOUSE_LEFT_BUTTON_DOWN)   EmitButton("L", true);
    if (f & RI_MOUSE_LEFT_BUTTON_UP)     EmitButton("L", false);
    if (f & RI_MOUSE_RIGHT_BUTTON_DOWN)  EmitButton("R", true);
    if (f & RI_MOUSE_RIGHT_BUTTON_UP)    EmitButton("R", false);
    if (f & RI_MOUSE_MIDDLE_BUTTON_DOWN) EmitButton("M", true);
    if (f & RI_MOUSE_MIDDLE_BUTTON_UP)   EmitButton("M", false);
    if (f & RI_MOUSE_BUTTON_4_DOWN)      EmitButton("X1", true);
    if (f & RI_MOUSE_BUTTON_4_UP)        EmitButton("X1", false);
    if (f & RI_MOUSE_BUTTON_5_DOWN)      EmitButton("X2", true);
    if (f & RI_MOUSE_BUTTON_5_UP)        EmitButton("X2", false);

    if (f & RI_MOUSE_WHEEL)  EmitWheel((long)(short)m.usButtonData, false);
    if (f & RI_MOUSE_HWHEEL) EmitWheel((long)(short)m.usButtonData, true);
}

// ---------------------------------------------------------------------------
//  帧切分与协议处理（网络线程）
// ---------------------------------------------------------------------------

struct Client {
    SOCKET      sock            = INVALID_SOCKET;
    bool        handshaken      = false;
    std::string recvBuffer;
    std::string currentLine;        // 正在发送的那一行
    size_t      currentOffset   = 0;
    unsigned long long currentStamp = 0;   // 该行入队时刻（QPC tick），用于统计发送延迟
    std::string peer            = "?";
    ULONGLONG   connectedAt     = 0;
    ULONGLONG   lastRecv        = 0;
    ULONGLONG   lastPing        = 0;
    unsigned long long pingSeq  = 0;
    std::map<unsigned long long, ULONGLONG> pingSentAt;
    // 这条连接正在等配对答案（PAIR? 已受理，确认框还开着、或答案还没发出去）。
    // 这个标志存在期间**不判死**，见网络线程"心跳与超时"那一段的注释。
    bool        pairPending     = false;
    const char* closeReason     = nullptr;   // 由协议层设置，供 CloseClient 打印准确原因
    // 协议层要求断开时不能立刻 close —— CloseClient 里的 ClearOutputQueue() 会把
    // 刚 EnqueueLine 进去、还没 send() 出去的那行一起丢掉
    // （ERR AUTH / ERR NOPAIR / PAIR-NO…）。改成"先刷干净再关"。
    bool        closeAfterFlush = false;
    ULONGLONG   closeDeadline   = 0;         // 兜底：刷不完也不能一直挂着
};

std::vector<std::string> SplitTokens(const std::string& line) {
    std::vector<std::string> out;
    size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && ::isspace((unsigned char)line[i])) ++i;
        const size_t start = i;
        while (i < line.size() && !::isspace((unsigned char)line[i])) ++i;
        if (i > start) out.push_back(line.substr(start, i - start));
    }
    return out;
}

// 取第 n 个字段之后的所有内容（保留其中的空格）——口令可能带空格
std::string RestAfterTokens(const std::string& line, size_t tokenCount) {
    size_t i = 0;
    size_t seen = 0;
    while (i < line.size() && seen < tokenCount) {
        while (i < line.size() && ::isspace((unsigned char)line[i])) ++i;
        const size_t start = i;
        while (i < line.size() && !::isspace((unsigned char)line[i])) ++i;
        if (i > start) ++seen;
    }
    while (i < line.size() && ::isspace((unsigned char)line[i])) ++i;
    return line.substr(i);
}

// 返回 false 表示这条连接应当断开
// ---------------------------------------------------------------------------
//  配对（协议 v1.2）
// ---------------------------------------------------------------------------
//  口令的**唯一事实来源**：配对文件。不缓存，每次握手现读。
//  返回空串 = "本机还没有配对过" -> 回 ERR NOPAIR（客户端据此发起配对）。
//
//  2026-10-01：按 Mac 侧决策**删掉了 --token** —— 配对是唯一的鉴权路径，
//  不再有"用户自己设口令"这条路（两条路并存会互相打架：设了 --token 就再也
//  弹不出配对框）。协议没变，HELLO 里照样带口令，只是那个口令永远是配对生成的。

std::wstring PairFilePath() {
    if (!g_opts.pairFile.empty()) return g_opts.pairFile;
    wchar_t exe[MAX_PATH] = {0};
    ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring p = exe;
    const size_t pos = p.find_last_of(L"\\/");
    const std::wstring dir = (pos == std::wstring::npos) ? std::wstring(L".") : p.substr(0, pos);
    // 默认落在 <exe 目录>\..\paired.json：
    //   开发布局：exe 在 phase3-tcp\build\ 里 → phase3-tcp\paired.json ✔
    //  （旧写法 "..\phase3-tcp\paired.json" 在开发布局下会拼成
    //    phase3-tcp\phase3-tcp\paired.json —— 2026-10-01 真机配对踩到过，
    //    表现为「写配对文件失败（3）」，因为那一层目录根本不存在。）
    //   安装布局（exe 与配对文件平铺）由入口用 --pair-file 显式指定。
    return dir + L"\\..\\paired.json";
}

std::string ReadPairFileToken() {
    const std::wstring p = PairFilePath();
    HANDLE h = ::CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return std::string();   // 没有文件 = 没有口令
    char buf[1024] = {0};
    DWORD got = 0;
    const BOOL ok = ::ReadFile(h, buf, (DWORD)sizeof(buf) - 1, &got, nullptr);
    ::CloseHandle(h);
    if (!ok || got == 0) return std::string();
    buf[got] = '\0';
    std::string s(buf);
    const size_t nl = s.find_first_of("\r\n");
    if (nl != std::string::npos) s.resize(nl);          // 只取第一行
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.erase(s.begin());
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.pop_back();
    return s;
}

std::string EffectiveToken() {
    return ReadPairFileToken();                         // 口令只来自配对文件
}

bool WritePairFileToken(const std::string& tok) {
    const std::wstring p = PairFilePath();
    HANDLE h = ::CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        Log("配对：写配对文件失败（%lu）：%ls", ::GetLastError(), p.c_str());
        return false;
    }
    DWORD wrote = 0;
    const BOOL ok = ::WriteFile(h, tok.data(), (DWORD)tok.size(), &wrote, nullptr);
    ::CloseHandle(h);
    if (!ok || wrote != (DWORD)tok.size()) { Log("配对：写配对文件不完整"); return false; }
    Log("配对完成：已保存口令（%u 字符）到 %ls", (unsigned)tok.size(), p.c_str());
    return true;
}

std::string MakeRandomToken() {
    unsigned char raw[32] = {0};
    const NTSTATUS st = ::BCryptGenRandom(nullptr, raw, (ULONG)sizeof(raw),
                                          BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (st != 0) {
        Log("配对：BCryptGenRandom 失败（0x%08X），改用 rand() 兜底", (unsigned)st);
        for (size_t i = 0; i < sizeof(raw); ++i) raw[i] = (unsigned char)(::rand() & 0xFF);
    }
    static const char* kHex = "0123456789abcdef";
    std::string s;
    s.reserve(64);
    for (size_t i = 0; i < sizeof(raw); ++i) {
        s.push_back(kHex[raw[i] >> 4]);
        s.push_back(kHex[raw[i] & 0x0F]);
    }
    return s;
}

// ---------------------------------------------------------------------------
//  配对确认框（协议 v1.2 · 方案 C：服务端自己建窗口）
// ---------------------------------------------------------------------------
//  为什么不用 MessageBoxW（上一轮的实现，已废弃）：
//    实测它既不认 WM_CLOSE，也不认我们合成出来的 WM_KEYDOWN(VK_ESCAPE)。
//    30 秒到点时框还挂在屏幕上，于是 PAIR-NO timeout 一直发不出去，
//    只有等用户手点一下才回包 —— "超时回包"这一项因此一直过不了。
//  所以改成自己建的小窗口：SetTimer 到点直接 DestroyWindow，
//  答案（允许 / 拒绝 / 超时）统一走 EnqueueLine 异步回给客户端。
//
//  线程模型（安全底线，别改）：
//    建窗、消息循环、销毁全部在这一个**独立线程**里跑。
//    主线程的 Raw Input 和网络线程一秒都不会被它挡住 ——
//    任务单 §2.3 要求的"弹框期间鼠标转发不卡"靠的就是这一条。
//
//  这个窗口不碰任何系统设置：无 hook、无驱动、不改注册表，关掉即消失。

std::atomic<bool> g_pairDialogOpen{false};    // 已有框在等（busy 判据）
std::atomic<HWND> g_pairDialogHwnd{nullptr};  // 供退出时强制关窗
std::atomic<bool> g_pairDialogAbort{false};   // 进程要退了：关窗、且不回包

const wchar_t* kPairDlgClass = L"Traiectus_PairDlg_v1";
// 注意：这里是**中文原文**（查表用的 key），显示时再走 L() —— 语言在运行时才定，
// 静态初始化阶段拿不到 I18nLang()，所以不能在全局初始化里查表。
const wchar_t* kPairDlgTitle = L"Traiectus 配对";
constexpr UINT_PTR kPairTimerId   = 1;
// 配对确认框等多久算超时。默认 60 秒（原来是 30 秒，实测太短了）：
// 用户要在另一台机器上点「连接」、再把显示器输入切过来、然后点按钮，
// 30 秒里稍一耽搁就自己超时了。可以用 --pair-timeout <秒> 改。
UINT PairTimeoutMs() { return g_opts.pairTimeoutSec * 1000u; }

enum PairResult { kPairNone = 0, kPairAllow = 1, kPairDeny = 2, kPairTimeout = 3 };

// 确认框自己的资源（控件句柄 + 字体）。关窗时一并释放。
// ---------------------------------------------------------------------------
//  配对确认框（Apple 风格）
// ---------------------------------------------------------------------------
//  设计取向：照着 macOS 的权限弹窗做 ——
//    · 没有标题栏：一个圆角浮层（Win11 的 DWM 圆角 + 投影），不显示在 Alt+Tab 里
//    · 文案居中：粗体标题一行 + 灰色设备名一行，没有别的字
//    · 按钮右下角对齐，圆角 6px；默认那个用 macOS 的蓝色实心（#0A84FF）
//    · 配色用 Apple 的色值；字体优先 Segoe UI（字形最接近 SF Pro），中文自动回退雅黑
//  安全语义不变：回车 / Esc / 关窗都算拒绝，默认按钮也是「拒绝」。

struct PairDlg {
    std::wstring dev;
    int          result    = kPairNone;
    HWND         hwnd      = nullptr;
    HWND         btnAllow  = nullptr;
    HWND         btnDeny   = nullptr;
    HWND         titleText = nullptr;
    HWND         devText   = nullptr;
    HFONT        fDevice   = nullptr;
    HFONT        fButton   = nullptr;
    int          dpi       = 96;
};

// ---- Apple 浅色配色 ------------------------------------------------------
const COLORREF kMacBg         = RGB(0xFA, 0xFA, 0xFA);   // 面板底
const COLORREF kMacTitle      = RGB(0x1D, 0x1D, 0x1F);   // 标题
const COLORREF kMacBody       = RGB(0x6E, 0x6E, 0x73);   // 次要文字
const COLORREF kMacBorder     = RGB(0xD2, 0xD2, 0xD7);   // 按钮描边
const COLORREF kMacPress      = RGB(0xEC, 0xEC, 0xF0);

HBRUSH MacBgBrush() {
    static HBRUSH b = ::CreateSolidBrush(kMacBg);        // 进程内一份，不用释放
    return b;
}

// 把客户端发来的字节串按 **UTF-8** 转成宽字符。
//
//   ★ 不能"逐字节拓宽"（老写法就是那么干的）：设备名是 UTF-8 中文，
//     例如「某某的Mac-Mini」，逐字节拓宽会把一个汉字拆成 3 个字符
//     （的 = E7 9A 84 → U+00E7 U+009A U+0084），弹框上显示成
//     「某某çMac-Mini」。2026-10-01 真机配对时被用户当场发现。
std::wstring WidenUtf8(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int n = ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (n > 0) {
        std::wstring out((size_t)n, L'\0');
        ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &out[0], n);
        return out;
    }
    std::wstring out;                                    // 非法 UTF-8：宁可难看别丢内容
    out.reserve(s.size());
    for (char c : s) out.push_back((wchar_t)(unsigned char)c);
    return out;
}

// 按磅值建字体。取不到就返回 nullptr，调用方退回系统字体 —— 宁可丑，不可没有字。
HFONT MakeFont(int pt, bool bold) {
    HDC screen = ::GetDC(nullptr);
    const int h = -::MulDiv(pt, ::GetDeviceCaps(screen, LOGPIXELSY), 72);
    ::ReleaseDC(nullptr, screen);

    LOGFONTW lf{};
    lf.lfHeight         = h;
    lf.lfWeight         = bold ? FW_SEMIBOLD : FW_NORMAL;
    lf.lfCharSet        = DEFAULT_CHARSET;
    lf.lfQuality        = CLEARTYPE_QUALITY;
    lf.lfOutPrecision   = OUT_TT_PRECIS;
    lf.lfClipPrecision  = CLIP_DEFAULT_PRECIS;
    lf.lfPitchAndFamily = DEFAULT_PITCH | FF_DONTCARE;
    // Segoe UI 的字形最接近 macOS 的 SF Pro；中文由系统的字体链接回退到雅黑
    ::lstrcpynW(lf.lfFaceName, L"Segoe UI", LF_FACESIZE);
    return ::CreateFontIndirectW(&lf);
}

// 自己画按钮：圆角 6px 的 macOS 样子。两个按钮**同一种样式**（白底描边、黑字），
// 不用颜色区分主次（用户要求"不要有颜色"）；按下时只做一点浅灰反馈。
void DrawMacButton(const DRAWITEMSTRUCT* di, HFONT font, const wchar_t* label) {
    HDC dc = di->hDC;
    RECT r = di->rcItem;
    const bool pressed = (di->itemState & ODS_SELECTED) != 0;

    const COLORREF fill   = pressed ? kMacPress : RGB(0xFF, 0xFF, 0xFF);
    const COLORREF border = kMacBorder;

    HBRUSH   br = ::CreateSolidBrush(fill);
    HPEN     pen = ::CreatePen(PS_SOLID, 1, border);
    HGDIOBJ  ob = ::SelectObject(dc, br);
    HGDIOBJ  op = ::SelectObject(dc, pen);
    ::RoundRect(dc, r.left, r.top, r.right, r.bottom, 12, 12);   // 12 = 圆角直径 6px
    ::SelectObject(dc, ob);
    ::SelectObject(dc, op);
    ::DeleteObject(br);
    ::DeleteObject(pen);

    ::SetBkMode(dc, TRANSPARENT);
    ::SetTextColor(dc, kMacTitle);
    HGDIOBJ of = ::SelectObject(dc, font);
    ::DrawTextW(dc, label, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    ::SelectObject(dc, of);
}

// Win11 的圆角窗口（老系统上这个调用不存在，静默跳过）
void ApplyRoundCorners(HWND hwnd) {
    HMODULE dwm = ::LoadLibraryW(L"dwmapi.dll");
    if (dwm == nullptr) return;
    typedef HRESULT (WINAPI *SetAttr)(HWND, DWORD, LPCVOID, DWORD);
    // 经 void* 中转，避开 FARPROC 直接转函数指针的 -Wcast-function-type
    auto fn = reinterpret_cast<SetAttr>(
        reinterpret_cast<void*>(::GetProcAddress(dwm, "DwmSetWindowAttribute")));
    if (fn != nullptr) {
        const DWORD DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        const int   DWMWCP_ROUND = 2;
        fn(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &DWMWCP_ROUND, sizeof(DWMWCP_ROUND));
    }
    ::FreeLibrary(dwm);
}

LRESULT CALLBACK PairDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    PairDlg* d = reinterpret_cast<PairDlg*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_NCCREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                            reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return TRUE;
    }
    case WM_CREATE: {
        d->fDevice = MakeFont(13, false);      // 正文
        d->fButton = MakeFont(12, false);      // 按钮
        if (!d->fDevice) d->fDevice = (HFONT)::GetStockObject(DEFAULT_GUI_FONT);
        if (!d->fButton) d->fButton = (HFONT)::GetStockObject(DEFAULT_GUI_FONT);

        // 布局按 96dpi 设计，再按实际 DPI 等比缩放
        auto S = [&](int v) { return ::MulDiv(v, d->dpi, 96); };

        // ---- 排版：三个元素（文字行 / 按钮行 / 窗口边缘）之间的间距 ----
        //
        //  用的是字体**实际**度量，不是拍脑袋的固定像素：
        //    · 文字行的"盒子高度" = tmHeight（字体的完整行高）
        //    · 这个盒子上方有一段 internal leading（行距），字看起来会离上边缘更远，
        //      所以顶部留白要**减掉**它 —— 这样"看得见的间距"才和其它方向一致
        //    · 三个方向的目标视觉间距都取 24（96dpi 设计值）
        //    · 窗口宽度由内容决定：max(文字宽, 按钮行宽) + 左右留白，
        //      再夹在 260~420 之间（太窄显得挤，太宽显得空）
        const std::wstring kHeadText = L("有一台 Mac 想连接这台电脑");
        TEXTMETRICW tm{};
        SIZE        ts{};
        {
            HDC dc = ::GetDC(hwnd);
            HGDIOBJ old = ::SelectObject(dc, d->fDevice);
            ::GetTextMetricsW(dc, &tm);
            ::GetTextExtentPoint32W(dc, kHeadText.c_str(), (int)kHeadText.size(), &ts);
            ::SelectObject(dc, old);
            ::ReleaseDC(hwnd, dc);
        }
        const int padSide = S(28);                 // 左右留白
        const int gap     = S(28);                 // 文字行 ↔ 按钮行
        const int padBot  = S(26);                 // 按钮行 ↔ 下边缘
        // 顶部留白比下边缘**略大**（28 vs 26）：这一行中文没有下伸部（g/y 那种尾巴），
        // 视觉重心天生偏高，等值留白会看起来"贴顶"；这一点差值就是光学补偿。
        const int padTop  = S(28);
        const int btnW = S(108), btnH = S(34), btnGap = S(12);

        const int textH    = tm.tmHeight;
        const int btnRowW  = btnW * 2 + btnGap;
        int       textW    = ts.cx;
        if (textW < btnRowW) textW = btnRowW;      // 内容宽度取两者较宽者
        int clientW = textW + padSide * 2;
        if (clientW < S(380)) clientW = S(380);    // 太窄会显得局促
        if (clientW > S(480)) clientW = S(480);
        const int clientH = padTop + textH + gap + btnH + padBot;

        auto label = [&](const std::wstring& s, HFONT f, DWORD extra,
                         int x, int y, int w, int hgt) {
            HWND c = ::CreateWindowExW(0, L"STATIC", s.c_str(),
                                       WS_CHILD | WS_VISIBLE | SS_CENTER | extra,
                                       S(x), S(y), S(w), S(hgt), hwnd,
                                       nullptr, nullptr, nullptr);
            ::SendMessageW(c, WM_SETFONT, (WPARAM)f, TRUE);
            return c;
        };
        auto button = [&](const wchar_t* s, int id, int x, int y, int w, int hgt) {
            return ::CreateWindowExW(0, L"BUTTON", s,
                                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                     S(x), S(y), S(w), S(hgt), hwnd,
                                     (HMENU)(INT_PTR)id, nullptr, nullptr);
        };

        // 第一行：文字居中（左右撑满 clientW - 2*padSide）
        d->titleText = label(kHeadText, d->fDevice, SS_CENTERIMAGE,
                             padSide, padTop, clientW - padSide * 2, textH);

        // 第二行：两个按钮整行居中
        const int btnRowX = (clientW - btnRowW) / 2;
        const int btnRowY = padTop + textH + gap;
        d->btnAllow = button(L("允许").c_str(), IDOK,     btnRowX, btnRowY, btnW, btnH);
        d->btnDeny  = button(L("拒绝").c_str(), IDCANCEL, btnRowX + btnW + btnGap, btnRowY, btnW, btnH);

        // 窗口尺寸是算出来的（无标题栏 → 窗口大小就是客户区大小）
        ::SetWindowPos(hwnd, nullptr, 0, 0, clientW, clientH,
                       SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        ::SetTimer(hwnd, kPairTimerId, PairTimeoutMs(), nullptr);   // 硬超时（--pair-timeout）
        return 0;
    }
    case WM_DRAWITEM: {
        auto* di = reinterpret_cast<DRAWITEMSTRUCT*>(lp);
        if (d == nullptr) return TRUE;
        if (di->CtlID == IDOK)          DrawMacButton(di, d->fButton, L("允许").c_str());
        else if (di->CtlID == IDCANCEL) DrawMacButton(di, d->fButton, L("拒绝").c_str());
        return TRUE;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = reinterpret_cast<HDC>(wp);
        ::SetBkMode(dc, TRANSPARENT);
        ::SetTextColor(dc, (d != nullptr && reinterpret_cast<HWND>(lp) == d->devText)
                               ? kMacBody : kMacTitle);
        return reinterpret_cast<LRESULT>(MacBgBrush());
    }
    case WM_COMMAND: {
        const int id = LOWORD(wp);
        if (id != IDOK && id != IDCANCEL) return 0;
        if (d != nullptr && d->result == kPairNone)
            d->result = (id == IDOK) ? kPairAllow : kPairDeny;
        ::DestroyWindow(hwnd);
        return 0;
    }
    case WM_TIMER:
        if (wp == kPairTimerId) {
            if (d != nullptr && d->result == kPairNone) d->result = kPairTimeout;
            ::DestroyWindow(hwnd);
        }
        return 0;
    case WM_CLOSE:
        if (d != nullptr && d->result == kPairNone) d->result = kPairDeny;
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        ::KillTimer(hwnd, kPairTimerId);
        if (d != nullptr) {
            for (HFONT f : { d->fDevice, d->fButton }) {
                if (f != nullptr && f != (HFONT)::GetStockObject(DEFAULT_GUI_FONT))
                    ::DeleteObject(f);
            }
            d->fDevice = d->fButton = nullptr;
        }
        // 只结束**本线程**的消息循环；主线程的消息队列互不相干
        ::PostQuitMessage(0);
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wp, lp);
    }
}

void PairDialogThread(std::wstring dev) {
    PairDlg d;
    d.dev = std::move(dev);

    HINSTANCE hInst = ::GetModuleHandleW(nullptr);
    WNDCLASSEXW wc{};
    wc.cbSize        = (UINT)sizeof(wc);
    wc.style         = CS_DROPSHADOW;
    wc.lpfnWndProc   = PairDlgProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = kPairDlgClass;
    wc.hCursor       = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = MacBgBrush();
    if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        Log("配对：RegisterClassExW 失败（%lu）—— 直接拒绝", ::GetLastError());
        g_pairDialogOpen = false;
        if (!g_pairDialogAbort.load()) EnqueueLine("PAIR-NO denied");
        return;
    }

    // 窗口大小最终由 WM_CREATE 按字体实际度量算出来（见那边"排版"一段）；
    // 这里先按一个大概尺寸建窗，出来之后再按真实大小重新居中。
    // **不要标题栏**（Apple 风格）
    HDC screen = ::GetDC(nullptr);
    d.dpi = ::GetDeviceCaps(screen, LOGPIXELSY);
    ::ReleaseDC(nullptr, screen);
    if (d.dpi <= 0) d.dpi = 96;

    const DWORD style   = WS_POPUP;
    const DWORD exStyle = WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
    const int w = ::MulDiv(360, d.dpi, 96);
    const int h = ::MulDiv(110, d.dpi, 96);
    const int x = (::GetSystemMetrics(SM_CXSCREEN) - w) / 2;
    const int y = (::GetSystemMetrics(SM_CYSCREEN) - h) / 3;

    d.hwnd = ::CreateWindowExW(exStyle, kPairDlgClass, L(kPairDlgTitle).c_str(), style,
                               x, y, w, h, nullptr, nullptr, hInst, &d);
    if (d.hwnd == nullptr) {
        Log("配对：CreateWindowExW 失败（%lu）—— 直接拒绝", ::GetLastError());
        g_pairDialogOpen = false;
        if (!g_pairDialogAbort.load()) EnqueueLine("PAIR-NO denied");
        return;
    }

    g_pairDialogHwnd = d.hwnd;
    // WM_CREATE 里已经把窗口改成算出来的尺寸了 —— 按最终大小重新居中/定位
    {
        RECT wr{};
        ::GetWindowRect(d.hwnd, &wr);
        const int fw = wr.right - wr.left;
        const int fh = wr.bottom - wr.top;
        ::SetWindowPos(d.hwnd, nullptr,
                       (::GetSystemMetrics(SM_CXSCREEN) - fw) / 2,
                       (::GetSystemMetrics(SM_CYSCREEN) - fh) / 3,
                       0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    ApplyRoundCorners(d.hwnd);
    ::ShowWindow(d.hwnd, SW_SHOWNORMAL);
    ::UpdateWindow(d.hwnd);
    ::SetForegroundWindow(d.hwnd);
    ::MessageBeep(MB_ICONQUESTION);
    Log("配对：确认框已弹出（允许 = 生成新口令；回车/Esc/关窗 = 拒绝；%u 秒 = 超时）",
        g_opts.pairTimeoutSec);

    MSG msg;
    while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // 回车 / Esc 一律当"拒绝"。写在循环里而不是窗口过程里：
        // 这样无论焦点在哪个子控件上（按钮、静态文本）都生效。
        if (msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN) {
            if (msg.wParam == VK_RETURN || msg.wParam == VK_ESCAPE) {
                if (d.result == kPairNone) d.result = kPairDeny;
                if (::IsWindow(d.hwnd)) ::DestroyWindow(d.hwnd);
                continue;                  // 退出靠 WM_DESTROY 里的 PostQuitMessage
            }
        }
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
    }

    g_pairDialogHwnd = nullptr;
    g_pairDialogOpen = false;

    // 进程正在退出：窗口关掉就够了，不要再往发送队列里塞东西
    if (g_pairDialogAbort.load()) {
        Log("配对：确认框在退出过程中被关闭，不回包");
        return;
    }

    switch (d.result) {
    case kPairAllow: {
        const std::string tok = MakeRandomToken();
        if (WritePairFileToken(tok)) {
            EnqueueLine("PAIR-OK " + tok);
            Log("配对：用户点了允许，已回 PAIR-OK（口令 %u 字符）", (unsigned)tok.size());
        } else {
            EnqueueLine("PAIR-NO save-failed");
        }
        break;
    }
    case kPairTimeout:
        EnqueueLine("PAIR-NO timeout");
        Log("配对：%u 秒无人操作，已回 PAIR-NO timeout", g_opts.pairTimeoutSec);
        break;
    default:
        EnqueueLine("PAIR-NO denied");
        Log("配对：用户拒绝（或直接关掉了确认框），已回 PAIR-NO denied");
        break;
    }
}

bool HandleClientLine(Client& cl, const std::string& line) {
    const std::vector<std::string> tok = SplitTokens(line);
    if (tok.empty()) return true;
    const std::string cmd = Upper(tok[0]);

    // 心跳和"握没握手"无关：服务端每秒都在发 PING，对端回 PONG 是正常的。
    // 这两条必须在握手检查**之前**处理 —— 否则 PAIR? 之后的配对等待
    // （连接还在、但还没 handshake）会被自己的心跳判成"协议错误"而断开。
    // 实测就是这个原因：PAIR? 后 ~1 秒连接被关，配对框还在等用户点。
    if (cmd == "PING") {
        if (tok.size() == 2) EnqueueLine("PONG " + tok[1]);
        return true;
    }
    if (cmd == "PONG") {
        if (tok.size() == 2) {
            const unsigned long long id = std::strtoull(tok[1].c_str(), nullptr, 10);
            auto it = cl.pingSentAt.find(id);
            if (it != cl.pingSentAt.end()) {
                g_lastRttMs = TicksToMs(QpcTicks() - it->second);
                cl.pingSentAt.erase(it);
            }
        }
        return true;
    }

    if (!cl.handshaken) {
        // ---- 协议 v1.2：配对请求 ----
        //  注意：PAIR-OK 之后**不能关连接** —— 客户端会在同一条连接上继续发 HELLO。
        if (cmd == "PAIR?") {
            const std::string devName = tok.size() > 1 ? RestAfterTokens(line, 1) : std::string("?");
            if (!EffectiveToken().empty()) {
                Log("配对：本机已有口令，回 PAIR-NO already-paired（设备 %s，来源 %s）",
                    devName.c_str(), cl.peer.c_str());
                EnqueueLine("PAIR-NO already-paired");
                return true;                     // 保持连接，由客户端决定何时断开
            }
            if (g_pairDialogOpen.exchange(true)) {
                Log("配对：已有一个确认框未关，回 PAIR-NO busy");
                EnqueueLine("PAIR-NO busy");
                return true;
            }
            // 从这里到"答案真的发出去"为止，这条连接的沉默是正常的：
            // 用户看到框之后要切显示器、再点按钮，十几秒很正常。
            cl.pairPending = true;
            Log("配对：收到配对请求（设备 %s，来源 %s）—— 已在 Windows 上弹确认框",
                devName.c_str(), cl.peer.c_str());
            // 弹框与计时都在确认框自己的线程里（见 PairDialogThread 上方注释）。
            // 这里立刻返回：接收循环、Raw Input、转发一秒都不受弹框影响。
            std::thread(PairDialogThread, WidenUtf8(devName)).detach();
            return true;                         // 不等结果，连接保持；答案稍后由对话框线程回
        }

        if (cmd != "HELLO") {
            ++g_protocolErrors;
            Log("客户端在握手前发了 %s，断开连接", cmd.c_str());
            return false;
        }
        const std::string version = tok.size() > 1 ? tok[1] : "";
        const std::string role    = tok.size() > 2 ? tok[2] : "?";
        const std::string token   = RestAfterTokens(line, 3);

        // 顺序不能反：**先判"有没有口令"，再判"对不对"**。
        // 没有口令 -> ERR NOPAIR（客户端会清掉本地口令并重连走配对）；
        // 有口令但对不上 -> ERR AUTH（客户端不清本地口令、停止自动重连）。
        const std::string have = EffectiveToken();
        if (have.empty()) {
            Log("握手失败（本机没有任何口令）→ 回复 ERR NOPAIR 并断开");
            EnqueueLine("ERR NOPAIR");
            return false;
        }
        if (version != std::to_string(kProtocolVersion) || token != have) {
            Log("握手失败（版本=%s 口令%s）→ 回复 ERR AUTH 并断开",
                version.c_str(), token == have ? "正确" : "不符");
            EnqueueLine("ERR AUTH");
            return false;
        }

        cl.handshaken = true;
        g_clientReady = true;
        EnqueueLine("HELLO-OK " + std::to_string(kProtocolVersion));
        // 顺便告诉对端当前控制权在谁那里（不认识这条命令的客户端会忽略它）
        EnqueueLine(g_macMode.load() ? "MODE Mac" : "MODE Win");
        Log("握手完成：%s（协议 v%s）—— 开始转发事件", role.c_str(), version.c_str());
        return true;
    }

    if (cmd == "PING") {
        if (tok.size() == 2) EnqueueLine("PONG " + tok[1]);
        return true;
    }
    if (cmd == "PONG") {
        if (tok.size() == 2) {
            const unsigned long long id = std::strtoull(tok[1].c_str(), nullptr, 10);
            auto it = cl.pingSentAt.find(id);
            if (it != cl.pingSentAt.end()) {
                // 用 QPC 计算，才能分辨 1 ms 量级的差异（GetTickCount64 只有 ~15.6 ms 粒度）
                g_lastRttMs = TicksToMs(QpcTicks() - it->second);
                cl.pingSentAt.erase(it);
            }
        }
        return true;
    }
    if (cmd == "BYE") {
        cl.closeReason = "对端发送了 BYE（正常结束）";
        return false;
    }

    // 追加（PROTOCOL.md 里记为可选扩展）：客户端可以请求把控制权交给某一端。
    // Mac 侧的联动脚本用它实现"一次 Fn 按键 = 键盘 + 鼠标 + 屏幕一起切"。
    // 不认识的客户端永远不会发这条命令，所以对老客户端没有影响。
    if (cmd == "MODE") {
        if (tok.size() == 2) {
            const std::string want = Upper(tok[1]);
            if (want == "MAC") {
                SetControlMode(true, "客户端请求");
            } else if (want == "WIN") {
                SetControlMode(false, "客户端请求");
            }
        }
        return true;
    }

    ++g_protocolErrors;
    if (g_protocolErrors.load() <= 5) Log("收到不认识的命令：%s", line.c_str());
    return true;
}

// 从接收缓冲里切出完整行；返回 false 表示协议层面应当断开
bool ProcessClientBuffer(Client& cl) {
    for (;;) {
        const size_t nl = cl.recvBuffer.find('\n');
        if (nl == std::string::npos) {
            if (cl.recvBuffer.size() > kMaxBufferedBytes) {
                Log("连续 %llu 字节没有出现换行，断开连接", (unsigned long long)cl.recvBuffer.size());
                return false;
            }
            return true;
        }

        std::string line = cl.recvBuffer.substr(0, nl);
        cl.recvBuffer.erase(0, nl + 1);
        if (!line.empty() && line.back() == '\r') line.pop_back();

        if (line.size() > kMaxLineBytes) {
            Log("单行 %llu 字节超过上限 %llu，断开连接",
                (unsigned long long)line.size(), (unsigned long long)kMaxLineBytes);
            return false;
        }
        if (!HandleClientLine(cl, line)) return false;
    }
}

// 把队列里的数据尽量发出去；返回 false 表示连接应当断开
bool FlushOutput(Client& cl) {
    std::lock_guard<std::mutex> lock(g_outMutex);
    size_t linesThisRound = 0;

    while (linesThisRound < 1024) {
        if (cl.currentOffset >= cl.currentLine.size()) {
            // 上一行已经完整发出 → 统计这一行的"入队 → 发出"耗时（取窗口内峰值）
            if (cl.currentStamp != 0) {
                const double ms = TicksToMs(QpcTicks() - cl.currentStamp);
                double prev = g_sendLatencyMaxMs.load();
                while (ms > prev && !g_sendLatencyMaxMs.compare_exchange_weak(prev, ms)) {}
                cl.currentStamp = 0;
            }
            cl.currentLine.clear();
            cl.currentOffset = 0;
            if (g_outQueue.empty()) return true;
            cl.currentLine = std::move(g_outQueue.front());
            g_outQueue.pop_front();
            if (!g_outQueueStamp.empty()) {
                cl.currentStamp = g_outQueueStamp.front();
                g_outQueueStamp.pop_front();
            }
        }

        const char* data = cl.currentLine.data() + cl.currentOffset;
        const int   remaining = (int)(cl.currentLine.size() - cl.currentOffset);
        const int   n = ::send(cl.sock, data, remaining, 0);

        if (n == SOCKET_ERROR) {
            if (::WSAGetLastError() == WSAEWOULDBLOCK) return true;   // 稍后再发
            return false;
        }
        if (n <= 0) return false;

        cl.currentOffset += (size_t)n;
        if (cl.currentOffset >= cl.currentLine.size()) {
            cl.currentLine.clear();
            cl.currentOffset = 0;
            ++linesThisRound;
            g_sentInWindow.fetch_add(1);
            g_sentTotal.fetch_add(1);
        } else {
            return true;   // 半行已发出，剩下的等下次可写
        }
    }
    return true;
}

void CloseClient(Client& cl, const char* why) {
    if (cl.sock == INVALID_SOCKET) return;

    // 关键安全动作：处于 Mac 模式时一旦断开，立刻回到 Windows 模式并解除光标锁定。
    // 放在最前面，确保无论因何断开（对端关闭 / 超时 / 出错 / 被顶掉）都会解锁。
    ForceWindowsMode("客户端断开");

    const char* reason = cl.closeReason ? cl.closeReason : why;
    if (cl.handshaken && reason) Log("客户端断开：%s", reason);
    g_clientReady = false;
    g_clientPresent = false;
    g_peerIp4 = 0;

    ::closesocket(cl.sock);
    const std::string peer = cl.peer;
    const bool wasHandshaken = cl.handshaken;

    cl = Client{};
    ClearOutputQueue();
    g_lastRttMs = -1.0;

    if (wasHandshaken) Log("已回到等待状态（%s 已断开）", peer.c_str());
}

// ---------------------------------------------------------------------------
//  网络线程：一次 select 同时处理 accept / 收 / 发 / 心跳
// ---------------------------------------------------------------------------

void NetworkThread() {
    Client cl;

    while (g_running) {
        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        FD_SET(g_listener, &readSet);

        const bool haveClient = (cl.sock != INVALID_SOCKET);
        if (haveClient) {
            FD_SET(cl.sock, &readSet);
            if (HasPendingOutput()) FD_SET(cl.sock, &writeSet);
        }

        // ---- 超时必须跟着"有没有客户端"走（第二轮联调的关键修复）----
        // 曾经的固定 200 ms 是一个真实 bug：写集合只在循环开头队列非空时才登记，
        // 而 Raw Input 线程可能在"检查队列是否为空"之后、select 之前才把事件入队
        // —— 那一行就要干等满 200 ms 才可能被发出。
        // 实测表现：事件成批送达 + 往返延迟 0~200 ms 均匀铺开（用户感受到的就是卡顿）。
        // 有客户端时用 1 ms，把最坏发送延迟压到 1 ms 以内；没有客户端时仍用 200 ms 省 CPU。
        timeval timeout{0, haveClient ? 1000 : 200000};
        const int ready = ::select(0, &readSet, haveClient ? &writeSet : nullptr, nullptr, &timeout);
        if (ready == SOCKET_ERROR) {
            Log("select 出错（%d），1 秒后重试", ::WSAGetLastError());
            ::Sleep(1000);
            continue;
        }

        // ---- 接受新连接（同一时刻只服务一个，新连接顶掉旧的）----
        if (FD_ISSET(g_listener, &readSet)) {
            sockaddr_in from{};
            int fromLen = (int)sizeof(from);
            SOCKET s = ::accept(g_listener, (sockaddr*)&from, &fromLen);
            if (s != INVALID_SOCKET) {
                u_long nonBlocking = 1;
                ::ioctlsocket(s, FIONBIO, &nonBlocking);

                // ---- 关键：禁用 Nagle 算法（TCP_NODELAY）----
                // 鼠标事件每条只有十几字节。Nagle 会把这种小包攒到几十毫秒再发，
                // 与延迟 ACK 相互等待时延迟可到 200ms 级 —— 实测往返尖峰 47~312ms。
                // 交互式流量必须关掉它，否则无论怎么优化都是"一顿一顿"。
                BOOL nodelay = TRUE;
                if (::setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
                                 (const char*)&nodelay, sizeof(nodelay)) != 0) {
                    Log("警告：设置 TCP_NODELAY 失败（%d）—— 事件可能被延迟发送",
                        ::WSAGetLastError());
                }

                char ip[64] = "?";
                ::inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));

                if (cl.sock != INVALID_SOCKET) {
                    Log("新客户端接入，顶掉旧连接（旧连接尚未握手完成或已被遗忘）");
                    CloseClient(cl, "被新连接顶掉");
                }

                cl.sock        = s;
                // 新连接必须复位"刷干净再关"的标记。
                // 这个字段是随 Client 结构长期存在的，不清的话会把上一个连接
                // 遗留的 true 带过来 —— 表现为"刚连上就被自己关掉"
                // （上一轮的 ERR NOPAIR 就置了 true，导致下一轮 PAIR? 连上即断）。
                cl.closeAfterFlush = false;
                cl.closeDeadline   = 0;
                cl.pairPending     = false;
                cl.peer        = std::string(ip) + ":" + std::to_string(ntohs(from.sin_port));
                cl.connectedAt = ::GetTickCount64();
                cl.lastRecv    = cl.connectedAt;
                cl.lastPing    = cl.connectedAt;
                g_clientPresent = true;
                ClearOutputQueue();     // 丢掉旧连接期间累积的事件
                g_peerIp4 = (unsigned long)from.sin_addr.s_addr;
                Log("客户端接入：%s，等待握手…", cl.peer.c_str());
            }
        }

        // ---- 收 ----
        if (cl.sock != INVALID_SOCKET && FD_ISSET(cl.sock, &readSet)) {
            char buf[4096];
            const int n = ::recv(cl.sock, buf, (int)sizeof(buf), 0);
            if (n == 0) {
                CloseClient(cl, "对端关闭了连接");
            } else if (n == SOCKET_ERROR) {
                const int e = ::WSAGetLastError();
                if (e != WSAEWOULDBLOCK) CloseClient(cl, "接收出错");
            } else {
                cl.lastRecv = ::GetTickCount64();
                cl.recvBuffer.append(buf, (size_t)n);
                if (!ProcessClientBuffer(cl)) {
                    // 先只做标记，等下面"刷干净再关"那段统一收尾
                    cl.closeAfterFlush = true;
                    cl.closeDeadline   = ::GetTickCount64() + 1000;
                }
            }
        }

        // ---- 发 ----
        if (cl.sock != INVALID_SOCKET && FD_ISSET(cl.sock, &writeSet)) {
            if (!FlushOutput(cl)) CloseClient(cl, "发送失败");
        }

        // 配对答案已经刷出去了 → 这条连接不再处于"等配对"状态。
        // 客户端拿到答案后会立刻回 HELLO（或主动断开），所以给它**重新起算 3 秒**：
        // 否则刚刚刷出去、客户端还没来得及回话，就会被下面的判死规则关掉。
        if (cl.pairPending && !g_pairDialogOpen.load() && !HasPendingOutput()) {
            cl.pairPending = false;
            cl.lastRecv    = ::GetTickCount64();
            Log("配对：答案已发出，恢复常规心跳判死（重新起算 3 秒）");
        }

        // ---- 协议层要求断开：先把发送队列刷干净，再关 ----
        //  FlushOutput 是非阻塞的，一次未必发得完（半行会等下次可写），
        //  所以给 1 秒兜底，不能假设一轮就发干净。
        if (cl.closeAfterFlush && cl.sock != INVALID_SOCKET) {
            FlushOutput(cl);
            if (g_outQueue.empty() || ::GetTickCount64() > cl.closeDeadline) {
                // 优雅半关：直接 closesocket 有可能发 RST，把对端还没读走的数据冲掉
                ::shutdown(cl.sock, SD_SEND);
                CloseClient(cl, "协议错误");
            }
            continue;
        }

        // ---- 队列溢出 ----
        if (g_outputOverflow.exchange(false)) {
            if (cl.sock != INVALID_SOCKET) {
                Log("发送队列超过 %llu 行，判定对端消费不过来，断开连接",
                    (unsigned long long)g_opts.maxQueue);
                CloseClient(cl, "发送队列溢出");
            }
        }

        // ---- 心跳与超时 ----
        if (cl.sock != INVALID_SOCKET) {
            const ULONGLONG now = ::GetTickCount64();
            // 配对等待期间**不判死**（2026-10-01 真机联调发现）：
            //   用户在 Windows 上看到确认框后，要切显示器、点按钮，十几秒很正常；
            //   而客户端在这段时间里是**安静的** —— 实测真 Mac 客户端在等配对答案时
            //   一个 PONG 都不回（它只在"已连接"状态下处理 PING）。
            //   按原来的 3 秒规则，会把"正在等配对答案的那条连接"先杀掉，
            //   PAIR-OK 入队时已经没有客户端了 —— 表现为"点了允许，Mac 却一直没反应"。
            //   这段静默是流程的正常状态，不是掉线；配对框自己有 30 秒超时兜底。
            //   恢复判死的时机是"答案已经发出去 + 重新起算 3 秒"（见上面 发 那段）。
            const bool pairingWait = !cl.handshaken &&
                                     (g_pairDialogOpen.load() || cl.pairPending);
            if (!pairingWait && now - cl.lastRecv > kPeerTimeoutMs) {
                CloseClient(cl, "超过 3 秒没收到对端任何数据");
            } else if (now - cl.lastPing >= kHeartbeatMs) {
                cl.lastPing = now;
                const unsigned long long id = ++cl.pingSeq;
                cl.pingSentAt[id] = QpcTicks();
                if (cl.pingSentAt.size() > 16) cl.pingSentAt.erase(cl.pingSentAt.begin());
                EnqueueLine("PING " + std::to_string(id));
            }
        }
    }

    if (cl.sock != INVALID_SOCKET) CloseClient(cl, "程序退出");
}

// ---------------------------------------------------------------------------
//  窗口过程（窗口只是 WM_INPUT 的接收器，默认隐藏）
// ---------------------------------------------------------------------------

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_INPUT:
        HandleRawInput(reinterpret_cast<HRAWINPUT>(lParam));
        return ::DefWindowProcW(hwnd, msg, wParam, lParam);
    case WM_INPUT_DEVICE_CHANGE:
        // 插拔只记一条日志，不做别的：本程序从不持有需要恢复的状态
        Log("设备%s：%s",
            wParam == GIDC_ARRIVAL ? "接入" : "移除",
            LookupDevice(reinterpret_cast<HANDLE>(lParam)).shortName.c_str());
        return 0;
    case WM_HOTKEY:
        if (wParam == (WPARAM)kHotkeyId) {
            SetControlMode(!g_macMode.load(), "快捷键 Ctrl+Alt+M");
            return 0;
        }
        return ::DefWindowProcW(hwnd, msg, wParam, lParam);
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC dc = ::BeginPaint(hwnd, &ps);
        RECT rc;
        ::GetClientRect(hwnd, &rc);
        rc.left += 16; rc.top += 16; rc.right -= 16; rc.bottom -= 16;
        HGDIOBJ oldFont = ::SelectObject(dc, ::GetStockObject(DEFAULT_GUI_FONT));
        ::SetBkMode(dc, TRANSPARENT);
        {
            // 只有 --show 才会把这个小窗显示出来；文字按当前语言查表。
            // 每行单独查表（整块一起查表的话，English 版换行位置会不一样）。
            const std::wstring body =
                L("Traiectus Server 正在运行。") + L"\n\n" +
                L("Ctrl+Alt+M : 切换控制权（Windows <-> Mac）") + L"\n" +
                L("  · Windows 模式：不转发、不锁光标（打游戏用这个）") + L"\n" +
                L("  · Mac 模式：转发事件，并把 Windows 光标锁在原地") + L"\n\n" +
                L("日志在控制台窗口；请在控制台按 Ctrl+C 停止程序。");
            ::DrawTextW(dc, body.c_str(), -1, &rc, DT_LEFT | DT_TOP | DT_WORDBREAK);
        }
        ::SelectObject(dc, oldFont);
        ::EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_CLOSE:
        ::DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        ::PostQuitMessage(0);
        return 0;
    default:
        return ::DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

BOOL WINAPI ConsoleHandler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
        g_running = false;
        if (g_hwnd != nullptr) ::PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
        return TRUE;
    }
    return FALSE;
}

// ---------------------------------------------------------------------------
//  每秒统计
// ---------------------------------------------------------------------------

void TickStats() {
    const ULONGLONG now = ::GetTickCount64();
    if (now - g_lastStats < (ULONGLONG)g_opts.statsMs) return;

    const double dt = (double)(now - g_lastStats) / 1000.0;
    g_lastStats = now;

    const double captured = (double)g_capturedInWindow.exchange(0) / dt;
    const double sent     = (double)g_sentInWindow.exchange(0) / dt;
    const bool   ready    = g_clientReady.load();
    const bool   present  = g_clientPresent.load();
    const double rtt      = g_lastRttMs.load();

    const char* state = ready ? "已连接（握手完成）"
                      : present ? "已连接（等待握手）"
                                : "等待客户端";
    const char* modeText = g_macMode.load() ? "控制权=Mac(光标已锁)" : "控制权=Windows";

    // 注意：不要把临时 std::string 的 c_str() 直接塞进 printf 的参数里
    char rttText[32];
    if (rtt >= 0.0) std::snprintf(rttText, sizeof(rttText), "%.1f ms", rtt);
    else            std::snprintf(rttText, sizeof(rttText), "—");

    // 本窗口内"入队 → 真正发出"的最大耗时（排查发送延迟用）
    const double sendLatMax = g_sendLatencyMaxMs.exchange(0.0);

    if (ready) {
        ::printf("[%s] %s | 客户端 %s | 发送 %6.0f 行/秒 | 队列 %3llu | 往返 %s | 发出延迟峰值 %.1f ms | 本机捕获 %6.0f pkt/s\n",
                 Timestamp().c_str(), modeText, state, sent,
                 (unsigned long long)QueueDepth(), rttText, sendLatMax, captured);
    } else {
        ::printf("[%s] %s | 客户端 %s | 监听 %s:%u | 本机捕获 %6.0f pkt/s（未发送）\n",
                 Timestamp().c_str(), modeText, state,
                 Narrow(g_opts.bindAddress).c_str(), g_opts.port, captured);
    }
    ::fflush(stdout);
}

// ---------------------------------------------------------------------------
//  设备列表
// ---------------------------------------------------------------------------

void PrintMouseList() {
    UINT count = 0;
    if (::GetRawInputDeviceList(nullptr, &count, (UINT)sizeof(RAWINPUTDEVICELIST)) == (UINT)-1) return;
    if (count == 0) return;

    std::vector<RAWINPUTDEVICELIST> list(count);
    const UINT got = ::GetRawInputDeviceList(list.data(), &count, (UINT)sizeof(RAWINPUTDEVICELIST));
    if (got == (UINT)-1) return;

    ::printf("%s", U8(L("本机的鼠标类 Raw Input 设备（用 --device 指定其中之一，通常选你在用的那只）：\n")).c_str());
    for (UINT i = 0; i < got; ++i) {
        if (list[i].dwType != RIM_TYPEMOUSE) continue;
        const std::wstring full = QueryDeviceName(list[i].hDevice);
        std::string shortName = ShortName(Narrow(full));
        if (shortName.empty()) shortName = "<unknown-device>";
        ::printf("   - %-26s  %s\n", shortName.c_str(), Narrow(full).c_str());
    }
    ::printf("\n");
    ::fflush(stdout);
}

void PrintAllDevices() {
    UINT count = 0;
    if (::GetRawInputDeviceList(nullptr, &count, (UINT)sizeof(RAWINPUTDEVICELIST)) == (UINT)-1) {
        ::printf("%s", U8(L("GetRawInputDeviceList 失败（错误 ") +
                          std::to_wstring(::GetLastError()) + L("）\n")).c_str());
        return;
    }
    if (count == 0) { ::printf("%s", U8(L("系统没有报告任何 Raw Input 设备。\n")).c_str()); return; }

    std::vector<RAWINPUTDEVICELIST> list(count);
    const UINT got = ::GetRawInputDeviceList(list.data(), &count, (UINT)sizeof(RAWINPUTDEVICELIST));
    if (got == (UINT)-1) {
        ::printf("%s", U8(L("GetRawInputDeviceList 第二次调用失败（") +
                          std::to_wstring(::GetLastError()) + L("）\n")).c_str());
        return;
    }

    ::printf("%s", U8(L("Raw Input 设备共 ") + std::to_wstring(got) + L(" 个：\n\n")).c_str());
    for (UINT i = 0; i < got; ++i) {
        const wchar_t* type = L"?";
        switch (list[i].dwType) {
        case RIM_TYPEMOUSE:    type = L"Mouse   "; break;
        case RIM_TYPEKEYBOARD: type = L"Keyboard"; break;
        case RIM_TYPEHID:      type = L"HID     "; break;
        default: break;
        }
        const std::wstring full = QueryDeviceName(list[i].hDevice);
        ::printf("  [%2u] %s  %-26s  %s\n", i, Narrow(type).c_str(),
                 ShortName(Narrow(full)).c_str(), Narrow(full).c_str());
    }
    ::printf("\n");
    ::fflush(stdout);
}

// ---------------------------------------------------------------------------
//  命令行
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//  鼠标切换热键（--hotkey）：解析成 RegisterHotKey 要的 mods + 虚拟键码
// ---------------------------------------------------------------------------
//  语法（--hotkey 和 config.ini 里同一个写法；Mac 侧也是这套）：
//    修饰键用 + 连接、大小写不敏感、顺序随意，**最后一个是主键**
//        Ctrl+Alt+M        默认值 —— 和改键之前的行为完全一样
//        Ctrl+Shift+M / Alt+Shift+K / Win+Alt+M
//        off               不注册热键
//  校验（必须做，否则会做出坑）：
//    · 至少要有 1 个修饰键 —— 裸键注册成全局热键会把正常打字毁掉
//    · 主键只认 A–Z / 0–9 / F1–F24
//    · 解析失败 → 打印明确原因 + **退回默认 Ctrl+Alt+M**（不静默失败、也不拒绝启动）

struct Hotkey {
    bool         enabled = true;
    unsigned     mods    = MOD_CONTROL | MOD_ALT;
    unsigned     vk      = 'M';
    std::wstring text    = L"Ctrl+Alt+M";       // 规范化写法，给日志和托盘读
};

Hotkey g_hotkey;
bool   g_hotkeyRegistered = false;

std::wstring HotkeyText(unsigned mods, unsigned vk) {
    std::wstring s;
    if (mods & MOD_CONTROL) s += L"Ctrl+";
    if (mods & MOD_ALT)     s += L"Alt+";
    if (mods & MOD_SHIFT)   s += L"Shift+";
    if (mods & MOD_WIN)     s += L"Win+";
    if (vk >= 'A' && vk <= 'Z')       s.push_back((wchar_t)vk);
    else if (vk >= '0' && vk <= '9')  s.push_back((wchar_t)vk);
    else                              s += L"F" + std::to_wstring((int)vk - (int)VK_F1 + 1);
    return s;
}

// 返回 false = 解析失败，原因写在 err 里（调用方打印，然后退回默认值）
bool ParseHotkey(const std::wstring& in, Hotkey& out, std::string& err) {
    std::wstring s;
    for (wchar_t c : in) if (!::iswspace(c)) s.push_back(c);
    if (s.empty()) { err = "是空的"; return false; }
    if (Lower(s) == L"off") { out.enabled = false; out.text = L"off"; return true; }

    std::vector<std::wstring> parts;
    for (size_t i = 0; i <= s.size();) {
        const size_t p = s.find(L'+', i);
        std::wstring t = (p == std::wstring::npos) ? s.substr(i) : s.substr(i, p - i);
        if (!t.empty()) parts.push_back(Lower(t));
        if (p == std::wstring::npos) break;
        i = p + 1;
    }
    if (parts.empty()) { err = "是空的"; return false; }

    unsigned mods = 0;
    for (size_t k = 0; k + 1 < parts.size(); ++k) {
        const std::wstring& t = parts[k];
        if (t == L"ctrl" || t == L"control") mods |= MOD_CONTROL;
        else if (t == L"alt")   mods |= MOD_ALT;
        else if (t == L"shift") mods |= MOD_SHIFT;
        else if (t == L"win")   mods |= MOD_WIN;
        else { err = "不认识的修饰键「" + Narrow(t) + "」"; return false; }
    }
    if (mods == 0) {
        err = "至少要有一个修饰键（Ctrl / Alt / Shift / Win）";
        return false;
    }

    const std::wstring& key = parts.back();
    unsigned vk = 0;
    if (key.size() == 1 && key[0] >= L'a' && key[0] <= L'z')      vk = (unsigned)(key[0] - L'a' + L'A');
    else if (key.size() == 1 && key[0] >= L'0' && key[0] <= L'9') vk = (unsigned)key[0];
    else if (key.size() >= 2 && key.size() <= 3 && key[0] == L'f') {
        const int n = (int)std::wcstol(key.c_str() + 1, nullptr, 10);
        if (n < 1 || n > 24) { err = "功能键只支持 F1–F24"; return false; }
        vk = (unsigned)(VK_F1 + n - 1);
    } else {
        err = "主键只支持 A–Z / 0–9 / F1–F24（最后一段是主键）";
        return false;
    }

    out.enabled = true;
    out.mods    = mods;
    out.vk      = vk;
    out.text    = HotkeyText(mods, vk);
    return true;
}

void PrintHelp() {
    if (IsEnglish()) {
        // 英文帮助：用词与官网 / Mac 端一致，标点全 ASCII。
        //  用宽字面量 → UTF-8 再输出：控制台代码页是 936 时也不会出现乱码。
        ::fputs(U8(L(
            "Traiectus Server - forwards the mouse from Windows to your Mac (read-only capture)\n"
            "\n"
            "Usage:\n"
            "  Traiectus-Server.exe [options]\n"
            "\n"
            "Options:\n"
            "  --device <substring>   Forward only mice whose device path contains this substring\n"
            "                         (case-insensitive). Empty by default = no filter: the server\n"
            "                         detects the mouse you are actually using. To pin one by hand,\n"
            "                         copy the VID_xxxx&PID_xxxx[&MI_xx] from the Mouse line of --list.\n"
            "  --detect               Force one more device detection (what the tray \"Detect mouse\" uses)\n"
            "  --port <port>          TCP listen port, default 45789\n"
            "  --kb-port <port>       UDP port for key frames / heartbeat to the Mac, default 45790 (0 = off)\n"
            "  --discover-port <port> UDP port for address discovery, default 45791\n"
            "                         (the Mac broadcasts `WHO 1`; this PC unicasts back `HERE 1 <port>`; 0 = off)\n"
            "  --mac-ip <address>     Where to send key frames; default = the connected client's IP\n"
            "  --no-kb                Do not read keyboard receiver frames (no key pre-empt; mouse forwarding unaffected)\n"
            "  --pair-file <path>     Pairing file location, default <exe dir>\\..\\paired.json\n"
            "  --pair-timeout <sec>   How long the pairing dialog waits before timing out, default 60 s\n"
            "                         ! Do not exceed 120: the Mac's safety net waits 120 s for PAIR-OK,\n"
            "                           and going over creates an already-paired deadlock (tell the Mac side if you change it)\n"
            "  --hotkey <combo>       Mouse-switch hotkey, default Ctrl+Alt+M\n"
            "                         Modifiers joined with +, last part is the main key: Ctrl+Shift+M / Win+Alt+K / F1-F24\n"
            "                         off = no hotkey. At least one modifier is required (bare keys are rejected)\n"
            "                         ! While registered, this combination is reserved system-wide by this app\n"
            "  --bind <address>       Listen address, default 0.0.0.0 (all interfaces)\n"
            "  --lang <zh|en>         UI language for this run (default: the Windows UI language)\n"
            "  --list                 List mouse-class Raw Input devices and exit\n"
            "  --verbose              Print every forwarded event to the console (for troubleshooting)\n"
            "  --show                 Also show a small window (not needed for normal use)\n"
            "  --start-in-mac-mode    Start in Mac mode (same as pressing Ctrl+Alt+M once after start)\n"
            "  --help                 Show this help\n"
            "  --watchdog <pid>       Internal: watchdog (covers ClipCursor not being released after a forced kill)\n"
            "\n"
            "Pairing (authentication): you never set it yourself. The token is created by pairing and\n"
            "  stored in the pairing file (default <exe dir>\\..\\paired.json). The first time a Mac\n"
            "  connects, a dialog appears on Windows - click \"Allow\" and pairing is done. After that\n"
            "  the Mac sends the token automatically. To switch machines: tray right-click -> \"Re-pair\".\n"
            "\n"
            "Control switching (global hotkey Ctrl+Alt+M):\n"
            "  Windows mode (default): no forwarding, no cursor lock -> Windows stays fully native (use this for gaming)\n"
            "  Mac mode: forwards events and pins the Windows cursor with ClipCursor (1x1)\n"
            "  Client disconnect, Ctrl+C, closing the window or a forced kill - always returns to\n"
            "  Windows mode and releases the lock.\n"
            "\n"
            "Stop: press Ctrl+C in this console.\n"
            "This app does not hook, install drivers, block or inject input events; ClipCursor only\n"
            "limits the cursor position and is reversible at any time.\n"
        )).c_str(), stdout);
        ::fflush(stdout);
        return;
    }
    ::printf(
        "Traiectus Server — 把 Windows 上的鼠标转发给 Mac（只读捕获）\n"
        "\n"
        "用法：\n"
        "  Traiectus-Server.exe [选项]\n"
        "\n"
        "选项：\n"
        "  --device <子串>   只转发设备路径包含该子串的鼠标（大小写不敏感）\n"
        "                    **默认留空 = 不挑设备**，服务端会自动识别你在用的那只鼠标\n"
        "                    手动指定时写 --list 里 Mouse 那行的 VID_xxxx&PID_xxxx[&MI_xx]\n"
        "  --detect          强制重跑一次设备识别（托盘点「检测鼠标」时用的）\n"
        "  --port <端口>     监听端口，默认 45789\n"
        "  --kb-port <端口>  抢跑帧/心跳发给 Mac 的 UDP 端口，默认 45790（0 = 关闭读帧）\n"
        "  --discover-port <端口>  地址自动发现的 UDP 端口，默认 45791\n"
        "                    （Mac 广播 `WHO 1`，本机单播回 `HERE 1 <上面的端口>`；0 = 关闭）\n"
        "  --mac-ip <地址>   抢跑帧发给哪个地址，默认用已连接客户端的 IP\n"
        "  --no-kb           不读键盘接收器状态帧（抢跑不可用；鼠标转发不受影响）\n"
        "  --pair-file <路径> 配对文件位置，默认 <exe目录>\\..\\paired.json\n"
        "  --pair-timeout <秒> 配对确认框等多久算超时，默认 60 秒\n"
        "                     ⚠ 不要超过 120：Mac 侧等 PAIR-OK 的安全网是 120 秒，\n"
        "                       超了会出现 already-paired 死局（改了要通知 Mac 侧）\n"
        "  --hotkey <组合键>  鼠标切换热键，默认 Ctrl+Alt+M\n"
        "                     修饰键用 + 连接、最后一段是主键：Ctrl+Shift+M / Win+Alt+K / F1–F24\n"
        "                     写 off = 不注册热键。至少要有 1 个修饰键（裸键会被拒绝）\n"
        "                     ⚠ 注册成功 = 这个组合键在全系统被本程序独占，别的程序拿不到\n"
        "  --bind <地址>     监听地址，默认 0.0.0.0（所有网卡）\n"
        "  --list            列出鼠标类 Raw Input 设备后退出\n"
        "  --verbose         把每条转发出去的事件打印到控制台（排查用）\n"
        "  --show            额外显示一个小窗口（正常运行时不需要）\n"
        "  --start-in-mac-mode  启动即进入 Mac 模式（等价于启动后按一次 Ctrl+Alt+M）\n"
        "  --help            显示这段帮助\n"
        "  --watchdog <pid>  内部使用：看门狗（兜住 ClipCursor 被强杀后不自动解除的风险）\n"
        "\n"
        "口令（鉴权）：**不用自己设**。口令由配对生成、存在配对文件里\n"
        "  （默认 <exe目录>\\..\\paired.json）。第一次有 Mac 连过来时，\n"
        "  Windows 上会弹一个确认框，点「允许」即完成配对；\n"
        "  之后 Mac 自动带口令握手。想换设备：托盘右键 →「重新配对」。\n"
        "\n"
        "控制权切换（全局快捷键 Ctrl+Alt+M）：\n"
        "  Windows 模式（默认）：不转发事件、不加光标锁定 → Windows 完全原生（打游戏用这个）\n"
        "  Mac 模式：转发事件，同时用 ClipCursor 把 Windows 光标锁在原地（1x1）\n"
        "  客户端断开、Ctrl+C、关闭窗口、进程被强杀 —— 一律回到 Windows 模式并解除锁定。\n"
        "\n"
        "停止：在本控制台按 Ctrl+C。\n"
        "本程序不做 hook、不装驱动、不拦截、不注入输入事件；ClipCursor 只限制光标位置，随时可逆。\n");
    ::fflush(stdout);
}

bool ParseArgs(int argc, wchar_t** argv) {
    for (int i = 1; i < argc; ++i) {
        const std::wstring a = argv[i];
        if (a == L"--list") {
            g_opts.listDevices = true;
        } else if (a == L"--show") {
            g_opts.showWindow = true;
        } else if (a == L"--verbose") {
            g_opts.verbose = true;
        } else if (a == L"--start-in-mac-mode") {
            g_opts.startInMacMode = true;
        } else if (a == L"--no-kb") {
            g_opts.noKbWatch = true;
        } else if (a == L"--detect") {
        g_opts.detectDevice = true;      // 托盘点「检测鼠标」时用：强制重跑一次识别
        } else if (a == L"--pair-file") {
            if (i + 1 >= argc) { ::printf("--pair-file 需要一个路径\n"); return false; }
            g_opts.pairFile = argv[++i];
        } else if (a == L"--pair-timeout") {
            if (i + 1 >= argc) { ::printf("--pair-timeout 需要秒数\n"); return false; }
            const long v = std::wcstol(argv[++i], nullptr, 10);
            if (v < 1 || v > 3600) { ::printf("--pair-timeout 要在 1~3600 秒之间\n"); return false; }
            g_opts.pairTimeoutSec = (unsigned)v;
        } else if (a == L"--watchdog") {
            if (i + 1 >= argc) { ::printf("--watchdog 需要一个进程号\n"); return false; }
            g_opts.watchdogMode = true;
            g_opts.watchdogPid  = (unsigned long)std::wcstol(argv[++i], nullptr, 10);
        } else if (a == L"--help" || a == L"-h" || a == L"/?") {
            g_opts.help = true;
        } else if (a == L"--lang") {
            // 语言本身在 main() 开头就已经取出去了（见那里的说明）；
            // 这里只做参数校验，免得 --lang 写成别的值时被当成"不认识的参数"。
            if (i + 1 >= argc) { ::printf("%s", U8(L("--lang 只认 zh 或 en\n")).c_str()); return false; }
            const std::wstring v = argv[++i];
            if (v != L"zh" && v != L"en") {
                ::printf("%s", U8(L("--lang 只认 zh 或 en\n")).c_str());
                return false;
            }
        } else if (a == L"--device" || a == L"--port" || a == L"--bind"
                   || a == L"--kb-port" || a == L"--mac-ip" || a == L"--discover-port"
                   || a == L"--hotkey") {
            if (i + 1 >= argc) { ::printf("%ls 需要一个值\n", a.c_str()); return false; }
            const std::wstring v = argv[++i];
            if (a == L"--device")     g_opts.deviceFilter = Lower(v);
            else if (a == L"--bind")  g_opts.bindAddress = v;
            else if (a == L"--mac-ip") g_opts.macIp = Narrow(v);
            else if (a == L"--kb-port")      g_opts.kbPort      = (unsigned)std::wcstol(v.c_str(), nullptr, 10);
            else if (a == L"--discover-port") g_opts.discoverPort = (unsigned)std::wcstol(v.c_str(), nullptr, 10);
            else if (a == L"--hotkey")        g_opts.hotkey = v;
            else                      g_opts.port = (unsigned)std::wcstol(v.c_str(), nullptr, 10);
        } else {
            ::printf("%s", U8(L("不认识的参数：") + a + L"\n\n").c_str());
            PrintHelp();
            return false;
        }
    }
    if (g_opts.port == 0 || g_opts.port > 65535) {
        ::printf("端口必须在 1..65535\n");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
//  键盘抢跑 socket 上收到的回包
// ---------------------------------------------------------------------------
//   Mac 收到我们的 KEY/HB 之后，是"往收到包的源地址回"，所以回包会落到
//   键盘抢跑那个 socket 上。这里只认 PING（连通性自检，回 PONG）。
//
//   ★ 2026-10-01：原来的 `MODE <Mac|Win> <口令>` 分支**删掉了** ——
//     控制权切换实际走的是 TCP 那条 MODE，这条 UDP 路径从来没被用过
//     （日志里 0 条），而且它的口令校验比的是 g_opts.token（删掉 --token 后是空串，
//     等于任何请求都被拒）。现在收到 MODE 一律**当成不认识的报文忽略**：
//     不回包、也不记"口令不符"。
bool HandleControlDatagram(const char* buf, int n, std::string& reply, const char* whence) {
    (void)whence;
    reply.clear();
    const std::vector<std::string> tok = SplitTokens(std::string(buf, (size_t)n));
    if (tok.empty()) return false;
    if (Upper(tok[0]) == "PING") { reply = "PONG"; return true; }
    return false;
}

// ---------------------------------------------------------------------------
//  地址自动发现（UDP 45791）：Mac 喊一声，我们应一声
// ---------------------------------------------------------------------------
//  全新安装时两边都不知道对方在哪：Mac 是主动连的一侧，得先知道往哪连；
//  而我们这边在"还没有任何客户端连过"时，也不知道心跳该发给谁 —— 死锁。
//  所以由 Mac 广播问一声：
//
//      Mac     → 广播 "WHO 1"              （第 2 个字段是协议版本）
//      Windows → 单播回 "HERE 1 45789"      （第 3 个字段是 TCP 监听端口）
//
//  安全上刻意做了三条限制：
//    · **只单播回来源**，绝不回广播 —— 回广播等于给反射放大送弹药
//    · **同来源 1 秒内最多回一次**（日志用同一个限速，防刷日志）
//    · 回包里**只有版本和端口**，不带任何口令 / 配对信息
//      （这两样端口扫描本来就能拿到，等于没多暴露什么）
//
//  这个线程**不依赖任何客户端连接**：服务端一启动就能应答 ——
//  这正是"全新安装也能自动找到对方"的关键。

std::mutex                         g_discMutex;
std::map<unsigned long, ULONGLONG> g_discLast;   // 来源 IP → 上次应答时刻

// 限速：同来源 1 秒内只放行一次（返回 true = 这次可以处理）
bool DiscoveryAllowed(unsigned long ip, ULONGLONG now) {
    std::lock_guard<std::mutex> lk(g_discMutex);
    auto it = g_discLast.find(ip);
    if (it != g_discLast.end() && now - it->second < 1000) return false;
    g_discLast[ip] = now;
    if (g_discLast.size() > 64) g_discLast.erase(g_discLast.begin());   // 别无限长
    return true;
}

void DiscoveryThread() {
    if (g_opts.discoverPort == 0 || g_opts.discoverPort > 65535) {
        Log("发现通道：已关闭（--discover-port 0）");
        return;
    }

    SOCKET s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        Log("发现通道：socket() 失败（%d）", ::WSAGetLastError());
        return;
    }
    BOOL reuse = TRUE;
    ::setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&reuse, sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons((u_short)g_opts.discoverPort);
    if (::bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
        Log("发现通道：bind(UDP %u) 失败（%d）—— 端口被占用或被防火墙拦截",
            g_opts.discoverPort, ::WSAGetLastError());
        ::closesocket(s);
        return;
    }
    Log("发现通道已开启：UDP %u（Mac 广播 WHO 1 → 本机单播回 HERE 1 %u）",
        g_opts.discoverPort, g_opts.port);

    while (g_running) {
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(s, &rd);
        timeval tv{};
        tv.tv_sec  = 0;
        tv.tv_usec = 200000;
        if (::select(0, &rd, nullptr, nullptr, &tv) <= 0) continue;

        char buf[256] = {0};
        sockaddr_in from{};
        int fromLen = (int)sizeof(from);
        const int n = ::recvfrom(s, buf, (int)sizeof(buf) - 1, 0,
                                 reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n <= 0) continue;

        const std::vector<std::string> tok = SplitTokens(std::string(buf, (size_t)n));
        if (tok.empty()) continue;
        // 只认 WHO；别的报文（含老的 MODE）一律当没看见 —— 不回错误包，
        // 免得被拿去当反射放大用
        if (Upper(tok[0]) != "WHO") continue;

        char ip[64] = "?";
        ::inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));

        const ULONGLONG now = ::GetTickCount64();
        if (!DiscoveryAllowed((unsigned long)from.sin_addr.s_addr, now)) continue;  // 限速：不回也不记

        const std::string ver = (tok.size() > 1) ? tok[1] : std::string();
        if (ver != "1") {
            Log("发现：忽略一条版本不符的 WHO（版本「%s」）  来源=%s", ver.c_str(), ip);
            continue;
        }

        char reply[64];
        std::snprintf(reply, sizeof(reply), "HERE 1 %u", g_opts.port);
        ::sendto(s, reply, (int)::strlen(reply), 0,
                 reinterpret_cast<sockaddr*>(&from), fromLen);
        Log("发现：%s 询问地址 → 已回 %s", ip, reply);
    }
    ::closesocket(s);
}

// ---------------------------------------------------------------------------
//  键盘接收器状态帧（3b：从 PowerShell 桥接搬进服务端）
// ---------------------------------------------------------------------------
//  为什么需要：键盘的 Fn 组合是固件内部按键，主机收不到。接收器在"键盘归属
//  变化"时会从厂商接口吐一帧状态 —— Mac 拿到它就能**提前约 1.5 秒**切屏，
//  比等蓝牙事件快得多。
//
//  原桥接干的三件事，一件都不能丢：
//    1) 读帧 -> "KEY xx xx …"（前 8 字节，大写十六进制、空格分隔）-> UDP 发给 Mac 的 45790
//    2) 每 2 秒发一次 "HB"（维持回程通道，同时让 Mac 记住我们的地址）
//    3) 收 Mac 回到这个 socket 的包（MODE …）-> 交给 HandleControlDatagram
//
//  为什么这三件事必须共用一个 socket：Mac 是"往收到包的源地址回"——
//  它把 MODE 请求发回我们发 KEY/HB 的那个源端口。所以要收得到回包，
//  就必须同一个 socket 又发又收，这正是原来桥接的做法
//  （它 Bind 了一个临时端口，既发 KEY/HB 又 Receive 回包）。
//
//  只读：GENERIC_READ 打开设备，只 ReadFile 读输入报文，不写任何东西。

SOCKET                     g_kbSock = INVALID_SOCKET;
std::mutex                 g_kbDestMutex;
sockaddr_in                g_kbDest{};
std::string                g_kbDestIp;
bool                       g_kbDestValid = false;

std::mutex                 g_kbDevMutex;   // 保护 g_kbDev（退出时要取消阻塞中的读）
HANDLE                     g_kbDev = INVALID_HANDLE_VALUE;

std::atomic<bool>          g_kbFound{false};
std::atomic<unsigned long> g_kbFrames{0};

// 已连接客户端（Mac）的 IP；没连接时返回空串
std::string CurrentClientIp() {
    const unsigned long a = g_peerIp4.load();
    if (a == 0) return std::string();
    in_addr in{};
    in.s_addr = a;
    char buf[64] = {0};
    if (::inet_ntop(AF_INET, &in, buf, sizeof(buf)) == nullptr) return std::string();
    return std::string(buf);
}

// 更新目标地址（同一地址重复调用不重复记日志）
void SetKbDest(const std::string& ip) {
    if (ip.empty()) return;
    {
        std::lock_guard<std::mutex> lk(g_kbDestMutex);
        if (g_kbDestValid && g_kbDestIp == ip) return;
        sockaddr_in d{};
        d.sin_family = AF_INET;
        d.sin_port   = htons((u_short)g_opts.kbPort);
        if (::inet_pton(AF_INET, ip.c_str(), &d.sin_addr) != 1) return;
        g_kbDest      = d;
        g_kbDestIp    = ip;
        g_kbDestValid = true;
    }
    Log("键盘抢跑：目标地址 = %s:%u", ip.c_str(), g_opts.kbPort);
}

// 把一行（"KEY …" / "HB"）发给 Mac；还没目标地址时直接丢掉（不刷屏）
void KbSendLine(const char* line, size_t len) {
    sockaddr_in to{};
    bool ok = false;
    {
        std::lock_guard<std::mutex> lk(g_kbDestMutex);
        to = g_kbDest;
        ok = g_kbDestValid;
    }
    if (!ok || g_kbSock == INVALID_SOCKET) return;
    ::sendto(g_kbSock, line, (int)len, 0,
             reinterpret_cast<sockaddr*>(&to), sizeof(to));
}

// 按 VID + usagePage + usage 找并打开接收器的厂商接口。
// **故意不写死 DevicePath** —— 那串实例号会随 USB 口/集线器变化。
HANDLE OpenKbdVendorInterface() {
    GUID hidGuid{};
    ::HidD_GetHidGuid(&hidGuid);

    HDEVINFO devInfo = ::SetupDiGetClassDevsW(&hidGuid, nullptr, nullptr,
                                              DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfo == INVALID_HANDLE_VALUE) {
        Log("键盘抢跑：SetupDiGetClassDevs 失败（%lu）", ::GetLastError());
        return INVALID_HANDLE_VALUE;
    }

    HANDLE found = INVALID_HANDLE_VALUE;
    SP_DEVICE_INTERFACE_DATA ifData{};
    ifData.cbSize = sizeof(ifData);

    for (DWORD index = 0;
         ::SetupDiEnumDeviceInterfaces(devInfo, nullptr, &hidGuid, index, &ifData);
         ++index) {
        DWORD need = 0;
        ::SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, nullptr, 0, &need, nullptr);
        if (need == 0) continue;

        std::vector<char> buffer(need);
        auto* detail = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA_W>(buffer.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        if (!::SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, detail, need,
                                                nullptr, nullptr)) {
            continue;
        }

        // 只请求 GENERIC_READ：符合"只读"定位（探测阶段验证过这样够用）
        HANDLE h = ::CreateFileW(detail->DevicePath, GENERIC_READ,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                 OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;

        HIDD_ATTRIBUTES attr{};
        attr.Size = sizeof(attr);
        HIDP_CAPS caps{};
        PHIDP_PREPARSED_DATA prep = nullptr;
        const bool okAttr = ::HidD_GetAttributes(h, &attr) != FALSE;
        const bool okCaps = ::HidD_GetPreparsedData(h, &prep) != FALSE
                         && ::HidP_GetCaps(prep, &caps) == HIDP_STATUS_SUCCESS;
        if (prep) ::HidD_FreePreparsedData(prep);

        if (okAttr && okCaps
            && attr.VendorID  == kKbdVid
            && caps.UsagePage == kKbdUsagePage
            && caps.Usage     == kKbdUsage) {
            Log("键盘抢跑：找到接收器 VID_%04X PID_%04X usagePage=0x%04X usage=0x%04X，"
                "输入报文 %u 字节",
                attr.VendorID, attr.ProductID, caps.UsagePage, caps.Usage,
                caps.InputReportByteLength);
            found = h;
            break;
        }
        ::CloseHandle(h);
    }

    ::SetupDiDestroyDeviceInfoList(devInfo);
    return found;
}

// 读帧线程：独占设备句柄（打开 / 读 / 拔了重枚举）。
void KeyboardReaderThread() {
    BYTE buf[256];
    ULONGLONG nextTry = 0;
    int fails = 0;

    while (g_running) {
        HANDLE dev = INVALID_HANDLE_VALUE;
        {
            std::lock_guard<std::mutex> lk(g_kbDevMutex);
            dev = g_kbDev;
        }

        if (dev == INVALID_HANDLE_VALUE) {
            if (::GetTickCount64() < nextTry) { ::Sleep(200); continue; }
            dev = OpenKbdVendorInterface();
            {
                std::lock_guard<std::mutex> lk(g_kbDevMutex);
                g_kbDev = dev;
            }
            if (dev == INVALID_HANDLE_VALUE) {
                g_kbFound = false;
                Log("键盘抢跑：没找到键盘接收器（VID_%04X usagePage=0x%04X usage=0x%04X）"
                    "—— 抢跑不可用，鼠标转发不受影响；30 秒后重试。",
                    kKbdVid, kKbdUsagePage, kKbdUsage);
                nextTry = ::GetTickCount64() + 30000;
                continue;
            }
            g_kbFound = true;
        }

        DWORD got = 0;
        if (!::ReadFile(dev, buf, (DWORD)sizeof(buf), &got, nullptr)) {
            if (!g_running) break;
            const DWORD e = ::GetLastError();
            Log("键盘抢跑：ReadFile 失败（%lu）—— 设备可能被拔了，重新枚举", e);
            {
                std::lock_guard<std::mutex> lk(g_kbDevMutex);
                if (g_kbDev == dev) g_kbDev = INVALID_HANDLE_VALUE;
            }
            ::CloseHandle(dev);
            dev = INVALID_HANDLE_VALUE;
            g_kbFound = false;
            if (++fails >= 3) { nextTry = ::GetTickCount64() + 30000; fails = 0; }
            continue;
        }
        fails = 0;
        if (got == 0) continue;

        // 与桥接完全一致：取前 8 字节、大写十六进制、单空格分隔
        const size_t n = (got < 8) ? (size_t)got : (size_t)8;
        char hex[64] = {0};
        size_t p = 0;
        for (size_t i = 0; i < n; ++i) {
            const int w = ::snprintf(hex + p, sizeof(hex) - p,
                                     (i == 0) ? "%02X" : " %02X", (unsigned)buf[i]);
            if (w > 0) p += (size_t)w;
        }

        std::string ip;
        {
            std::lock_guard<std::mutex> lk(g_kbDestMutex);
            ip = g_kbDestIp;
        }
        g_kbFrames++;
        Log("键盘抢跑：FF42/%02X frame: %s  -> UDP %s:%u",
            (unsigned)kKbdUsage, hex, ip.empty() ? "?" : ip.c_str(), g_opts.kbPort);

        const std::string line = std::string("KEY ") + hex;
        KbSendLine(line.c_str(), line.size());
    }

    std::lock_guard<std::mutex> lk(g_kbDevMutex);
    if (g_kbDev != INVALID_HANDLE_VALUE) {
        ::CloseHandle(g_kbDev);
        g_kbDev = INVALID_HANDLE_VALUE;
    }
}

// 链路线程：独占 socket（发 HB / 收回包）。
void KeyboardLinkThread() {
    if (g_opts.noKbWatch || g_opts.kbPort == 0 || g_opts.kbPort > 65535) {
        Log("键盘抢跑：已关闭（--no-kb 或 --kb-port 0）");
        return;
    }

    g_kbSock = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_kbSock == INVALID_SOCKET) {
        Log("键盘抢跑：socket() 失败（%d）", ::WSAGetLastError());
        return;
    }

    sockaddr_in local{};
    local.sin_family      = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port        = 0;      // 临时端口：Mac 往这里回包
    if (::bind(g_kbSock, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == SOCKET_ERROR) {
        Log("键盘抢跑：bind 失败（%d）", ::WSAGetLastError());
        ::closesocket(g_kbSock);
        g_kbSock = INVALID_SOCKET;
        return;
    }
    Log("键盘抢跑：已启动（读接收器状态帧 -> UDP %u；每 2 秒 HB；同一 socket 收回包）",
        g_opts.kbPort);

    if (!g_opts.macIp.empty()) SetKbDest(g_opts.macIp);

    std::thread reader(KeyboardReaderThread);

    ULONGLONG lastHb = 0;
    while (g_running) {
        // 目标地址：优先 --mac-ip；否则跟着已连接的客户端走
        if (g_opts.macIp.empty()) {
            const std::string ip = CurrentClientIp();
            if (!ip.empty()) SetKbDest(ip);
        }

        // 每 2 秒一个 HB（第一次立刻发，让 Mac 尽快记住我们的地址）
        const ULONGLONG now = ::GetTickCount64();
        if (now - lastHb >= 2000) {
            KbSendLine("HB", 2);
            lastHb = now;
        }

        // 收回包：Mac 的 MODE 请求会发回这个 socket
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(g_kbSock, &rd);
        timeval tv{};
        tv.tv_sec  = 0;
        tv.tv_usec = 200000;
        if (::select(0, &rd, nullptr, nullptr, &tv) > 0) {
            char buf[512] = {0};
            sockaddr_in from{};
            int fromLen = (int)sizeof(from);
            const int n = ::recvfrom(g_kbSock, buf, (int)sizeof(buf) - 1, 0,
                                     reinterpret_cast<sockaddr*>(&from), &fromLen);
            if (n > 0) {
                std::string reply;
                if (HandleControlDatagram(buf, n, reply, "键盘抢跑 socket") && !reply.empty()) {
                    ::sendto(g_kbSock, reply.c_str(), (int)reply.size(), 0,
                             reinterpret_cast<sockaddr*>(&from), fromLen);
                }
            }
        }
    }

    // 退出：取消阻塞中的 ReadFile，让读线程自己收尾（句柄归它管，这里不关，
    // 免得两头都 CloseHandle）。
    {
        std::lock_guard<std::mutex> lk(g_kbDevMutex);
        if (g_kbDev != INVALID_HANDLE_VALUE) ::CancelIoEx(g_kbDev, nullptr);
    }
    if (reader.joinable()) reader.detach();   // 进程即将退出，不强等
}

}  // namespace

// ---------------------------------------------------------------------------
//  main
// ---------------------------------------------------------------------------

int wmain(int argc, wchar_t** argv) {
    ::SetConsoleOutputCP(CP_UTF8);
    ::SetConsoleTitleW(L"Traiectus Server - Phase 3");
    setvbuf(stdout, nullptr, _IOFBF, 1 << 15);

    // ---- 界面语言：① --lang zh|en ② 系统 UI 语言 ----
    //   ★ 服务端**不读** launcher 的 config.ini —— 两者目录布局不同（以前踩过这个坑），
    //     语言由 launcher 在命令行上用 --lang 显式传过来。
    //   ★ 只影响"界面"（配对框 / --show 小窗 / --help / --list）：
    //     日志、TickStats 的每秒统计、以及 DEVICE/HOTKEY 这些机器可读行**永远是中文**，
    //     托盘的「服务端就绪 / 设备识别 / 热键状态」就是靠 grep 它们工作的。
    {
        bool langGiven = false;
        for (int i = 1; i + 1 < argc; ++i) {
            if (::wcscmp(argv[i], L"--lang") == 0) {
                if (::wcscmp(argv[i + 1], L"zh") == 0)      SetLang(Lang::Zh);
                else if (::wcscmp(argv[i + 1], L"en") == 0) SetLang(Lang::En);
                langGiven = true;
                break;
            }
        }
        if (!langGiven) {
            SetLang((PRIMARYLANGID(::GetUserDefaultUILanguage()) == LANG_CHINESE)
                        ? Lang::Zh : Lang::En);
        }
    }

    if (!ParseArgs(argc, argv)) return 2;

    // ---- 看门狗模式：不作为服务器运行，只为兜住 ClipCursor 的强杀风险 ----
    if (g_opts.watchdogMode) {
        return RunWatchdog(g_opts.watchdogPid);
    }

    // --help / --list 是"命令行查询"：先答完就退出，**不打印启动横幅**。
    //   （横幅属于日志，保持中文；查询输出要能整段干净地贴给别人看。）
    if (g_opts.help) { PrintHelp(); return 0; }
    if (g_opts.listDevices) { PrintAllDevices(); return 0; }

    ::printf("=====================================================================\n");
    ::printf(" Traiectus Server — Windows 端（只读捕获，转发给 Mac）\n");
    ::printf(" 不 hook、不拦截、不注入、不用驱动、不需要管理员权限。\n");
    ::printf(" 运行期间 Windows 自己的鼠标键盘完全正常。\n");
    ::printf("=====================================================================\n\n");

    // 本机网络（**中文日志**，2026-10-07 任务单 §2.4-4）：
    //   "地址又飘了"这种问题第一眼看这一行就够了 —— 适配器 / IP / 网关 / DHCP 租约到期。
    {
        const NetInfo ni = QueryDefaultRouteNet();
        if (ni.valid) {
            std::wstring line = L"本机网络：" + ni.adapter + L" " + ni.ip;
            if (!ni.gateway.empty()) line += L" 网关 " + ni.gateway;
            if (ni.dhcp) {
                const std::wstring exp = NetLeaseText(ni.leaseExpires);
                line += L" DHCP租约";
                line += exp.empty() ? L"（到期时间未知）" : (L" 过期 " + exp);
            } else {
                line += L"（静态地址，非 DHCP）";
            }
            ::printf("%s\n", U8(line).c_str());
        } else {
            ::printf("本机网络：没查到（当前没有在线的网卡？）\n");
        }
    }

    if (!g_opts.deviceFilter.empty())
        ::printf("设备过滤：%s\n", Narrow(g_opts.deviceFilter).c_str());

    // 鉴权状态。口令唯一来源是配对文件，所以这里只有三种情况，
    // 而且**只有第三种才是警告** ——「尚未配对」是全新安装的正常状态：
    // 配对本就是靠"在 Windows 上物理点一次确认"来防护的，不是靠没口令就不设防。
    {
        const std::wstring pairPath = PairFilePath();
        if (!ReadPairFileToken().empty()) {
            ::printf("鉴权：已配对（口令来自 %ls）\n", pairPath.c_str());
        } else if (::GetFileAttributesW(pairPath.c_str()) != INVALID_FILE_ATTRIBUTES) {
            ::printf("警告：配对文件存在但读不出内容（%ls），请检查权限或重新配对\n",
                     pairPath.c_str());
        } else {
            ::printf("鉴权：尚未配对 —— 第一台连接的 Mac 会在本机弹确认框，"
                     "点「允许」即完成配对\n");
        }
    }

    // ---- 鼠标切换热键：解析 --hotkey（解析失败就退回默认值，不拒绝启动）----
    {
        std::string hkErr;
        if (!ParseHotkey(g_opts.hotkey, g_hotkey, hkErr)) {
            ::printf("警告：--hotkey「%s」不能用（%s）—— 改用默认值 Ctrl+Alt+M。\n",
                     Narrow(g_opts.hotkey).c_str(), hkErr.c_str());
            Hotkey def;
            std::string dummy;
            ParseHotkey(L"Ctrl+Alt+M", def, dummy);   // 默认值一定能解析成功
            g_hotkey = def;
        }
    }

    // ---- 鼠标设备自动识别：没配设备串就自动进入观察 ----
    //    观察窗口内照常转发（过滤为空 = 全部转发），只是统计"谁真的在动"。
    if (g_opts.detectDevice) {
        StartDeviceWatch("按 --detect 重新识别");
    } else if (g_opts.deviceFilter.empty()) {
        StartDeviceWatch("没有指定 --device，自动识别");
    }

    // ---- WSA ----
    WSADATA wsa{};
    if (::WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        ::printf("WSAStartup 失败\n");
        return 3;
    }

    // ---- 监听 socket ----
    g_listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_listener == INVALID_SOCKET) {
        ::printf("创建 socket 失败（%d）\n", ::WSAGetLastError());
        ::WSACleanup();
        return 3;
    }
    // SO_EXCLUSIVEADDRUSE：防止同机上的其它程序抢占这个端口
    BOOL exclusive = TRUE;
    ::setsockopt(g_listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&exclusive, sizeof(exclusive));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons((u_short)g_opts.port);
    const std::string bindUtf8 = Narrow(g_opts.bindAddress);
    if (::inet_pton(AF_INET, bindUtf8.c_str(), &addr.sin_addr) != 1) {
        ::printf("监听地址无效：%s\n", bindUtf8.c_str());
        ::closesocket(g_listener);
        ::WSACleanup();
        return 3;
    }
    if (::bind(g_listener, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        ::printf("绑定 %s:%u 失败（%d）。端口可能已被占用。\n",
                 bindUtf8.c_str(), g_opts.port, ::WSAGetLastError());
        ::closesocket(g_listener);
        ::WSACleanup();
        return 3;
    }
    if (::listen(g_listener, 4) == SOCKET_ERROR) {
        ::printf("listen 失败（%d）\n", ::WSAGetLastError());
        ::closesocket(g_listener);
        ::WSACleanup();
        return 3;
    }

    // ---- 隐藏窗口 + Raw Input ----
    WNDCLASSEXW wc{};
    wc.cbSize        = (UINT)sizeof(wc);
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = L"Traiectus_Server_Window_v1";
    wc.hCursor       = ::LoadCursorW(nullptr, IDC_ARROW);
    if (!::RegisterClassExW(&wc)) {
        ::printf("RegisterClassExW 失败（%lu）\n", ::GetLastError());
        return 4;
    }

    g_hwnd = ::CreateWindowExW(0, wc.lpszClassName, L("Traiectus Server（日志在控制台）").c_str(),
                               WS_OVERLAPPEDWINDOW, 80, 80, 520, 180,
                               nullptr, nullptr, wc.hInstance, nullptr);
    if (g_hwnd == nullptr) {
        ::printf("CreateWindowExW 失败（%lu）\n", ::GetLastError());
        return 4;
    }
    if (g_opts.showWindow) {
        ::ShowWindow(g_hwnd, SW_SHOWNORMAL);
        ::UpdateWindow(g_hwnd);
    }

    RAWINPUTDEVICE rid{};
    rid.usUsagePage = 0x01;   // Generic Desktop Controls
    rid.usUsage     = 0x02;   // Mouse
    rid.dwFlags     = RIDEV_INPUTSINK | RIDEV_DEVNOTIFY;
    rid.hwndTarget  = g_hwnd;
    if (!::RegisterRawInputDevices(&rid, 1, (UINT)sizeof(rid))) {
        ::printf("RegisterRawInputDevices 失败（%lu）\n", ::GetLastError());
        return 5;
    }

    // ---- 全局快捷键：切换控制权（Windows <-> Mac），组合键可用 --hotkey 配 ----
    //  最后一行的 "HOTKEY ..." 是给**托盘程序读**的机器可读状态（托盘 grep 它）。
    //  前面那些中文行是给人看的，两行并存。
    if (!g_hotkey.enabled) {
        ::printf("控制权切换：热键已关闭（--hotkey off）—— 只能用 --start-in-mac-mode 或托盘切换\n");
        ::printf("HOTKEY OFF\n");
    } else if (::RegisterHotKey(g_hwnd, kHotkeyId, g_hotkey.mods, g_hotkey.vk)) {
        g_hotkeyRegistered = true;
        ::printf("控制权切换：按 %ls 在 Windows / Mac 之间切换（默认 = Windows，不转发）\n",
                 g_hotkey.text.c_str());
        ::printf("HOTKEY OK %ls\n", g_hotkey.text.c_str());
    } else {
        const DWORD hkErr = ::GetLastError();
        ::printf("警告：%ls 注册失败（错误 %lu）—— 可能已被别的程序占用。\n",
                 g_hotkey.text.c_str(), (unsigned long)hkErr);
        ::printf("      仍可用 --start-in-mac-mode 直接以 Mac 模式启动，"
        "或在托盘右键「设置鼠标切换快捷键」换一个组合键。\n");
        ::printf("HOTKEY FAIL %ls %lu\n", g_hotkey.text.c_str(), (unsigned long)hkErr);
    }
    if (g_opts.startInMacMode) {
        SetControlMode(true, "启动参数 --start-in-mac-mode");
    }

    // ---- 启动网络线程 ----
    ::QueryPerformanceFrequency(&g_qpcFreq);   // 供高精度往返/发送延迟统计使用
    std::thread networkThread(NetworkThread);
    // 3b：键盘抢跑（读接收器状态帧 + HB + 收回包）—— 原来是 PowerShell 桥接干的
    std::thread kbLinkThread(KeyboardLinkThread);
    kbLinkThread.detach();       // 随 g_running 结束，无需 join
    // 地址自动发现（Mac 广播 WHO → 我们单播回 HERE）—— 不依赖客户端连接
    std::thread discoveryThread(DiscoveryThread);
    discoveryThread.detach();    // 随 g_running 结束，无需 join

    PrintMouseList();
    ::printf("监听 %s:%u（TCP）\n", bindUtf8.c_str(), g_opts.port);
    if (g_opts.noKbWatch || g_opts.kbPort == 0)
        ::printf("键盘抢跑：已关闭（--no-kb 或 --kb-port 0）\n");
    else
        ::printf("键盘抢跑：读接收器状态帧 -> UDP %u（3b 起由服务端自己做，桥接已退役）\n",
                 g_opts.kbPort);
    if (g_opts.discoverPort == 0)
        ::printf("地址自动发现：已关闭（--discover-port 0）\n");
    else
        ::printf("地址自动发现：UDP %u（Mac 广播 WHO 1 → 本机回 HERE 1 %u）\n",
                 g_opts.discoverPort, g_opts.port);
    ::printf("在 Mac 上运行 Traiectus Client，填入这台电脑的 IP 与本端口即可连接。\n");
    ::printf("如果 Mac 连不上：Windows 防火墙首次会弹窗，勾选『专用网络』并允许；\n");
    ::printf("或在管理员 PowerShell 里按 README 的说明添加一条最小范围的入站规则。\n");
    ::printf("按 Ctrl+C 停止。本程序不会修改任何系统设置。\n");
    ::printf("--------------------------------------------------------------------------------\n");
    ::fflush(stdout);

    ::SetConsoleCtrlHandler(ConsoleHandler, TRUE);
    g_lastStats = ::GetTickCount64();

    while (g_running) {
        const DWORD r = ::MsgWaitForMultipleObjectsEx(0, nullptr, 200, QS_ALLINPUT, 0);
        if (!g_running) break;

        if (r == WAIT_OBJECT_0) {
            MSG msg;
            while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) { g_running = false; break; }
                ::TranslateMessage(&msg);
                ::DispatchMessageW(&msg);
            }
        }
        TickStats();
        TickDeviceWatch();      // 观察窗口到点 → DEVICE PICK / MULTI / NONE
        TickDeviceMiss();       // 配了串却一直没通过 → DEVICE MISS
    }

    // ---- 收尾 ----
    ::SetConsoleCtrlHandler(ConsoleHandler, FALSE);
    if (g_hotkeyRegistered) {
        ::UnregisterHotKey(g_hwnd, kHotkeyId);
        g_hotkeyRegistered = false;
    }

    // 最重要的一条安全保证：无论如何退出（正常退出 / Ctrl+C / 窗口关闭），
    // 都不让光标停留在"被锁定"的状态。
    if (g_cursorClipped.exchange(false)) {
        ::printf("已解除光标锁定。\n");
    }
    ::ClipCursor(nullptr);   // 兜底，重复解除无副作用
    g_running = false;

    // 如果配对确认框还开着，先把它关掉再收摊。
    // 让那个线程在我们拆掉全局对象之后才回包，是没必要的风险。
    g_pairDialogAbort = true;
    if (HWND pd = g_pairDialogHwnd.load()) {
        ::PostMessageW(pd, WM_CLOSE, 0, 0);
        for (int i = 0; i < 40 && g_pairDialogHwnd.load() != nullptr; ++i) ::Sleep(25);
    }

    if (g_listener != INVALID_SOCKET) {
        ::closesocket(g_listener);
        g_listener = INVALID_SOCKET;
    }
    if (networkThread.joinable()) networkThread.join();

    RAWINPUTDEVICE removeRequest{};
    removeRequest.usUsagePage = 0x01;
    removeRequest.usUsage     = 0x02;
    removeRequest.dwFlags     = RIDEV_REMOVE;
    removeRequest.hwndTarget  = nullptr;
    ::RegisterRawInputDevices(&removeRequest, 1, (UINT)sizeof(removeRequest));

    if (::IsWindow(g_hwnd)) ::DestroyWindow(g_hwnd);

    ::printf("\n===================== 本次会话汇总 =====================\n");
    ::printf("捕获事件总数：%llu   已发送行数：%llu   队列丢弃：%llu   协议错误：%llu\n",
             g_capturedTotal.load(), g_sentTotal.load(),
             g_queueDrops.load(), g_protocolErrors.load());
    ::printf("累计位移：dx=%+lld  dy=%+lld   按键事件：%llu   滚轮事件：%llu\n",
             g_dxTotal.load(), g_dyTotal.load(),
             g_buttonEvents.load(), g_wheelEvents.load());
    ::printf("=======================================================\n");
    ::printf("已退出。没有需要恢复的状态 —— Windows 的鼠标从未被改变。\n");
    ::fflush(stdout);

    ::WSACleanup();
    return 0;
}
