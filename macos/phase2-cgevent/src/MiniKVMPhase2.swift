// ============================================================================
//  MiniKVM — macOS 端（CGEvent 合成鼠标事件）
//  macOS 鼠标事件合成测试程序（Swift + SwiftUI + CGEvent）
// ----------------------------------------------------------------------------
//  目的：在 Mac 上验证"用 macOS 官方 API 合成鼠标事件"这条路走得通，
//        为 Phase 3（Windows 通过 TCP 发事件、Mac 落地执行）打地基。
//
//  本程序做的事情：
//    * 检查 / 申请「辅助功能(Accessibility)」权限并提供跳转按钮
//    * 用 CGEvent 合成：移动（画圈）、左键、右键、中键、滚轮上/下
//    * 每一步都写进日志，方便你对照观察
//
//  安全说明：
//    * 只用 Apple 官方 API：CGEvent（CoreGraphics）+ AXIsProcessTrusted
//    * 不使用任何已废弃 API，不使用内核扩展(kext)，不装任何东西
//    * 只申请「辅助功能」权限，不申请「完全磁盘访问」
//    * 只影响这台 Mac；对 Windows 侧没有任何影响
//    * 每项测试结束都会把光标复位到开始位置
//
//  注意：这份代码我无法在当前这台 Windows 机器上编译验证（没有 macOS 工具链），
//        所以如果 Xcode 报错，把错误发我，我改。
// ============================================================================

import SwiftUI
import AppKit
import ApplicationServices
import Darwin

private func logStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 测试引擎

final class MouseTestEngine: ObservableObject {
    @Published var lines: [String] = []
    @Published var trusted: Bool = AXIsProcessTrusted()

    /// 所有合成动作都在这条串行队列上执行，避免和 UI 抢线程。
    private let queue = DispatchQueue(label: "com.minikvm.mac.engine")

    init() {
        let ok = AXIsProcessTrusted()
        trusted = ok
        lines.append("[启动] 辅助功能权限：\(ok ? "已授权" : "未授权 —— 合成事件不会生效")")
    }

    // ---------------------------------------------------------------- 权限

    func refreshTrust() {
        let ok = AXIsProcessTrusted()
        trusted = ok
        append("权限检查：\(ok ? "已授权" : "未授权")")
    }

    /// 弹出系统授权提示（同时会把本 App 加进「辅助功能」列表）。
    func requestTrust() {
        // kAXTrustedCheckOptionPrompt is imported as Unmanaged<CFString>, so it
        // has to be unwrapped before it can be used as a dictionary key.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshTrust()
    }

    /// 直接打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    // ---------------------------------------------------------------- 基础设施

    private func append(_ s: String) {
        DispatchQueue.main.async {
            self.lines.append("[\(logStamp())] \(s)")
            if self.lines.count > 500 { self.lines.removeFirst(self.lines.count - 500) }
        }
    }

