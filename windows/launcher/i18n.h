// ============================================================================
//  i18n.h —— Windows 端界面文案的中英对照表
// ----------------------------------------------------------------------------
//  用法：界面里写 L("退出")，中文时返回原文，英文时查表；查不到就回退中文。
//
//  约定（重要，别改）：
//    · **只翻界面**。运行日志（Log()/printf 的状态行）和机器可读行
//      （`:45789`、`DEVICE …`、`HOTKEY …`）一律保持中文 —— 托盘的
//      「服务端就绪 / 设备识别 / 热键状态」就是 grep 这些行工作的。
//    · 带参数的句子**不要整句查表**，用拼接：
//          L("鼠标切换：") + st.text + L(" ✓")
//          L("错误码 ") + std::to_wstring(code) + L("。")
//    · 设备串、文件路径、用户名不翻。
//    · 英文一律用 ASCII 标点（" ' - :），不要弯引号/破折号。
//
//  这份文件在 launcher\ 和 phase3-tcp\src\ 下各有一份，**内容必须完全一致**
//  （两端各自单独编译，不共享目标文件）。
//
//  语言来源三级优先（见 Traiectus.cpp / main.cpp）：
//    ① 命令行 --lang zh|en  ② config.ini 的 [ui] language  ③ 系统 UI 语言
// ============================================================================
#pragma once

#include <string>
#include <cwchar>

enum class Lang { Zh, En };

inline Lang& I18nLang() { static Lang l = Lang::Zh; return l; }
inline void  SetLang(Lang l) { I18nLang() = l; }
inline bool  IsEnglish() { return I18nLang() == Lang::En; }

struct TrEntry { const wchar_t* zh; const wchar_t* en; };

