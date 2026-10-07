// ============================================================================
//  ShortcutRecorder —— 设置里那个"点一下就开始录制"的快捷键输入框
// ----------------------------------------------------------------------------
//  第一版是自绘 NSView（在 draw(_:) 里画圆角框 + 文字），实测**框在、字不显示**，
//  于是改成纯 SwiftUI 画：背景、边框、文字全交给 SwiftUI，不可能再出现空框。
//
//  录制用 app 级键盘监视器（NSEvent.addLocalMonitorForEvents(.keyDown)）：
//    · 比"抢第一响应者"靠谱 —— 设置窗口里不需要有控件拿焦点
//    · 回调返回 nil 会吞掉这次按键，所以 ⌘E 这类既有菜单快捷键不会被真的执行，
//      只被录进来（第一版就是没吞，才让 ⌘E 真的变成了全局热键）
//    · Esc 取消，保留原来的组合；必须含 ⌘/⌃/⌥ 之一，否则会跟正常打字抢输入
// ============================================================================

import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    let keyCode: UInt32
    let modifiers: UInt32
    let isEnabled: Bool
    let onChange: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var hint: String?
    @State private var monitor: Any?

    private var labelText: String {
        if let hint { return hint }
        if isRecording { return L("按下组合键…") }
        return SleepHotKey.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        // 提示挂在**外层**，不挂在按钮自己身上：
        //   热键关着的时候这个按钮是 disabled，而 macOS 上被禁用的视图收不到悬停 ——
        //   挂在它自己身上的 tooltip 就不会弹（这就是"鼠标放上去有时候没提示"）。
        //   外层不禁用，套一层 + contentShape 就能整块响应悬停。
        recorder
            .contentShape(Rectangle())
            .help(L("点一下，然后按下想要的组合键（Esc 取消）"))
    }

    private var recorder: some View {
        Button {
            guard isEnabled else { return }
            start()
        } label: {
            Text(labelText)
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 150, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.14)
                              : Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onDisappear { stop() }
    }

    private var foregroundColor: Color {
        if !isEnabled { return Color.secondary.opacity(0.5) }
        return isRecording ? Color.secondary : Color.primary
    }

    // ---------------------------------------------------------------- 录制

    private func start() {
        stop()
        isRecording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // 交给下一个 runloop 处理：监视器自己的回调里不能把这个监视器拆掉
            DispatchQueue.main.async { handle(event) }
            return nil                 // 吞掉这次按键，别让它触发菜单快捷键
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hint = nil
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else { return }

        if event.keyCode == 53 {       // Esc
            stop()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = SleepHotKey.carbonModifiers(from: flags)
        guard SleepHotKey.isAcceptable(modifiers: carbon) else {
            hint = L("需要 ⌘ / ⌃ / ⌥")
            NSSound.beep()
            return
        }

        let code = UInt32(event.keyCode)
        stop()
        onChange(code, carbon)
    }
}