    /// 当前光标位置（CGEvent 全局坐标，左上角为原点）。
    private func cursorLocation() -> CGPoint {
        return CGEvent(source: nil)?.location ?? CGPoint.zero
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private func moveCursor(to p: CGPoint) {
        post(CGEvent(mouseEventSource: nil,
                     mouseType: .mouseMoved,
                     mouseCursorPosition: p,
                     mouseButton: .left))
    }

    /// 把坐标限制在主显示器范围内，避免跑出屏幕。
    private func clampToScreen(_ p: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        let x = min(max(p.x, b.minX + 1), b.maxX - 2)
        let y = min(max(p.y, b.minY + 1), b.maxY - 2)
        return CGPoint(x: x, y: y)
    }

    private func warnIfNotTrusted() {
        if !AXIsProcessTrusted() {
            append("⚠︎ 当前没有「辅助功能」权限，合成的事件不会生效。请点「请求权限」或「打开系统设置」。")
        }
    }

    // ---------------------------------------------------------------- 具体动作（同步，必须在 queue 上调用）

    private func doMoveTest() {
        warnIfNotTrusted()
        let home = cursorLocation()
        let radius: CGFloat = 180
        let steps = 120
        append("移动测试开始：圆心 (\(Int(home.x)),\(Int(home.y)))，半径 \(Int(radius))，\(steps) 步，每步 8ms")
        for i in 0...steps {
            let angle = 2.0 * Double.pi * Double(i) / Double(steps)
            let p = CGPoint(x: home.x + radius * CGFloat(cos(angle)),
                            y: home.y + radius * CGFloat(sin(angle)))
            moveCursor(to: clampToScreen(p))
            usleep(8000)
        }
        moveCursor(to: home)
        append("移动测试完成，光标已复位")
    }

    private func doClick(_ button: CGMouseButton, _ name: String) {
        warnIfNotTrusted()
        let p = cursorLocation()
        let down: CGEventType
        let up: CGEventType
        switch button {
        case .left:  down = .leftMouseDown;  up = .leftMouseUp
        case .right: down = .rightMouseDown; up = .rightMouseUp
        default:     down = .otherMouseDown; up = .otherMouseUp   // 中键
        }
        post(CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button))
        usleep(50000)
        post(CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button))
        append("\(name)点击完成 @ (\(Int(p.x)),\(Int(p.y)))")
    }

    private func doScroll(up: Bool, notches: Int32) {
        warnIfNotTrusted()
        let delta: Int32 = up ? 1 : -1
        for _ in 0..<notches {
            if let e = CGEvent(scrollWheelEvent2Source: nil,
                               units: .line,
                               wheelCount: 1,
                               wheel1: delta,
                               wheel2: 0,
                               wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }
            usleep(60000)
        }
        append("滚轮\(up ? "上" : "下")滚 \(notches) 格完成")
    }

    // ---------------------------------------------------------------- 对外按钮入口

    func runMoveTest()      { queue.async { self.doMoveTest() } }
    func runLeftClick()     { queue.async { self.doClick(.left, "左键") } }
    func runRightClick()    { queue.async { self.doClick(.right, "右键") } }
    // 中键和滚轮只有"延迟版"对外提供：即时版等于在窗口自己身上点，测不出任何东西。

    // ---------------------------------------------------------------- 延迟执行

    /// 中键和滚轮必须"光标停在目标上"才有意义（链接上按中键才会开新标签页、
    /// 能滚动的窗口里滚轮才看得出方向），而点这个窗口里的按钮本身就会把光标
    /// 挪到窗口上。所以这几个动作提供延迟版本：按下按钮后有 5 秒时间把光标
    /// 移到目标上并停住，时间到了就在光标当时所在的位置执行。
    ///
    /// 日志里会逐秒打印倒计时，并在真正执行前打印光标位置 —— 这样"计时器没跑"
    /// 和"跑了但事件没生效"这两种失败能一眼分开。
    private func doDelayed(_ name: String, _ body: @escaping () -> Void) {
        append("\(name)：5 秒后执行 —— 现在把光标移到目标上并停住（别再动鼠标）")
        queue.async {
            for remaining in stride(from: 4, through: 1, by: -1) {
                usleep(1_000_000)
                self.append("      … 还有 \(remaining) 秒")
            }
            usleep(1_000_000)
            let p = CGEvent(source: nil)?.location ?? CGPoint.zero
            self.append("      → 时间到，在光标位置 (\(Int(p.x)), \(Int(p.y))) 执行\(name)")
            if !AXIsProcessTrusted() {
                self.append("      ⚠︎ 未授权，合成的事件不会生效")
            }
            body()
        }
    }

    func runMiddleClickDelayed() { doDelayed("中键") { self.doClick(.center, "中键") } }
    func runScrollUpDelayed()    { doDelayed("滚轮上") { self.doScroll(up: true, notches: 3) } }
    func runScrollDownDelayed()  { doDelayed("滚轮下") { self.doScroll(up: false, notches: 3) } }

    func runFullTest() {
        queue.async {
            self.append("========== 全套测试开始 ==========")
            self.doMoveTest()
            usleep(300000)
            self.doClick(.left, "左键")
            usleep(300000)
            self.doClick(.right, "右键")
            usleep(300000)
            self.doClick(.center, "中键")
            usleep(300000)
            self.doScroll(up: true, notches: 3)
            usleep(200000)
            self.doScroll(up: false, notches: 3)
            self.append("========== 全套测试结束 ==========")
        }
    }

    func clearLog() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var engine = MouseTestEngine()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("MiniKVM — macOS 鼠标事件合成测试")
                .font(.headline)

            HStack(spacing: 10) {
                Circle()
                    .fill(engine.trusted ? Color.green : Color.red)
                    .frame(width: 11, height: 11)
                Text(engine.trusted ? "辅助功能权限：已授权" : "辅助功能权限：未授权")
                    .font(.system(size: 13))
                Spacer()
                Button("检查") { engine.refreshTrust() }
                Button("请求权限") { engine.requestTrust() }
                Button("打开系统设置") { engine.openAccessibilitySettings() }
            }

            Text("授权后需要重启本程序才会生效。若列表里没有它，点 + 手动添加 build/MiniKVM.app。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if !engine.trusted {
                Text("⚠︎ 现在没有辅助功能权限，下面所有测试按钮都是禁用状态（按了也不会有任何反应）。请点「请求权限」，在系统设置里打开开关，然后退出本 App 重新打开；重新编译过 App 之后也需要重新打开一次那个开关。")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button("移动测试（画圈）") { engine.runMoveTest() }
                Button("左键") { engine.runLeftClick() }
                Button("右键") { engine.runRightClick() }
            }
            .disabled(!engine.trusted)

            HStack(spacing: 8) {
                Text("下面三项需要先把光标放到目标上，所以延迟 5 秒执行：")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("中键") { engine.runMiddleClickDelayed() }
                Button("滚轮上") { engine.runScrollUpDelayed() }
                Button("滚轮下") { engine.runScrollDownDelayed() }
            }
            .disabled(!engine.trusted)

            HStack(spacing: 8) {
                Button("▶︎ 全套测试（约 6 秒）") { engine.runFullTest() }
                    .disabled(!engine.trusted)
                Button("清空日志") { engine.clearLog() }
                Spacer()
            }

            Divider()

            ScrollView {
                Text(engine.lines.isEmpty ? "（还没有日志，点上面任意按钮开始）"
                                          : engine.lines.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.gray.opacity(0.3))
        }
        .padding(14)
        .frame(minWidth: 660, minHeight: 460)
    }
}

@main
struct MiniKVMApp: App {
    var body: some Scene {
        WindowGroup("MiniKVM") {
            ContentView()
        }
    }
}
