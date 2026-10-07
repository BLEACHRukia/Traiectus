// ============================================================================
//  SleepHotKey —— 睡眠快捷键（做进 Traiectus 的设置里）
// ----------------------------------------------------------------------------
//  为什么不用「系统设置 → 键盘 → 键盘快捷键 → 服务」：
//    服务快捷键由 pbs 注册，它排在当前 App 的菜单快捷键**之后**。
//    Finder 的 ⌘1 是「显示为图标」、浏览器 ⌘1 是「第一个标签页」——
//    前台 App 先把键吃掉，事件根本轮不到服务，表现就是"按下没反应"。
//
//  这里用 Carbon `RegisterEventHotKey` 注册**系统级热键**：在窗口服务器层就被
//  接走，优先于任何 App 的菜单快捷键，所以不管在哪个界面按下都生效。
//
//  睡眠动作：先让「系统事件」执行睡眠（普通用户权限即可，无需 root），
//  失败再兜底 `pmset sleepnow`。首次触发时 macOS 会问一次"想控制「系统事件」"，
//  允许之后就记住了；被拒绝会在设置里显示「需要授权」。
//
//  注册本身走 GlobalHotKey（和「鼠标切换」热键共用一套分发器，见那个文件）。
//  这个类只管"按下之后做什么"。
// ============================================================================

import Foundation
import AppKit
import Carbon.HIToolbox

final class SleepHotKey {

    /// 出厂默认：⌘1（K70 上的 ⊞Win+1）
    static let defaultKeyCode: UInt32 = 18
    static let defaultModifiers: UInt32 = UInt32(cmdKey)

    /// 日志出口（由 TraiectusClient 注入，写进 Traiectus.log）
    var log: ((String) -> Void)?

    private let hotKey = GlobalHotKey()
    /// 睡眠是阻塞调用（还要等系统弹授权框），放后台队列，别卡住界面
    private let workQueue = DispatchQueue(label: "com.traiectus.client.sleephotkey")

    var isRegistered: Bool { hotKey.isRegistered }

    // ---------------------------------------------------------------- 注册 / 注销

    /// 注册全局热键。返回 OSStatus，`noErr` 表示成功；被别的程序占用会返回非 0。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        return hotKey.register(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            self?.performSleep()
        }
    }

    func unregister() {
        hotKey.unregister()
    }

    // ---------------------------------------------------------------- 动作

    func performSleep() {
        log?("睡眠快捷键触发 → 请求睡眠")
        workQueue.async { [weak self] in
            guard let self else { return }
            let viaSystemEvents = Self.run("/usr/bin/osascript",
                                           ["-e", "tell application \"System Events\" to sleep"])
            if viaSystemEvents == 0 { return }

            self.log?("「系统事件」方式失败（退出码 \(viaSystemEvents)），改用 pmset 兜底")
            let viaPmset = Self.run("/usr/bin/pmset", ["sleepnow"])
            if viaPmset != 0 {
                self.log?("⚠️ 睡眠请求两种方式都失败：osascript=\(viaSystemEvents) pmset=\(viaPmset)")
            }
        }
    }

    /// 预检「自动化」权限：提前把系统授权框引出来，并把结果回报给界面。
    /// 注意 osascript 在授权框未处理前会一直阻塞，所以必须走后台队列。
    func probeAutomation(completion: @escaping (Bool) -> Void) {
        workQueue.async {
            let status = Self.run("/usr/bin/osascript",
                                  ["-e", "tell application \"System Events\" to get name"])
            DispatchQueue.main.async { completion(status == 0) }
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // ---------------------------------------------------------------- 显示
    // 键名/修饰键这些共用的东西都在 GlobalHotKey 里，这里只是转发 ——
    // 保留这层是为了不动 ShortcutRecorder 和 TraiectusClient 里的调用点。

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        GlobalHotKey.carbonModifiers(from: flags)
    }

    static func isAcceptable(modifiers: UInt32) -> Bool {
        GlobalHotKey.isAcceptable(modifiers: modifiers)
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        GlobalHotKey.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        GlobalHotKey.keyName(keyCode)
    }
}
