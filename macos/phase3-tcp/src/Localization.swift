// ============================================================================
//  Localization —— 界面语言（中文 / English）
// ----------------------------------------------------------------------------
//  为什么不用 Localizable.strings：
//    · .strings 要**重启 app** 才生效，而语言开关最好是"点一下当场变"
//    · 中英对照放在同一个文件里，改文案时一眼能看到两边，不容易漏
//    · 日志**不翻译**（排查时两端对得上最重要），只有界面走 L()
//
//  用法：界面里写 L("通用")，中文时返回原文，英文时查表。
//  查不到就返回原文（宁可显示中文，也不要显示空白或 key）。
// ============================================================================

import Foundation

enum AppLanguage: String, CaseIterable {
    case zh              // 中文
    case en              // English

    var label: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum Localization {

    static let defaultsKey = "traiectus.language"

    /// 当前语言。
    ///
    /// 设置里**没有**「跟随系统」这一项（就两个选项：中文 / English）。但"从没选过"
    /// 不等于"默认中文"：首次启动按系统偏好挑一个（中文系统给中文、其他给英文），
    /// 免得英文用户一上来看到满屏中文。用户一点，就按点的存下来，之后不再变。
    static var language: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            // 老版本存的 "system" 会解析失败 → 落到系统默认（读的时候不写盘）
            return AppLanguage(rawValue: raw) ?? systemDefault
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 系统偏好的语言（只在"用户还没选过"时用）
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    /// 把存盘里的历史取值归一化成一个真选项。
    /// 老版本有过「跟随系统」，存的是 "system" —— 那个取值现在解析不出来（读的时候
    /// 会落到系统默认，不会出错），但不归一化的话设置文件里会一直留着一个已经不存在的
    /// 取值。启动时调用一次。
    static func normalizeStoredValue() {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        guard AppLanguage(rawValue: raw) == nil else { return }
        let fixed = language.rawValue
        UserDefaults.standard.set(fixed, forKey: defaultsKey)
        NSLog("[Traiectus] 界面语言旧取值 %@ 已归一化为 %@", raw.isEmpty ? "(空)" : raw, fixed)
    }

    static var isEnglish: Bool { language == .en }

    /// 界面文案：中文直接返回原文，英文查表
    static func text(_ zh: String) -> String {
        guard isEnglish else { return zh }
        return english[zh] ?? zh
    }

    /// 带占位符的文案：模板里写 `{n}` 这类占位符，两边（中/英）都用同一套
    ///   例：`L("① 收到 {n} 帧 ✓", ["n": "3"])`
    ///   —— 这样带数字的句子也能整句翻译，不用把一句话拆成几段再拼
    static func text(_ zh: String, _ vars: [String: String]) -> String {
        var s = text(zh)
        for (key, value) in vars {
            s = s.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return s
    }

    // ---------------------------------------------------------------- 对照表
    //  只放**用户可见的界面文案**；日志不在其中（保持中文）。
    //  术语统一：Win / Mac、hotkey（快捷键）、head-start（抢跑）、
    //            keyboard link（键盘联动）、source frames（状态帧）
    static let english: [String: String] = [

        // ---- 标签页
        "通用": "General",
        "键盘": "Keyboard",
        "显示": "Display",
        "连接": "Link",
        "高级": "Advanced",

        // ---- 通用
        "语言": "Language",
        "键盘联动": "Keyboard link",
        "启用键盘联动": "Enable keyboard link",
        "按键盘上的切换快捷键时，屏幕和鼠标跟着一起切。\n"
            + "关掉后：① 不再自动切屏 / 切鼠标（键盘本身照常在两边切，只是本软件不跟）；"
            + "② Mac 睡眠时不再自动把屏幕和鼠标交给 Windows（醒来也不会自动切回）；"
            + "③ 键盘页的「学习」收不到状态帧，用不了。":
            "When you press your keyboard's switch key, the screen and mouse follow.\n"
            + "When off: (1) no automatic screen / mouse switching (the keyboard still switches on its own); "
            + "(2) when the Mac sleeps it no longer hands the screen and mouse to Windows (and won't switch"
            + " back on wake); (3) the Keyboard page can't learn (no source frames).",
        "需要注意": "Needs attention",
        "睡眠热键": "Sleep hotkey",
        "启用睡眠快捷键": "Enable sleep hotkey",
        "组合键": "Key combination",
        "鼠标切换": "Mouse switching",
        "启用鼠标切换快捷键": "Enable mouse-switch hotkey",
        "按一下就在 Mac 与 Win 之间切换鼠标控制权（等价于在 Win 上按 Ctrl+Alt+M）":
            "Switches mouse control between Mac and Win (same as Ctrl+Alt+M on Windows)",
        "启动": "Startup",
        "登录时启动": "Launch at login",
        "登录这台 Mac 时自动启动 Traiectus。关了也能用 —— 双击图标打开就行。":
            "Start Traiectus automatically when you log in to this Mac. "
            + "Turning it off doesn't disable anything — just open it yourself.",
        "没能改成功：": "Couldn't change it: ",
        "未开启": "Off",
        "要在系统设置的「登录项」里允许": "Allow it under System Settings → Login Items",
        "找不到 app —— 先把它放进「应用程序」": "App not found — move it to Applications first",
        "未知状态": "Unknown",

        // ---- 键盘
        "键盘识别": "Keyboard recognition",
        "我的键盘": "My keyboard",
        "点一下从检测到的键盘里选一把（联动要认准是哪一把）":
            "Click to pick from the keyboards detected (the link needs to know which one)",
        "选择你的键盘": "Choose your keyboard",
        "选错了，按键盘上的切换键时屏幕和鼠标不会跟着切。":
            "Pick the wrong one and the screen and mouse won't follow your switch key.",
        "现在没检测到键盘 —— 键盘正连在 Win 上时就是这样。切到 Mac 再点「重新检测」。":
            "No keyboard detected — that's normal while it's on Windows. Switch it to the Mac and scan again.",
        "重新检测": "Scan again",
        "提前切屏": "Head-start switching",
        "学到的规则": "Learned rules",
        "学习步骤": "Steps",
        "取消学习": "Cancel learning",
        "先确认接法（Win 走无线、Mac 走蓝牙），":
            "First check the setup (Win on 2.4G, Mac on Bluetooth), ",
        "并按键盘上切到 Win / 切回 Mac 的快捷键各切一次，确认两边都能正常打字":
            "and press your \"to Win\" / \"to Mac\" shortcuts once each; make sure you can type on both.",
        "点上面那个按钮，然后在 8 秒内按键盘上切到 Win 的快捷键":
            "Click the button above, then press your \"to Win\" shortcut within 8 seconds",
        "再点一次，然后在 8 秒内按键盘上切回 Mac 的快捷键":
            "Click it again, then press your \"to Mac\" shortcut within 8 seconds",
        "自动算规则并保存（立刻生效）": "Rules are computed and saved (effective immediately)",
        "点「开始复测」验证一遍": "Click \"Verify\" to confirm",

        // ---- 显示
        "显示器切换": "Monitor switching",
        "先在显示器的 OSD 菜单里把 ": "First turn on ",
        "DDC/CI 打开": "DDC/CI in the monitor's OSD menu",
        "不少型号出厂默认是关的；不开的话下面点了不会有任何反应。":
            "Many monitors ship with it off — nothing below works until it's on.",
        "正在读取显示器…": "Reading the monitor…",
        "开始学习显示器切换": "Learn monitor switching",

        // ---- 连接
        "状态": "Status",
        "断开": "Disconnect",
        "重新连接": "Reconnect",
        "正在查找 Windows…": "Looking for Windows…",
        "等待在 Windows 上确认…": "Waiting for confirmation on Windows…",
        "配对未完成（": "Pairing incomplete (",
        "）": ")",
        "等太久没确认": "timed out",
        "被拒绝": "denied",
        "Windows 已配对过": "Windows already paired",
        "Windows 正忙": "Windows busy",
        "已连接 · 鼠标在本机": "Connected · mouse on this Mac",
        "已连接 · 鼠标在 Windows": "Connected · mouse on Windows",
        "连接中…": "Connecting…",
        "Windows 端未运行": "Windows side not running",
        "异常：口令或版本不对": "Error: password or version mismatch",
        "要在 Windows 托盘点「重新配对」，然后回来点「连接」。":
            "Use the Windows tray → \"Pair again\", then click Connect here.",
        "口令由配对自动生成 —— 在 Windows 上点「允许」即可，不用填任何东西。":
            "The password is created by pairing — just click Allow on Windows. Nothing to type.",
        "未填写地址": "No address",
        "连接设置": "Connection settings",
        "正在查找…": "Searching…",
        "自动检测": "Auto-detect",
        "在本机网段里自动寻找 Windows，找到就填到这里并立刻重连":
            "Finds Windows on your LAN, fills it in and reconnects",
        "Windows 地址": "Windows address",
        "启动时自动连接": "Connect on launch",

        // ---- 高级
        "端口（两端默认 45789）": "Port (default 45789)",
        "连接中不可修改 —— 先在「连接」页点「断开」":
            "Can't change while connected — click Disconnect first",
        "只有端口冲突时才需要改；改完会自动重连":
            "Only needed if the port is in use; reconnects automatically",
        "连接参数": "Connection",
        "打开日志目录": "Open logs folder",
        "打开配置文件": "Open config file",
        "文件": "Files",
        "日志在 ~/Library/Logs；硬件参数改 config.json 后重启生效。":
            "Logs live in ~/Library/Logs; hardware settings are in config.json (restart to apply).",
        "退出 Traiectus": "Quit Traiectus",
        "确定退出 Traiectus？": "Quit Traiectus?",
        "退出": "Quit",
        "取消": "Cancel",
        "退出后键盘联动、鼠标转发与抢跑都会停止。想再用就双击桌面图标。":
            "Quitting stops the keyboard link, mouse forwarding and head-start. "
            + "Double-click the desktop icon to start again.",
        "收起": "Collapse",
        "展开": "Expand",

        // ---- 面板 / 快捷键录制器
        "设置（⌘,）": "Settings (⌘,)",
        "设置": "Settings",
        "设置…": "Settings…",
        "按下组合键…": "Press a shortcut…",
        "点一下，然后按下想要的组合键（Esc 取消）": "Click, then press the shortcut you want (Esc to cancel)",
        "需要 ⌘ / ⌃ / ⌥": "Needs ⌘ / ⌃ / ⌥",
        "空格": "Space",
        "帮助": "Help",
        "键码 {n}": "key {n}",

        // ---- 功能状态（FeatureStatus：通用页「需要注意」那一行的值）
        "已启用": "Enabled",
        "需要授权": "Needs permission",
        "重连中…": "Reconnecting…",
        "快捷键被占用": "Hotkey already in use",

        // ---- 键盘页
        "未命名键盘": "Unnamed keyboard",
        "蓝牙": "Bluetooth",
        "未检测到键盘（可能正连在 Win 上）": "No keyboard detected (it may be on Windows right now)",
        "配置的 {id} 在 Mac 上看不到 —— 点这里选一把":
            "Configured {id} isn't visible on the Mac — click here to pick one",

        // ---- 键盘页：学习向导（客户端层动态文案）
        "开始学习键盘切换": "Learn keyboard switching",
        "开始采集（8 秒）": "Start capture (8 s)",
        "开始复测（15 秒）": "Start verify (15 s)",
        "先打开「键盘联动」—— 学习靠它收帧。":
            "Turn on \"Keyboard link\" first — learning needs it to receive frames.",
        "Win 端没连上：状态帧要靠它转发过来。":
            "Windows side isn't connected — source frames are forwarded from it.",
        "先把键盘切回 Mac（键盘上切 Mac 的那个快捷键），再开始 —— 第一段采集要录「切去 Win」那一刻。":
            "Switch the keyboard back to the Mac first (your \"to Mac\" key), then start"
            + " — the first capture records the moment it goes to Win.",
        "① 点「开始采集」，然后在 8 秒内按键盘上切到 Win 的快捷键":
            "① Click \"Start capture\", then press your \"to Win\" key within 8 seconds",
        "采集 8 秒…（现在就可以按键盘切换）": "Capturing for 8 s… (press the switch key now)",
        "① 没收到任何帧。请确认：键盘已经切到 Win、接收器插在「这台」Win 上、而且「键盘联动」是开着的。然后重来一次。":
            "① No frames received. Check that the keyboard is on Win, its receiver is plugged into"
            + " \"this\" PC, and that \"Keyboard link\" is on. Then try again.",
        "① 收到 {n} 帧 ✓　② 点「开始采集」，然后在 8 秒内按键盘上切回 Mac 的快捷键":
            "① {n} frames received ✓  Now ② click \"Start capture\", then press your \"to Mac\" key"
            + " within 8 seconds",
        "② 没收到任何帧。请确认键盘真的切回了 Mac（能在 Mac 上打字），再重来一次。":
            "② No frames received. Make sure the keyboard really is back on the Mac (you can type"
            + " there), then try again.",
        "③ 规则已保存并生效 ✓　现在复测：点「开始复测」，然后在 15 秒内用键盘上的切换快捷键各切 2 次":
            "③ Rules saved and active ✓  Now verify: click \"Start verify\", then press your switch"
            + " key twice in each direction within 15 seconds",
        "复测中…15 秒，请用键盘上的切换快捷键各切 2 次":
            "Verifying… 15 s — press your switch key twice in each direction",
        "复测结果：": "Verify result: ",
        "学不出来：": "Couldn't build a rule: ",
        "未知原因": "unknown reason",
        "（A 组 {a} 帧 / B 组 {b} 帧）": "(group A: {a} frames / group B: {b} frames)",
        "规则学出来了，但写配置文件失败：{why}": "The rule was learned, but writing the config failed: {why}",
        "（区分位：第 {bytes} 字节；掩码 {mask}）": "(distinguishing byte(s): {bytes}; mask {mask})",

        // ---- 键盘页：复测结论（KeyboardFrameRules —— 中文原文在那边，这边只放英文）
        "支持抢跑（两个方向都能认）": "Head-start works (both directions recognised)",
        "支持抢跑（只认「去 Win」方向 —— 这是常态，提前量只在这个方向）":
            "Head-start works (only the \"to Win\" direction — that's normal; the head-start only"
            + " exists in that direction)",
        "只认「回 Mac」方向（少见；该方向本来就没有提前量）":
            "Only the \"to Mac\" direction is recognised (rare; there's no head-start in that direction)",
        "不支持抢跑（收到了帧，但现有规则一条都认不出）":
            "No head-start (frames arrive, but no rule matches them)",
        "这次没检测到键盘切换 —— 再跑一次，期间用键盘上的切换快捷键去 Win / 回 Mac 各一次":
            "No keyboard switch detected — run it again and press your switch key once in each direction",
        "读不到状态帧 → 这把键盘用不了抢跑": "No source frames → this keyboard can't use head-start",
        "仍然能用：走蓝牙方案 —— 去 Win 方向慢约 1.7 秒，回 Mac 方向本来就一样快，":
            "Still works over Bluetooth — about 1.7 s slower going to Win, the same speed coming back. ",

        // ---- 键盘页：学习失败原因（KeyboardFrameRules 的结构化失败标识）
        "两侧都没有收到能解析的帧": "No parseable frames arrived from either side",
        "Win 那一侧没收到能解析的帧": "No parseable frames arrived from the Win side",
        "Mac 那一侧没收到能解析的帧": "No parseable frames arrived from the Mac side",
        "帧长度太短，没法比对": "The frames are too short to compare",
        "取代表帧失败": "Couldn't pick a representative frame",
        "两组样本区分不开": "The two sample groups can't be told apart",
        "生成规则失败": "Couldn't build the rule",
        "收到 A 组 {a} 条、B 组 {b} 条（能解析成十六进制的：{pa} / {pb}）":
            "Received {a} frames in group A and {b} in group B (parseable as hex: {pa} / {pb})",
        "逐字节比过：没有任何一个字节是「两侧各自恒定、且彼此不同」。\n常见原因：接口选错了（比如读到了 FF42/01 而不是 FF42/02）；两次采集其实是同一个方向；或者这把键盘不吐方向信息。":
            "Compared byte by byte: no byte is constant within each group and different between them.\n"
            + "Usual causes: the wrong interface was read (e.g. FF42/01 instead of FF42/02); both captures"
            + " were actually the same direction; or this keyboard simply doesn't report direction.",

        // ---- 键盘页：检测方式与提示（客户端层动态文案）
        "未开启（联动关着）": "Off (keyboard link is off)",
        "打开「键盘联动」后才会收键盘信号（状态帧）":
            "Turn on \"Keyboard link\" to receive keyboard signals (source frames)",
        "未开启（还没收到键盘信号）": "Off (no keyboard signal yet)",
        "本次运行还没收到键盘信号（状态帧）—— 切一次键盘就能判断。收不到时只能等 Mac 自己发现，切过去会晚约 1.7 秒。":
            "No keyboard signal (source frames) yet this run — switch the keyboard once to check. "
            + "Without frames, switching waits for the Mac to notice — about 1.7 s later.",
        "已开启": "On",
        "键盘信号（状态帧）正常在收（本次运行 {n} 条，最近一次 {ago}）：":
            "Keyboard signals (source frames) are arriving (this run: {n}, last one {ago}): ",
        "键盘刚从 Win 那边离开，屏幕就先切过去了 —— 切过去几乎无感。":
            "the screen switches the moment the keyboard leaves Windows — it feels instant.",

        // ---- 显示页（客户端层动态文案）
        "没找到 m1ddc —— 切屏不可用": "m1ddc not found — monitor switching is unavailable",
        "没读到显示器（接了外接屏吗？）": "No monitor detected (is an external display connected?)",
        " · 当前输入源 ": " · current input ",
        " · 读不到输入源": " · input can't be read",
        "正在读取…": "Reading…",
        "读不到显示器的输入源。\n① 先确认显示器的 OSD 里 DDC/CI 是开启的（很多型号出厂是关的）；\n② 再确认显示器接在 Mac 的 HDMI / USB-C 上。":
            "Can't read the monitor's input.\n① First check that DDC/CI is on in the monitor's OSD menu (many ship with it off);\n② then check that the monitor is connected to the Mac over HDMI / USB-C.",
        "已记住 Mac 这边：{n}\n现在按显示器上的按钮切到 Windows —— 不用再点任何东西，切过去我就会自动记下来。":
            "Remembered the Mac side: {n}\nNow press the button on the monitor to switch to Windows"
            + " — nothing else to click, I'll note it down automatically.",
        "学好了：Mac = {mac}，Windows = {win}。\n已保存，切屏立刻用这套编号。":
            "Learned: Mac = {mac}, Windows = {win}.\nSaved — the next switch uses these numbers.",
        "保存失败：{why}": "Couldn't save: {why}",
        "等了 60 秒还没看到显示器切走。\n确认一下：显示器的 OSD 里 DDC/CI 是开的；然后用显示器上的按钮切到 Windows 那边。":
            "Waited 60 s and the monitor hasn't switched away.\nCheck that DDC/CI is on in the monitor's"
            + " OSD menu, then use the monitor's button to switch to Windows.",

        // ---- 菜单栏面板（ConnectionDiagram）
        "连接中": "Connecting",
        "未运行": "Not running",
        "异常": "Error",
    ]
}

/// 界面文案的统一入口（中文原文当 key）
func L(_ zh: String) -> String { Localization.text(zh) }

/// 带占位符的界面文案（见 Localization.text(_:_:)）
func L(_ zh: String, _ vars: [String: String]) -> String { Localization.text(zh, vars) }
