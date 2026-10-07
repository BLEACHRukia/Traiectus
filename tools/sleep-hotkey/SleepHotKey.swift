// SleepHotKey —— 用全局热键触发 macOS 睡眠
//
// 为什么不用「系统设置 → 键盘快捷键 → 服务」：
//   服务快捷键由 pbs 注册，但它排在当前 App 的菜单快捷键之后。
//   Finder 的 ⌘1 是「显示为图标」、浏览器 ⌘1 是「第一个标签页」，
//   前台 App 占了 ⌘1 时，事件根本轮不到服务，表现就是「按下没反应」。
//
//   本工具用 Carbon RegisterEventHotKey 注册系统级热键，
//   它在窗口服务器层就被吃下，优先于任何 App 的菜单快捷键。
//
// 默认组合：⌘1（--keycode 18 --modifiers 256）

import Cocoa
import Carbon.HIToolbox

// MARK: - 日志

let logPath = ("~/Library/Logs/sleep-hotkey.log" as NSString).expandingTildeInPath

func logLine(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
    FileHandle.standardError.write(data)
}

// MARK: - 执行子进程

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        logLine("启动 \(launchPath) 失败：\(error.localizedDescription)")
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - 睡眠

func sleepNow() {
    logLine("↑ 收到热键，请求睡眠")

    // 首选：让「系统事件」执行睡眠（普通用户权限即可，无需 root）
    var status = run("/usr/bin/osascript",
                     ["-e", "tell application \"System Events\" to sleep"])
    logLine("osascript(System Events sleep) 退出码 = \(status)")

    // 兜底：pmset（部分版本需要 root，失败就记日志）
    if status != 0 {
        status = run("/usr/bin/pmset", ["sleepnow"])
        logLine("pmset sleepnow 退出码 = \(status)")
    }
    if status != 0 {
        logLine("⚠️ 两种方式都没成功，请把本日志发给 Codex")
    }
}

// MARK: - 热键注册

func modifierMask(from name: String) -> UInt32 {
    var mask: UInt32 = 0
    let lower = name.lowercased()
    if lower.contains("cmd") || lower.contains("command") { mask |= UInt32(cmdKey) }
    if lower.contains("opt") || lower.contains("alt") { mask |= UInt32(optionKey) }
    if lower.contains("ctrl") || lower.contains("control") { mask |= UInt32(controlKey) }
    if lower.contains("shift") { mask |= UInt32(shiftKey) }
    return mask
}

/// 解析命令行参数：--keycode 18 --modifiers 256
func parseArguments() -> (keyCode: UInt32, modifiers: UInt32) {
    var keyCode = UInt32(kVK_ANSI_1)
    var modifiers = UInt32(cmdKey)
    let args = CommandLine.arguments

    var index = 1
    while index < args.count {
        switch args[index] {
        case "--keycode" where index + 1 < args.count:
            if let value = UInt32(args[index + 1]) { keyCode = value }
            index += 2
        case "--modifiers" where index + 1 < args.count:
            if let value = UInt32(args[index + 1]) { modifiers = value }
            index += 2
        case "--mods" where index + 1 < args.count:
            modifiers = modifierMask(from: args[index + 1])
            index += 2
        default:
            index += 1
        }
    }
    return (keyCode, modifiers)
}

let hotKeySignature: OSType = 0x534C_4B59  // 'SLKY'

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private let keyCode: UInt32
    private let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEventHandler()
        registerHotKey()
        probeAutomationPermission()
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            sleepNow()
            return noErr
        }, 1, &spec, nil, nil)
        logLine("安装热键事件处理器：OSStatus = \(status)")
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            logLine("✅ 已注册全局热键：keyCode=\(keyCode) modifiers=\(modifiers)（默认 ⌘1）")
        } else {
            logLine("❌ 热键注册失败：OSStatus = \(status)（可能被其它程序占用）")
        }
    }

    /// 启动时先做一次无害的 Apple Event，把「自动化」授权弹窗提前引出来，
    /// 免得用户第一次按热键时被弹窗挡住，以为没反应。
    private func probeAutomationPermission() {
        let status = run("/usr/bin/osascript",
                         ["-e", "tell application \"System Events\" to get name"])
        logLine("自动化权限预检：退出码 = \(status)（0 = 已授权）")
    }
}

// MARK: - 入口

let config = parseArguments()
logLine("启动 SleepHotKey，目标热键 keyCode=\(config.keyCode) modifiers=\(config.modifiers)")

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(keyCode: config.keyCode, modifiers: config.modifiers)
application.delegate = delegate
application.run()
