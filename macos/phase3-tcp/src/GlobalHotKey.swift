// ============================================================================
//  GlobalHotKey —— 系统级热键的通用注册器
// ----------------------------------------------------------------------------
//  为什么要有这一层：Traiectus 现在有**两个**全局热键（睡眠、鼠标切换），
//  而 Carbon 的事件回调是 C 函数指针、只能挂在 app 的事件目标上。两个热键
//  必须共用一个处理器、按 `EventHotKeyID` 分发，否则会踩两个坑：
//    · 谁也不看 hotKeyID → 按下任意一个热键，另一个的动作也跟着跑
//    · Carbon 里处理器返回 `noErr` 会**截断后面的处理器**（eventNotHandledErr
//      才会继续往下传），所以"两个处理器各管各的"这种写法很脆
//
//  所以这里只做一件事：一个处理器 + 按 id 分发。注册/注销/键名都在这。
//
//  ⚠️ 注册必须在**主线程**做：事件目标是 `GetApplicationEventTarget()`，
//     它是在主的 run loop 上派发的。
//
//  注：热键只在 app 运行期间有效。Traiectus 是登录自动启动的菜单栏 app，
//      所以实际上等于常驻。
// ============================================================================

import Foundation
import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {

    /// 所有已注册热键的动作，键 = `EventHotKeyID.id`
    /// 只在主线程访问（注册在主线程、事件也在主线程派发），所以不上锁。
    private static var actions: [UInt32: () -> Void] = [:]
    private static var eventHandlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x5452_484B          // 'TRHK'

    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    var isRegistered: Bool { ref != nil }

    // ---------------------------------------------------------------- 注册 / 注销

    /// 注册一个系统级热键。返回 OSStatus，`noErr` 表示成功。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> OSStatus {
        unregister()

        let installed = Self.installHandlerIfNeeded()
        guard installed == noErr else { return installed }

        let newID = Self.claimID()
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers,
                                         EventHotKeyID(signature: Self.signature, id: newID),
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return status }

        Self.actions[newID] = action
        self.id = newID
        self.ref = hotKeyRef
        return noErr
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        if id != 0 {
            Self.actions[id] = nil
            id = 0
        }
        // 处理器不拆：它只是一个空转的分发器，留着比"反复装/拆"稳
    }

    // ---------------------------------------------------------------- 内部分发

    private static func claimID() -> UInt32 {
        nextID += 1
        return nextID
    }

    private static func installHandlerIfNeeded() -> OSStatus {
        if eventHandlerRef != nil { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr, let action = GlobalHotKey.actions[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)   // 不是我们的键：让别的处理器接着处理
            }
            action()
            return noErr
        }, 1, &spec, nil, &eventHandlerRef)
    }

    // ---------------------------------------------------------------- 显示

    /// NSEvent 的修饰键 → Carbon 修饰键位
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    /// 至少要有 ⌘ / ⌃ / ⌥ 之一。只用 ⇧ 或裸键会跟正常打字抢输入，不允许。
    static func isAcceptable(modifiers: UInt32) -> Bool {
        modifiers & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0
    }

    /// ⌃⌥⇧⌘ 的官方顺序 + 键名，例如 "⌘1"
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        // 键名是给界面看的（录制器里显示"⌃⌥空格"这种），所以跟着界面语言走；
        // 字母/数字/箭头/符号那些本来就不用翻译，L() 查不到会原样返回。
        keyNames[keyCode] ?? L("键码 {n}", ["n": "\(keyCode)"])
    }

    /// ANSI 虚拟键码表（录制器拿到的是同一个编码）。
    /// 注意是 `var`（计算属性）而不是 `let`：`let` 只在第一次访问时求值、之后一直缓存，
    /// 那样运行中切语言，「空格 / 帮助」这些词会停在旧语言直到重启。
    private static var keyNames: [UInt32: String] { [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
        25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: L("空格"), 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: L("帮助"), 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ] }

    // ---------------------------------------------------------------- 产品默认值

    /// 鼠标切换的出厂默认：**⌃⌥M** —— 和 Windows 侧那个 Ctrl+Alt+M 是同一个组合键。
    /// 两边用同一个键是刻意的：键盘在哪台机器上，这个键就在哪台机器上生效，
    /// 用户只需要记一个。Mac 上已实测该组合没被系统或其它程序占用。
    static let defaultMouseKeyCode: UInt32 = 46                          // M
    static let defaultMouseModifiers: UInt32 = UInt32(controlKey | optionKey)
}