// static + inline：两个 .cpp 各拿到自己的一份，不需要额外的 .cpp 去定义
static const TrEntry kTrTable[] = {
    // ---- 托盘 tooltip ----
    { L"Traiectus：运行中",                      L"Traiectus: Running" },
    { L"Traiectus：已停止",                      L"Traiectus: Stopped" },
    { L"Traiectus：异常",                        L"Traiectus: Error" },
    { L"Traiectus：正在检测鼠标…（请动一下鼠标）", L"Traiectus: detecting mouse… (move it)" },
    { L"Traiectus：异常（服务端已退出）",         L"Traiectus: error (the server has exited)" },
    { L"Traiectus：异常（桥接已退出）",           L"Traiectus: error (the bridge has exited)" },

    // ---- 托盘菜单：状态三行 ----
    { L"状态：运行中",                           L"Status: running" },
    { L"状态：已停止",                           L"Status: stopped" },
    { L"状态：异常",                             L"Status: error" },
    { L"鼠标切换：",                             L"Mouse switching: " },
    { L" ✓",                                     L" ✓" },
    { L" ✗ 被占用",                              L" ✗ taken by another app" },
    { L"鼠标切换：未设置",                       L"Mouse switching: not set" },
    { L"鼠标：",                                 L"Mouse: " },
    { L"鼠标：✗ 未匹配（换鼠标了？点「检测鼠标」）", L"Mouse: ✗ no match (new mouse? click \"Detect mouse\")" },
    { L"鼠标：检测到 ",                          L"Mouse: " },
    { L" 个 → 点「检测鼠标」选一个",              L" found → click \"Detect mouse\" to pick one" },
    { L"鼠标：没检测到 → 点「检测鼠标」重试",      L"Mouse: none found → click \"Detect mouse\" to retry" },
    { L"全部（未指定）",                         L"all (not specified)" },
    // 「本机 IP：192.168.1.20」——给用户自己核对 ipconfig / 方便回报（2026-10-07）
    { L"本机 IP：",                              L"This PC: " },

    // ---- 托盘菜单：菜单项 ----
    //   注意：菜单项一律**不带结尾的省略号**（用户 2026-10-07 要求）——
    //   「设置鼠标切换快捷键」这一条同时是那个小窗的标题，所以表里只有这一份。
    { L"设置鼠标切换快捷键",                     L"Set mouse-switch hotkey" },
    { L"检测鼠标",                               L"Detect mouse" },
    { L"正在检测鼠标…（动一下鼠标）",             L"Detecting mouse… (move the mouse)" },
    { L"启动 Traiectus",                         L"Start Traiectus" },
    { L"重启",                                   L"Restart" },
    { L"重新配对",                               L"Re-pair" },
    { L"打开日志目录",                           L"Open log folder" },
    { L"退出",                                   L"Quit" },
    { L"语言",                                   L"Language" },

    // ---- 提示条 toast ----
    { L"正在检测鼠标",                           L"Detecting mouse" },
    { L"请在 8 秒内晃动你要用的那只鼠标。",        L"Move the mouse you want to use within 8 seconds." },
    { L"Traiectus 提示",                         L"Traiectus notice" },

    // ---- 弹窗：标题 ----
    { L"没有找到 config.ini",                    L"config.ini not found" },
    { L"config.ini 里有废弃的 --token",          L"config.ini still has the removed --token" },
    { L"启动失败",                               L"Start failed" },
    { L"找不到服务端程序",                       L"Server executable not found" },
    { L"启动服务端失败",                         L"Could not start the server" },
    { L"服务端启动超时",                         L"Server start timed out" },
    { L"启动桥接失败",                           L"Could not start the bridge" },
    { L"已清除配对",                             L"Pairing cleared" },
    { L"没有配对文件",                           L"No pairing file" },
    { L"删除失败",                               L"Delete failed" },
    { L"读不到 config.ini",                      L"Can not read config.ini" },
    { L"config.ini 格式不对",                    L"config.ini is malformed" },
    { L"写 config.ini 失败",                     L"Could not write config.ini" },
    { L"写 config.ini 不完整",                   L"config.ini write was incomplete" },
    { L"已锁定这只鼠标",                         L"Mouse locked in" },
    { L"检测成功，但没写进配置",                  L"Detected, but not saved to the config" },
    { L"没检测到鼠标",                           L"No mouse detected" },
    { L"检测超时",                               L"Detection timed out" },
    { L"选择鼠标设备",                           L"Select mouse device" },
    { L"配置已生成",                             L"Config created" },

    // ---- 弹窗：正文 ----
    { L"会把 config.example.ini 复制成 config.ini 吗？\n"
      L"里面主要是 --device（鼠标设备串）和端口，按你的机器改一下。\n"
      L"口令不用填 —— 第一次有 Mac 连过来时点一次「允许」就配好了。",
      L"Copy the template to config.ini?\n"
      L"It mainly holds --device (the mouse device string) and the port - adjust them for this machine.\n"
      L"No token needed: the first time a Mac connects, click \"Allow\" once and pairing is done." },
    { L"这个参数已经不用了（留着会让服务端启动失败）。\n"
      L"把 --token 那一段删掉即可：口令由配对生成，不用自己设。\n"
      L"（文件：launcher\\config.ini 的 [server] args）",
      L"That option no longer exists (keeping it makes the server fail to start).\n"
      L"Just delete the --token part: the token comes from pairing, you do not set it yourself.\n"
      L"(file: launcher\\config.ini, [server] args)" },
    { L"创建 Job Object 失败，无法安全地管理子进程。",
      L"Could not create the Job Object, so child processes cannot be managed safely." },
    { L"创建单实例锁失败。", L"Could not create the single-instance mutex." },
    { L"路径：\n", L"Path:\n" },
    { L"请先跑一次 phase3-tcp\\build-mingw.bat 生成它，或检查 config.ini 里的 server.exe。",
      L"Run phase3-tcp\\build-mingw.bat once to build it, or check server.exe in config.ini." },
    { L"错误码 ", L"Error code " },
    { L"。\n命令行：\n", L".\nCommand line:\n" },
    { L"没有在 ", L"It did not reach the listening state within " },
    { L" 秒内进入监听状态。\n\n请看日志：\n", L" seconds.\n\nSee the log:\n" },
    { L"鼠标转发仍然可用，但键盘跨机切换会失效。",
      L"Mouse forwarding still works, but keyboard switching will not." },
    { L"确定要重新配对吗？\n\n会删除这个文件：\n", L"Re-pair this machine?\n\nThis deletes:\n" },
    { L"\n\n注意：对当前已连接的会话没有影响 ——\n"
      L"Mac 会在**下一次连接**时被要求重新点一次「允许」。",
      L"\n\nThe current session is not affected -\n"
      L"the Mac will be asked to click \"Allow\" again on its next connection." },
    { L"Mac 下次连接时会重新询问。", L"The Mac will be asked again on its next connection." },
    { L"本来就没有配对文件（可能已经是未配对状态）。",
      L"There was no pairing file to begin with (it may already be unpaired)." },
    { L"。\n\n", L".\n\n" },
    { L"找不到 [server] 的 args= 那一行，没有改动。",
      L"The \"args=\" line under [server] was not found; nothing was changed." },
    { L"文件被占用或只读？没有改动。", L"File in use or read-only? Nothing was changed." },
    { L"请检查文件。", L"Please check the file." },
    { L"\n\n已写进 config.ini，以后只转发它。",
      L"\n\nSaved to config.ini; only this mouse will be forwarded from now on." },
    { L"检测到这只鼠标：\n", L"Detected this mouse:\n" },
    { L"\n\n但写 config.ini 失败（文件被占用/只读？）。",
      L"\n\nBut writing config.ini failed (file in use, or read-only?)." },
    { L"这 8 秒里没有鼠标移动。\n\n请再点一次「检测鼠标」，"
      L"然后在这 8 秒里晃动你要用的那只鼠标。",
      L"No mouse movement in those 8 seconds.\n\nClick \"Detect mouse\" again and move the mouse you\n"
      L"want to use during those 8 seconds." },
    { L"30 秒没有结论，已恢复正常运行。\n可以点「检测鼠标」重试。",
      L"No result after 30 seconds; normal operation resumed.\nYou can click \"Detect mouse\" to try again." },
    { L"已生成 config.ini（模板：", L"config.ini was created from the template: " },
    { L"）。改完再启动即可。", L"). Edit it and start again." },
    { L"没能生成 config.ini：模板 config.example.ini 不存在。\n"
      L"现在用的是内置默认值，功能是完整的，只是设备过滤可能不匹配这台机器的鼠标。",
      L"Could not create config.ini: the template config.example.ini is missing.\n"
      L"Built-in defaults are in use - fully functional, but the device filter may not match this machine's mouse." },

    // ---- 快捷键设置小窗 ----
    { L"请按下你想要的组合键",                   L"Press the key combination you want" },
    { L"修饰键：Ctrl / Alt / Shift / Win（至少 1 个）",
      L"Modifiers: Ctrl / Alt / Shift / Win (at least 1)" },
    { L"主键：A–Z / 0–9 / F1–F24",              L"Main key: A-Z / 0-9 / F1-F24" },
    { L"保存",                                   L"Save" },
    { L"取消",                                   L"Cancel" },
    { L"确定",                                   L"OK" },
    { L"删除配对文件",                           L"Delete pairing file" },
    { L"不使用热键",                             L"No hotkey" },
    { L"保存后不再占用任何组合键",                L"Saves as off - no key combination will be reserved" },
    { L"继续按主键…",                            L"Now press the main key…" },
    { L"这个键不支持：主键只认 A–Z / 0–9 / F1–F24",
      L"Unsupported key: the main key must be A-Z / 0-9 / F1-F24" },
    { L"至少要有 1 个修饰键，否则会毁掉正常打字",
      L"At least one modifier is required, or normal typing breaks" },
    { L"按「保存」后服务端会重启，新组合键立刻生效",
      L"Saving restarts the server, so the new combination takes effect immediately" },
    { L"检测到多个设备，请选一个",                L"Multiple devices detected - pick one" },
    { L"以后换鼠标：托盘右键 →「检测鼠标」再跑一次",
      L"Changed mouse later? Tray right-click -> \"Detect mouse\" again" },

    // ---- 服务端：配对确认框 ----
    { L"Traiectus 配对",                         L"Traiectus pairing" },
    { L"有一台 Mac 想连接这台电脑",               L"A Mac wants to connect to this PC" },
    { L"允许",                                   L"Allow" },
    { L"拒绝",                                   L"Deny" },

    // ---- 服务端：启动横幅 / 控制台标题 ----
    // ★ 这一组的来源：服务端 --show 时显示的那个小窗（隐藏窗口的标题 + WM_PAINT 正文）。
    //   **控制台里那一整块 printf 启动横幅不在翻译范围内** —— 按约定它是日志，
    //   和 TickStats 的每秒统计行一样保持中文。
    { L"Traiectus Server（日志在控制台）",        L"Traiectus Server (log in console)" },
    { L"Traiectus Server 正在运行。",             L"Traiectus Server is running." },
    { L"Ctrl+Alt+M : 切换控制权（Windows <-> Mac）",
      L"Ctrl+Alt+M : switch control (Windows <-> Mac)" },
    { L"  · Windows 模式：不转发、不锁光标（打游戏用这个）",
      L"  · Windows mode: no forwarding, no cursor lock (use this for gaming)" },
    { L"  · Mac 模式：转发事件，并把 Windows 光标锁在原地",
      L"  · Mac mode: forwards events and pins the Windows cursor" },
    { L"日志在控制台窗口；请在控制台按 Ctrl+C 停止程序。",
      L"The log is in this console window; press Ctrl+C to stop." },

    // ---- 服务端：--list ----
    { L"本机的鼠标类 Raw Input 设备（用 --device 指定其中之一，通常选你在用的那只）：\n",
      L"Mouse-class Raw Input devices on this PC (you usually do not need --device: without it\n"
      L"  the server detects the mouse you are using; to pin one, put a line from here into --device):\n" },
    { L"GetRawInputDeviceList 失败（错误 ",       L"GetRawInputDeviceList failed (error " },
    { L"）\n",                                   L")\n" },
    { L"系统没有报告任何 Raw Input 设备。\n",     L"The system reported no Raw Input devices.\n" },
    { L"GetRawInputDeviceList 第二次调用失败（",   L"Second GetRawInputDeviceList call failed (" },
    { L"Raw Input 设备共 ",                       L"Raw Input devices: " },
    { L" 个：\n\n",                               L"\n\n" },

    // ---- 服务端：命令行错误 ----
    { L"--pair-file 需要一个路径\n",              L"--pair-file needs a path\n" },
    { L"--pair-timeout 需要秒数\n",               L"--pair-timeout needs a number of seconds\n" },
    { L"--pair-timeout 要在 1~3600 秒之间\n",     L"--pair-timeout must be between 1 and 3600 seconds\n" },
    { L"--watchdog 需要一个进程号\n",             L"--watchdog needs a process id\n" },
    { L" 需要一个值\n",                           L" needs a value\n" },
    { L"不认识的参数：",                          L"Unknown option: " },
    { L"端口必须在 1..65535\n",                   L"Port must be within 1..65535\n" },
    { L"--lang 只认 zh 或 en\n",                  L"--lang accepts only zh or en\n" },
};

static const int kTrCount = (int)(sizeof(kTrTable) / sizeof(kTrTable[0]));

// 查表；查不到就回退中文原文（宁可显示中文，也不要显示空字符串）
inline std::wstring L(const wchar_t* zh) {
    if (!zh) return std::wstring();
    if (I18nLang() == Lang::Zh) return std::wstring(zh);
    for (int i = 0; i < kTrCount; ++i) {
        if (::wcscmp(kTrTable[i].zh, zh) == 0) return std::wstring(kTrTable[i].en);
    }
    return std::wstring(zh);
}

inline std::wstring L(const std::wstring& zh) { return L(zh.c_str()); }

// 便利重载：允许直接在界面代码里写 L("中文原文")（不带 L 前缀的窄字符串）。
//   窄字面量按 **UTF-8** 解释 —— 所以两个前提必须成立：
//     · 源码本身是 UTF-8（工程里所有 .cpp/.h 都是）；
//     · 编译时编/执行字符集都是 UTF-8
//       （MinGW 默认就是；MSVC 由 build.bat 的 /utf-8 保证）。
//   转换后再走上面那张对照表，所以和 L(L"中文") 完全等价。
//   注意：这个头文件依赖 <windows.h>（MultiByteToWideChar），
//   两个使用方都是先 include windows.h 再 include 本文件。
#ifdef _WIN32
inline std::wstring L(const char* zh) {
    if (!zh) return std::wstring();
    const int n = ::MultiByteToWideChar(CP_UTF8, 0, zh, -1, nullptr, 0);
    if (n <= 1) return std::wstring();
    std::wstring w((size_t)n, L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, zh, -1, &w[0], n);
    w.resize((size_t)n - 1);
    return L(w.c_str());
}
#endif
