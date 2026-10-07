// ============================================================================
//  Traiectus Client（Phase 3）
//  连接 Windows 端的 Traiectus Server，把转发过来的鼠标事件用 CGEvent 注入本机
// ----------------------------------------------------------------------------
//  协议以仓库根目录的 PROTOCOL.md 为准（HELLO / MOVE / DOWN / UP / WHEEL / PING）。
//
//  本程序负责：
//    * 作为 TCP 客户端主动连接 Windows（Windows 是监听端）
//    * 握手（协议版本 + 口令）、心跳（1 秒 PING）、3 秒超时判死
//    * 断线后 0.25s → 0.5s → 1s 指数退避重连
//    * 正确处理粘包 / 分包（按 \n 切分，残包留在缓冲区）
//    * 断开时把仍按下的键补发"抬起"，避免 Mac 上左键卡住
//
//  安全：只注入鼠标事件；不 hook、不拦截、不修改任何系统设置；
//        退出或崩溃时本机鼠标不受影响。
// ============================================================================

import SwiftUI
import AppKit
import ApplicationServices
import Network

// ============================================================================
//  LinkAvailability —— "Windows 端是否在线"的单一真相
// ----------------------------------------------------------------------------
//  判定：TCP 已 ready **且** 3 秒内收到过 PONG（只看 ready 不够：对端进程卡死时
//  TCP 可能还在，只有心跳停了才算真离线）。
//  由客户端持有，KeyboardLink 通过闭包查询；离线时联动只挡输出动作。
// ============================================================================
final class LinkAvailability {
    private let lock = NSLock()
    private var _online = false

    /// 状态翻转时回调（在客户端 queue 上调用）
    var onChange: ((Bool) -> Void)?

    var online: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _online }
        set {
            lock.lock()
            let changed = (_online != newValue)
            _online = newValue
            lock.unlock()
            if changed { onChange?(newValue) }
        }
    }
}

// MARK: - 协议常量（与 PROTOCOL.md 对应）

enum KVMProtocol {
    static let version = 1
    static let maxLineBytes = 256
    static let maxBufferedBytes = 1024
    static let handshakeTimeout: TimeInterval = 3
    /// 配对超时：发出 PAIR? 后等用户在 Windows 上点确认的**安全网**。
    ///
    /// ⚠️ 必须明显大于服务端确认框的等待时间（`--pair-timeout`，默认 60 秒）。
    /// 客户端先超时的后果很严重：Mac 断开，但 Windows 那边已经生成口令并写进了
    /// paired.json，`PAIR-OK` 发给一条没人管的连接 → 下次 Mac 没口令 → 发 PAIR?
    /// → 服务端回 `already-paired` → 用户掉进"必须去 Windows 托盘重新配对"的死胡同。
    /// （2026-10-01：服务端把窗口从 30 秒改成 60 秒，这里是跟着调的。）
    ///
    /// 所以这只是一个"服务端没应答"的兜底，正常情况永远由服务端先回。
    /// 服务端若把 `--pair-timeout` 调到 120 秒以上，这个值要跟着调大。
    static let pairingTimeout: TimeInterval = 120
    static let heartbeatInterval: TimeInterval = 1
    static let peerTimeout: TimeInterval = 3
    static let maxReconnectDelay: TimeInterval = 1
    static let defaultPort: UInt16 = 45789
}

/// 首次连接时的配对状态（PROTOCOL.md §2.1）。
/// 本地没有口令时，客户端不发 HELLO，而是发 `PAIR?`，等用户在 Windows 上点「允许」。
enum PairingState: Equatable {
    case idle                  // 没在配对（已配对过，或还没走到这一步）
    case requesting            // 已发出 PAIR?，等 Windows 上点确认
    case denied(String)        // 被拒 / 超时 / 服务端已配对 —— 带上原因给界面看
}

// MARK: - 行分帧器（解决粘包 / 分包）

final class LineFramer {
    private var buffer = Data()
    private let maxLineBytes: Int
    private let maxBufferedBytes: Int

    var onLine: ((String) -> Void)?
    var onFault: ((String) -> Void)?

    init(maxLineBytes: Int, maxBufferedBytes: Int) {
        self.maxLineBytes = maxLineBytes
        self.maxBufferedBytes = maxBufferedBytes
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// 追加收到的字节，并把其中所有完整的行回调出去。
    /// 一次 recv 可能带来半行、一行或多行，这里统一处理。
    func append(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)

            if lineBytes.count > maxLineBytes {
                onFault?("收到 \(lineBytes.count) 字节的行，超过上限 \(maxLineBytes)")
                return
            }

            var text = String(decoding: lineBytes, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            onLine?(text)
        }

        if buffer.count > maxBufferedBytes {
            onFault?("连续 \(buffer.count) 字节没有出现换行")
        }
    }
}

// MARK: - 事件注入

final class EventInjector {
    /// 协议约定：一格滚轮 = 120
    private static let wheelUnitsPerDetent = 120
    /// 一格滚轮在 Mac 上滚几行。想滚得更快就调大这个值。
    /// 实测（2026-09-24）：1 行时浏览器里 `deltaY` 只有 40 px，偏慢；调到 3 后是 ~120 px，
    /// 与真实鼠标一格的手感接近。觉得还是太快/太慢就改成 2 或 4。
    private static let linesPerDetent: Int32 = 3

    /// 用「HID 系统来源」创建事件，让它们与真实鼠标产生的事件在系统看来没有区别。
    /// 为什么重要：某些 App（尤其带自动化能力的应用）会读取事件的来源 ID
    /// （`kCGEventSourceStateID`）来判断"这是不是合成事件"，来源不是 HID 时可能直接忽略点击。
    /// 之前事件是用 `nil` 来源创建的，属于"私有来源"，保真度不够。
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private var heldButtons: Set<String> = []
    private var wheelRemainderV = 0
    private var wheelRemainderH = 0

    private var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint.zero
    }

    private func clampToMainDisplay(_ p: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: min(max(p.x, b.minX + 1), b.maxX - 2),
                       y: min(max(p.y, b.minY + 1), b.maxY - 2))
    }

    private func mouseButton(for name: String) -> CGMouseButton? {
        switch name.uppercased() {
        case "L":  return .left
        case "R":  return .right
        case "M":  return .center
        case "X1": return CGMouseButton(rawValue: 3)   // 侧键 1 = "back"
        case "X2": return CGMouseButton(rawValue: 4)   // 侧键 2 = "forward"
        default:   return nil
        }
    }

    /// 相对位移：读当前坐标 → 加上增量 → 注入绝对坐标。
    /// macOS 对"投递进来的绝对坐标"不做指针加速，所以这里就是 1:1 的线性手感。
    ///
    /// ⚠️ 关键：按住键移动时必须发对应的 **Dragged** 事件类型。
    /// 一直发 `.mouseMoved` 的话，系统只当"光标在移动"，不认为是拖拽 ——
    /// 表现就是：拖不动文件、拖不动选中的文字（Finder 和文本编辑都会拒绝）。
    func move(dx: Int, dy: Int) {
        let now = cursorLocation
        let target = clampToMainDisplay(CGPoint(x: now.x + CGFloat(dx),
                                                y: now.y + CGFloat(dy)))

        let type: CGEventType
        let button: CGMouseButton
        if heldButtons.contains("L") {
            type = .leftMouseDragged
            button = .left
        } else if heldButtons.contains("R") {
            type = .rightMouseDragged
            button = .right
        } else if let other = heldButtons.first {
            type = .otherMouseDragged
            button = mouseButton(for: other) ?? .center
        } else {
            type = .mouseMoved
            button = .left
        }

        CGEvent(mouseEventSource: eventSource,
                mouseType: type,
                mouseCursorPosition: target,
                mouseButton: button)?.post(tap: .cghidEventTap)
    }

    @discardableResult
    func button(name: String, down: Bool) -> Bool {
        guard let b = mouseButton(for: name) else { return false }
        let key = name.uppercased()

        let type: CGEventType
        switch b {
        case .left:  type = down ? .leftMouseDown  : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default:     type = down ? .otherMouseDown : .otherMouseUp   // 中键与侧键
        }

        if down { heldButtons.insert(key) } else { heldButtons.remove(key) }

        CGEvent(mouseEventSource: eventSource,
                mouseType: type,
                mouseCursorPosition: cursorLocation,
                mouseButton: b)?.post(tap: .cghidEventTap)
        return true
    }

    /// 滚轮：把零头累积起来，够一格才注入，避免高分辨率滚轮的小增量被丢掉。
    func wheel(delta: Int, horizontal: Bool) {
        var detents = 0
        if horizontal {
            wheelRemainderH += delta
            detents = wheelRemainderH / Self.wheelUnitsPerDetent
            wheelRemainderH -= detents * Self.wheelUnitsPerDetent
        } else {
            wheelRemainderV += delta
            detents = wheelRemainderV / Self.wheelUnitsPerDetent
            wheelRemainderV -= detents * Self.wheelUnitsPerDetent
        }
        guard detents != 0 else { return }

        let lines = Int32(detents) * Self.linesPerDetent
        CGEvent(scrollWheelEvent2Source: eventSource,
                units: .line,
                wheelCount: 1,
                wheel1: horizontal ? 0 : lines,      // wheel1 = 垂直
                wheel2: horizontal ? lines : 0,      // wheel2 = 水平
                wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// 断开连接时必须调用：把还按着的键补一次"抬起"，
    /// 否则会出现"Mac 上左键卡住、所有点击都变成拖拽"这种故障。
    @discardableResult
    func releaseAllHeldButtons() -> [String] {
        let names = Array(heldButtons)
        for name in names { button(name: name, down: false) }
        return names
    }
}

// MARK: - 客户端主体

/// 对外的门面类：UI 与 Xcode 预览都用它
/// （public 是为了让 SwiftPM 的可执行目标 Traiectus 能用；单模块编译时无影响）
public final class TraiectusClient: ObservableObject {

    /// 偏好设置入口（带一次性的改名迁移）。
    /// 改名迁移：旧键 `minikvm.*` → 新键 `traiectus.*`。第一次被访问时执行一次，
    /// 把用户原来填的地址/端口/口令/开关原样搬过来，避免改名后配置"丢失"。
    /// 用 `static let` 是刻意的：上面的 @Published 属性初始化早于 init() 正文，
    /// 迁移必须在那之前完成。
    private static let defaults: UserDefaults = {
        let d = UserDefaults.standard
        let pairs = [("minikvm.host", "traiectus.host"),
                     ("minikvm.port", "traiectus.port"),
                     ("minikvm.token", "traiectus.token"),
                     ("minikvm.autostart", "traiectus.autostart"),
                     ("minikvm.link", "traiectus.link")]
        // 两组来源都看：
        //   ① 同一域里的旧键名（minikvm.* → traiectus.*）
        //   ② **旧 bundle id 的域**（改名前的 app 把设置写在 com.minikvm.client，
        //      换 bundle id 后新域是空的，必须从那边搬）
        let legacy = UserDefaults(suiteName: "com.minikvm.client")
        var moved = 0
        for (old, new) in pairs where d.object(forKey: new) == nil {
            if let v = (d.object(forKey: old) ?? legacy?.object(forKey: old)) {
                d.set(v, forKey: new)
                moved += 1
            }
        }
        if moved > 0 { NSLog("[Traiectus] 已迁移 %d 项旧设置（minikvm.* → traiectus.*）", moved) }
        // 界面语言的老取值（"system"）归一化 —— 和上面的键名迁移一样，第一次访问时做一次
        Localization.normalizeStoredValue()
        return d
    }()

    // ---- 界面状态
    @Published var logLines: [String] = []
    @Published var statusText = "未连接"
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var trusted: Bool = AXIsProcessTrusted()
    @Published var eventRate: Double = 0
    @Published var lastLatencyMs: Double = -1
    @Published var injectedEvents: Int = 0
    /// 配对进度（首次连接时在 Windows 上点「允许」）。见 PROTOCOL.md §2.1
    @Published var pairingState: PairingState = .idle
    /// 正在自动查找 Windows（广播问 + 扫网段，见 PeerDiscovery.swift）
    @Published var discovering = false

    // ---- 连接参数（记住上次填的）
    @Published var host: String = TraiectusClient.defaults.string(forKey: "traiectus.host") ?? ""
    @Published var portText: String = TraiectusClient.defaults.string(forKey: "traiectus.port")
        ?? String(KVMProtocol.defaultPort)
    @Published var token: String = TraiectusClient.defaults.string(forKey: "traiectus.token") ?? ""
    /// 启动时自动连接（双击桌面图标就能直接连上，不用再点「连接」）
    @Published var autostart: Bool = TraiectusClient.defaults.bool(forKey: "traiectus.autostart")
    /// 「登录时启动」—— 状态存在系统里（SMAppService），这里只是给界面看的副本
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    /// 改这个开关失败时的原因（正常是 nil）
    @Published var launchAtLoginError: String?
    /// 键盘联动：按 Fn+Caps / Fn+T 时，屏幕与鼠标跟着键盘一起切
    @Published var linkEnabled: Bool = TraiectusClient.defaults.bool(forKey: "traiectus.link")
    /// 睡眠快捷键：按一下让这台 Mac 立即睡眠（系统级热键，优先于前台 App）
    @Published var sleepHotKeyEnabled: Bool =
        TraiectusClient.defaults.bool(forKey: "traiectus.sleephotkey.enabled")
    @Published var sleepHotKeyCode: UInt32 =
        UInt32((TraiectusClient.defaults.object(forKey: "traiectus.sleephotkey.keycode") as? Int)
               ?? Int(SleepHotKey.defaultKeyCode))
    @Published var sleepHotKeyModifiers: UInt32 =
        UInt32((TraiectusClient.defaults.object(forKey: "traiectus.sleephotkey.modifiers") as? Int)
               ?? Int(SleepHotKey.defaultModifiers))
    /// 热键被别的程序占用（注册失败）
    @Published var sleepHotKeyConflict = false
    /// 缺「自动化」授权 —— 按下热键也睡不了
    @Published var sleepHotKeyNeedsAutomation = false
    /// 鼠标切换快捷键：按一下把鼠标控制权在 Mac / Win 之间切（系统级热键）
    /// 等价于在 Windows 上按 Ctrl+Alt+M —— 走的是协议 §3.3 那条 MODE 请求
    @Published var mouseHotKeyEnabled: Bool =
        TraiectusClient.defaults.object(forKey: "traiectus.mousehotkey.enabled") as? Bool ?? true
    @Published var mouseHotKeyCode: UInt32 =
        UInt32((TraiectusClient.defaults.object(forKey: "traiectus.mousehotkey.keycode") as? Int)
               ?? Int(GlobalHotKey.defaultMouseKeyCode))
    @Published var mouseHotKeyModifiers: UInt32 =
        UInt32((TraiectusClient.defaults.object(forKey: "traiectus.mousehotkey.modifiers") as? Int)
               ?? Int(GlobalHotKey.defaultMouseModifiers))
    /// 热键被别的程序占用（注册失败）
    @Published var mouseHotKeyConflict = false
    /// 当前挂在 Mac 上的键盘（按 VID 去重）—— 用来让用户"点一下选键盘"而不是查厂商 ID
    @Published var keyboardCandidates: [KeyboardCandidate] = []
    /// 键盘体检（"这把键盘支不支持抢跑"）
    @Published var keyboardProbeRunning = false
    /// 键盘学习向导
    enum LearnStep { case idle, captureA, captureB, verify }
    @Published var learnStep: LearnStep = .idle
    @Published var learnMessage = ""
    @Published var learnRulesText = ""
    /// 运行期自检（判定 vs 实际归属）
    @Published var keyboardLastMatchedAt: Date?
    @Published var keyboardMatchedFrameCount = 0
    @Published var keyboardMismatchCount = 0
    private var learnFramesA: [String] = []
    private var learnFramesB: [String] = []
    private var learnRules: [KeyboardFrameRule] = []
    /// Windows 端是否在线（供 UI 显示；内部判定见 LinkAvailability）
    @Published var winOnline: Bool = false
    /// 鼠标控制权当前是否在 Mac（由服务端 MODE 行更新，供面板显示 ●Mac / ●Win）
    @Published var mouseOnMac: Bool = false
    /// 握手被拒绝（口令/版本不对）→ 面板显示"异常"
    @Published var authFailed: Bool = false
    /// 刚点了"重连" → 设置里短暂显示"重连中…"（给用户可见反馈）
    @Published var manualReconnectUntil: Date?

    // ---- 内部
    private let queue = DispatchQueue(label: "com.traiectus.client.net")
    private let injector = EventInjector()
    private let keyboardLink = KeyboardLink()
    private let sleepHotKey = SleepHotKey()
    private let mouseHotKey = GlobalHotKey()
    let availability = LinkAvailability()
    private var lastPongAt = Date.distantPast
    private var onlineTimer: DispatchSourceTimer?
    private var offlineSince: Date?
    private var offlineLoggedAt = Date.distantPast
    // 网络路径监听：代理/VPN 起停或换节点会改路由表与 utun 接口，
    // 已建立的连接会被打断，NWConnection 还可能卡在旧的失败路径上 —— 见 handlePathChange()
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceNames: Set<String> = []
    /// SIGTERM / SIGINT 的处理源（保住引用，否则 source 会被释放掉）
    private var signalSources: [DispatchSourceSignal] = []
    private var lastPathReconnectAt = Date.distantPast
    private let framer = LineFramer(maxLineBytes: KVMProtocol.maxLineBytes,
                                    maxBufferedBytes: KVMProtocol.maxBufferedBytes)

    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var wantConnected = false
    private var handshaken = false
    private var reconnectAttempt = 0
    /// 对端超时次数（用于识别"握手成功后又反复失联"＝可能有第二个实例在互相踢）
    private var peerTimeouts = 0
    /// 握手完成前就被对端关掉的次数。连着几次就说明"连上了但没人应答"，
    /// 最常见的原因是代理把到内网的连接吞了（见 receive 里的长注释）。
    private var handshakeEofs = 0
    /// 刚发出去的 MODE 请求（用来确认服务端是否真的响应了）
    private var pendingModeRequest: (mode: String, at: Date)?
    private var lastReceive = Date.distantPast
    private var readyAt: Date?
    private var currentHost = ""
    private var currentPort: UInt16 = KVMProtocol.defaultPort
    /// 最近一次真正用于握手的口令。用来判断"参数是不是真变了" —— 只改了口令
    /// 也得重连，光比地址/端口会漏掉这种情况。
    private var currentToken = ""
    /// 发出 PAIR? 的时刻。配对要等用户在 Windows 上点确认，比普通握手超时宽松得多。
    private var pairingSentAt: Date?
    private var nextPingId: UInt64 = 1
    private var pingSentAt: [UInt64: Date] = [:]
    private var eventCount = 0
    private var countedAt = Date()
    private var protocolErrorCount = 0
    private var injectedTotal = 0
    private var autostartDone = false
    private var connectFailures = 0
    // 服务端当前的控制权模式（PROTOCOL.md v1.1；老服务端不发 MODE 时按 Mac 处理）
    private var serverMode = "Mac"
    // 打点用：用来和服务端的往返数据做交叉验证
    private var rxLinesInWindow = 0
    private var injectedInWindow = 0
    private var statsWindowAt = Date()
    private var lastRxCallbackAt = Date()
    private var maxRxGapMs = 0.0
    private var maxHandleMs = 0.0

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 日志文件：~/Library/Logs/Traiectus.log
    /// 为什么要写文件：从终端直接跑这个二进制时，macOS 可能把权限主体判给"启动它的进程"，
    /// 于是程序自己看到的状态和正常双击打开时不一样。写到文件里，两种方式都能核对。
    private static let logFilePath: String = {
        let dir = ("~/Library/Logs" as NSString).expandingTildeInPath
        return (dir as NSString).appendingPathComponent("Traiectus.log")
    }()
    private let logFileQueue = DispatchQueue(label: "com.traiectus.client.logfile")

    /// 是不是跑在 Xcode 的 SwiftUI 预览里。
    ///
    /// 两道判断，任何一道命中就不连网：
    ///   ① 预览会给进程设 `XCODE_RUNNING_FOR_PREVIEWS=1`
    ///   ② 兜底：正式 app 的 bundle id 固定是 `com.traiectus.client`，
    ///      预览宿主（PreviewShell / Xcode 相关进程）一定不是它。
    ///      直接跑裸二进制时 bundle id 为空 —— 那是本机调试，放行。
    static var isRunningInPreview: Bool {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        return id != "com.traiectus.client"
    }

    /// 配对时告诉 Windows「我是谁」，会显示在确认框里给用户核对。
    /// 空格换成连字符，免得在 Windows 的对话框里被拆得别扭。
    static var deviceName: String {
        let raw = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let cleaned = raw.replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "Mac" : cleaned
    }

    public init() {
        // 日志超过 1 MB 就重开一个，避免无限增长
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.logFilePath),
           let size = attrs[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? FileManager.default.removeItem(atPath: Self.logFilePath)
        }
        framer.onLine = { [weak self] line in self?.handle(line: line) }
        framer.onFault = { [weak self] reason in
            guard let self else { return }
            self.log("协议错误：\(reason)，断开连接")
            self.dropConnection()
            self.scheduleReconnect()
        }
        // ---- 键盘联动（屏幕 + 鼠标模式）
        keyboardLink.log = { [weak self] text in self?.log(text) }
        // 从 Windows 的心跳里学地址：它每 2 秒发一次 HB，来源地址就是它自己。
        // 只在"没填过地址"或"现在连不上"时采用 —— 不跟一条正常工作的连接抢。
        keyboardLink.onPeerSeen = { [weak self] ip in
            guard let self else { return }
            DispatchQueue.main.async {
                let current = self.host.trimmingCharacters(in: .whitespaces)
                guard current.isEmpty || !self.isConnected else { return }
                guard current != ip else { return }
                self.log("[自动] 从 Windows 的心跳学到地址：\(ip)"
                         + (current.isEmpty ? "" : "（原来填的是 \(current)）"))
                self.adoptDetectedPeer(ip, port: nil)
            }
        }
        // 运行期自检：命中规则的帧 → 更新"检测方式"；判定与实际不一致 → 落盘诊断报告
        keyboardLink.onMatchedFrame = { [weak self] at in
            DispatchQueue.main.async {
                self?.keyboardLastMatchedAt = at
                self?.keyboardMatchedFrameCount += 1
            }
        }
        keyboardLink.onMismatch = { [weak self] report in
            self?.handleKeyboardMismatch(report)
        }
        // 联动的输出动作只在"Windows 端在线"时执行（离线时仍更新本地键盘归属）
        keyboardLink.isOnline = { [weak self] in self?.availability.online ?? true }
        keyboardLink.onMouseSide = { [weak self] side, why in
            guard let self else { return }
            self.queue.async {
                // 协议 §3.3：客户端可以直接请求切换控制权（等价于在 Windows 上按 Ctrl+Alt+M）
                self.sendLine("MODE \(side.rawValue)")
                self.log("[联动] 已请求鼠标控制权 → \(side.rawValue)（\(why)）")
                self.pendingModeRequest = (side.rawValue, Date())
            }
        }
        // Windows 端在线状态翻转：离线时复位联动状态，恢复时做一次同步
        availability.onChange = { [weak self] online in
            guard let self else { return }
            DispatchQueue.main.async { self.winOnline = online }
            if online {
                self.log("[TCP] Windows 端已恢复在线")
                self.keyboardLink.syncAfterRecovery()
            } else {
                self.log("[TCP] Windows 端离线（TCP 断线或心跳超时）")
                self.keyboardLink.resetOnOffline()
            }
        }
        startOnlineWatchdog()
        startPathMonitor()
        // ⚠️ 预览环境绝不能启动联动：KeyboardLink 会 bind UDP 45790（抢跑端口），
        // 而预览进程和正式 app 是同一个用户、同一个端口 —— 谁先起来谁占住，
        // 正式 app 就只能报"UDP 45790 绑定失败、抢跑不可用"。
        // （2026-10-01 实测：开着 Xcode 预览时，正式 app 的抢跑一直起不来，
        //   `lsof -iUDP:45790` 指向 XCPreview。）
        if linkEnabled, !Self.isRunningInPreview {
            keyboardLink.start()
        } else if linkEnabled {
            log("检测到 Xcode 预览环境 —— 不启动键盘联动（避免占用抢跑端口 45790）")
        }

        // ---- 键盘识别：把"联动要盯哪把键盘"对齐到真正插着的那把
        // （换键盘的人原来会看到"联动一声不响地完全不动"，见 autoHealKeyboardVendorID）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.autoHealKeyboardVendorID()
        }

        // ---- 系统睡眠 / 唤醒：显式交接鼠标控制权
        // 不靠"键盘离开 Mac"那条链：Mac 睡下去会把键盘的蓝牙链路断掉，联动会把这件
        // 事误判成"键盘走了"，于是交接要等到入睡约 1.4 秒之后才发生（Windows 那边的
        // 鼠标就卡着；如果联动没开，则要等 4~5 秒等服务端自己发现客户端掉线）。
        // 监听系统事件后，按 ⌘1 的同一刻就告诉 Windows 接管。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            guard let self, self.linkEnabled else { return }
            self.keyboardLink.handleWillSleep()
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                    object: nil, queue: .main) { [weak self] _ in
            guard let self, self.linkEnabled else { return }
            // 蓝牙设备要一点时间才会重新出现，等归属能判准了再决定
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.linkEnabled else { return }
                self.keyboardLink.handleDidWake()
            }
        }

        // ---- 睡眠快捷键（热键注册必须在主线程，挂到 NSApplication 的事件目标上）
        sleepHotKey.log = { [weak self] text in self?.log(text) }
        if sleepHotKeyEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applySleepHotKey(reason: "启动时恢复")
            }
        }
        // ---- 鼠标切换快捷键（和睡眠热键共用 GlobalHotKey 那一套分发器）
        if mouseHotKeyEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyMouseHotKey(reason: "启动时恢复")
            }
        }
        // 菜单栏 app 没有窗口，旧的 ContentView.onAppear 不会再触发 ——
        // 所以"启动时自动连接"必须在这里自己发起（否则 app 永远不会去连）
        DispatchQueue.main.async { [weak self] in self?.autostartIfRequested() }
        // 正常退出（托盘「退出」、⌘Q）走这条通知；被信号直接杀掉走下面那套
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.shutdownCleanly()
        }
        installSignalHandlers()
        log("[启动] 辅助功能权限：\(trusted ? "已授权" : "未授权 —— 转发过来的事件不会生效")")
        // 登录时启动：第一次启动注册一次（默认开），之后完全听用户的
        if !Self.isRunningInPreview {
            log("[启动] 登录时启动：\(LoginItem.registerOnFirstRun())")
        }
        log(TraiectusConfig.shared.summary)
    }

    // ---------------------------------------------------------------- 退出清理

    /// 退出前把外部资源收干净。**两条退出路径共用**：
    ///   · 正常退出 → `NSApplication.willTerminateNotification`
    ///   · 被信号杀掉 → `installSignalHandlers()`（`launchctl bootout`、脚本重启、pkill）
    ///
    /// 为什么信号那条也要管：`kill` 不会触发 willTerminate，漏掉它就会留下
    /// **孤儿 kvm-keywatch** —— 它继续持有 IOHIDManager，会污染"不碰 HID"那条
    /// 兼容性二分测试（2026-10-03 实测：pkill 重启后日志里出现两个 keywatch）。
    func shutdownCleanly() {
        queue.sync {
            // 礼貌地告诉服务端我们要走了，而不是直接断线（服务端日志会干净很多）
            sendLine("BYE")
            usleep(150_000)
            _ = injector.releaseAllHeldButtons()
        }
        // ★ 必须显式收掉 kvm-keywatch 子进程：否则 app 退出后它变成孤儿，
        //   继续持有 IOHIDManager —— 做兼容性二分测试时会污染"不碰 HID"那些档位。
        keyboardLink.stop()
        // 热键也一起摘掉，避免退出瞬间还残留一个系统级占用
        // （Carbon 热键的注册/注销必须在主线程，所以下面两个都回到主线程做）
        runOnMain {
            self.sleepHotKey.unregister()
            self.mouseHotKey.unregister()
        }
    }

    /// SIGTERM / SIGINT：交给 dispatch source 处理，走和正常退出一样的清理
    private func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)                 // 先屏蔽默认行为，否则进程会直接死掉
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log("收到信号 \(sig) → 走正常退出流程（收子进程 + 摘热键）")
                self?.shutdownCleanly()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    // ---------------------------------------------------------------- 权限

    func refreshTrust() {
        let ok = AXIsProcessTrusted()
        trusted = ok
        log("权限检查：\(ok ? "已授权" : "未授权")")
    }

    func requestTrust() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshTrust()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // ---------------------------------------------------------------- 对外入口

    func start() {
        guard !isRunning else { return }
        // Xcode 预览里绝不去连真机：预览进程和正式 app 共用同一套偏好，
        // 一旦连上就是"两个客户端互相顶" —— 服务端只接受一个客户端，
        // 两边会不停把对方踢掉，正式那条连接就一直重连（2026-10-01 真发生过）。
        guard !Self.isRunningInPreview else {
            log("检测到 Xcode 预览环境 —— 不建立连接（避免和正式 app 互相顶）")
            return
        }
        let hostText = host.trimmingCharacters(in: .whitespaces)
        // ⚠️ 先记下"用户想连"，再去判地址 —— 否则"地址为空 → 自动查找"这条路
        //   找到地址之后没人知道我们本来是想连的，会停在"填好了但不连"（实测踩到）。
        wantConnected = true
        guard !hostText.isEmpty else {
            // 全新安装的第一次：地址是空的 —— 别让用户去查，自己找（PeerDiscovery.swift）
            log("还没有 Windows 地址 → 自动查找")
            autoDetectPeer()
            return
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else {
            log("端口无效：\(portText)"); return
        }

        TraiectusClient.defaults.set(hostText, forKey: "traiectus.host")
        TraiectusClient.defaults.set(String(port), forKey: "traiectus.port")
        TraiectusClient.defaults.set(token, forKey: "traiectus.token")

        reconnectAttempt = 0
        protocolErrorCount = 0
        pairingState = .idle         // 用户主动点了「连接」→ 上一次的配对结论作废，重新来
        DispatchQueue.main.async { self.isRunning = true }

        queue.async { [weak self] in
            guard let self else { return }
            self.currentHost = hostText
            self.currentPort = port
            self.currentToken = token
            self.connect()
        }
    }

    /// 设置页里地址/端口/口令改成"随时可改、改完自动生效"后，由 UI 在停止输入
    /// （去抖）时调用这里：存下新参数；本来就在连着的话，用新参数重连一次。
    ///
    /// 半截输入（比如刚删到只剩 "192." 或端口不是数字）直接忽略 —— 等用户输完整
    /// 自然会再来一次，不会拿残缺参数去连。
    func applyEditedParameters() {
        guard !Self.isRunningInPreview else { return }

        let hostText = host.trimmingCharacters(in: .whitespaces)
        let portRaw  = portText.trimmingCharacters(in: .whitespaces)
        guard !hostText.isEmpty, let port = UInt16(portRaw), port > 0 else { return }
        let tokenText = token

        TraiectusClient.defaults.set(hostText, forKey: "traiectus.host")
        TraiectusClient.defaults.set(String(port), forKey: "traiectus.port")
        TraiectusClient.defaults.set(tokenText, forKey: "traiectus.token")

        queue.async { [weak self] in
            guard let self else { return }
            // 三项都没变就什么都不做（去抖期间反复触发是常事）
            guard hostText != self.currentHost
                    || port != self.currentPort
                    || tokenText != self.currentToken else { return }

            self.currentHost = hostText
            self.currentPort = port
            self.currentToken = tokenText
            self.reconnectAttempt = 0
            self.offlineSince = nil

            // 用户没在连（从没点过「连接」）→ 只存不改，等他点连接时自然用新值
            guard self.wantConnected else { return }

            self.log("连接参数已改 → 用 \(hostText):\(port) 重连")
            self.dropConnection()
            self.connect()
        }
    }

    // ---------------------------------------------------------------- 自动找地址

    // ---------------------------------------------------------------- 显示器切换学习
    //
    //  代号不能猜：DDC/CI 的命令码各品牌一致，但**取值**不一样（LG 用另一套寻址、
    //  有些型号自定义），所以让用户"试出编号"比"抄一个 15/17"可靠。
    //  做法是两步：显示器按钮切到 Mac 读一次 → 切到 Windows 再读一次。
    //  详见 DisplaySwitch.swift 顶部的说明。

    /// 读到显示器此刻报的编号后，UI 上显示成这样（让用户能确认读的是不是他那台）
    @Published var displayInfo: String = ""
    /// 学习向导走到哪一步
    @Published var displayLearnStep: DisplayLearnStep = .idle
    @Published var displayLearnMessage: String = ""
    private var learnedMacInput: String?

    enum DisplayLearnStep: Equatable {
        case idle            // 没在学
        case waitingWindows  // 已记住 Mac 那边，正在等用户把显示器切过去
    }

    // 轮询用的令牌：每次开始/取消都 +1，旧的那轮自己退出（避免"取消了还在读"）
    private let displayPollLock = NSLock()
    private var displayPollToken = 0
    private func newPollToken() -> Int {
        displayPollLock.lock(); defer { displayPollLock.unlock() }
        displayPollToken += 1
        return displayPollToken
    }
    private func pollTokenIsCurrent(_ t: Int) -> Bool {
        displayPollLock.lock(); defer { displayPollLock.unlock() }
        return displayPollToken == t
    }

    /// 读一下显示器名字 + 当前输入源编号（会起进程，所以放后台）
    func refreshDisplayInfo() {
        guard !Self.isRunningInPreview else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let names = DisplaySwitch.monitorNames()
            let input = DisplaySwitch.currentInput()
            let text: String
            if DisplaySwitch.toolPath() == nil {
                text = L("没找到 m1ddc —— 切屏不可用")
            } else if names.isEmpty {
                text = L("没读到显示器（接了外接屏吗？）")
            } else {
                text = names.joined(separator: "、")
                     + (input.map { L(" · 当前输入源 ") + DisplaySwitch.describe($0) }
                        ?? L(" · 读不到输入源"))
            }
            DispatchQueue.main.async { self.displayInfo = text }
        }
    }

    /// 学习向导的主按钮：按当前步骤推进
    func advanceDisplayLearn() {
        guard !Self.isRunningInPreview else { return }
        displayLearnMessage = L("正在读取…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let value = DisplaySwitch.currentInput()
            DispatchQueue.main.async {
                guard let value else {
                    self.displayLearnMessage = L("读不到显示器的输入源。\n"
                        + "① 先确认显示器的 OSD 里 DDC/CI 是开启的（很多型号出厂是关的）；\n"
                        + "② 再确认显示器接在 Mac 的 HDMI / USB-C 上。")
                    return
                }
                // 只做一步：把"现在看到的这个编号"记成 Mac 那边。
                // 剩下那半（Windows 的编号）**不需要用户再点任何东西** ——
                // 显示器切走之后 Mac 照样能读到它报的编号（DDC 是同一条线上的低速侧信道，
                // 不跟着画面走，实测切到 DP 之后读回 15）。所以这里挂一个轮询，
                // 用户按显示器按钮切过去，我们自动认出来。
                //
                // 原来的设计要求"切到 Windows 之后再点一次"—— 那是错的：
                // 切过去之后 Mac 的界面根本不在屏幕上，用户看不到也点不到。
                self.learnedMacInput = value
                self.displayLearnStep = .waitingWindows
                self.displayLearnMessage = L("已记住 Mac 这边：{n}\n"
                    + "现在按显示器上的按钮切到 Windows —— 不用再点任何东西，"
                    + "切过去我就会自动记下来。", ["n": value])
                self.log("[显示器] 已记住 Mac 侧编号 \(value)，等显示器切走…")
                self.pollForWindowsInput(mac: value)
            }
        }
    }

    /// 盯着显示器报的编号，一变（且不是 Mac 那个）就认定是 Windows 的，保存。
    /// 读数是阻塞的，所以整轮放后台；`displayPollToken` 保证取消之后旧轮会自己退出。
    private func pollForWindowsInput(mac: String) {
        let token = newPollToken()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(60)   // 给足时间：用户要看显示器按钮、找位置
            while Date() < deadline, self.pollTokenIsCurrent(token) {
                if let v = DisplaySwitch.currentInput(), v != mac, v != "0", !v.isEmpty {
                    DispatchQueue.main.async {
                        guard self.pollTokenIsCurrent(token) else { return }
                        do {
                            try TraiectusConfig.saveDisplayInputs(mac: mac, windows: v)
                            self.displayLearnStep = .idle
                            self.displayLearnMessage = L("学好了：Mac = {mac}，Windows = {win}。\n"
                                                         + "已保存，切屏立刻用这套编号。",
                                                         ["mac": mac, "win": v])
                            self.log("[显示器] 学习完成：Mac=\(mac) Windows=\(v)（已写入 config.json）")
                        } catch {
                            self.displayLearnMessage = L("保存失败：{why}",
                                                         ["why": error.localizedDescription])
                        }
                        self.refreshDisplayInfo()
                    }
                    return
                }
                usleep(500_000)                            // 每 0.5 秒看一眼
            }
            DispatchQueue.main.async {
                guard self.pollTokenIsCurrent(token), self.displayLearnStep == .waitingWindows else { return }
                self.displayLearnMessage = L("等了 60 秒还没看到显示器切走。\n"
                                             + "确认一下：显示器的 OSD 里 DDC/CI 是开的；"
                                             + "然后用显示器上的按钮切到 Windows 那边。")
            }
        }
    }

    func cancelDisplayLearn() {
        _ = newPollToken()          // 让正在跑的那轮退出
        displayLearnStep = .idle
        learnedMacInput = nil
        displayLearnMessage = ""
    }

    /// 自动找 Windows 在哪。顺序：
    ///   ① 广播问一声（`WHO` → `HERE`，要 Windows 新版才认，毫秒级）
    ///   ② 扫自己所在的那个 /24（任何 Windows 版本都能用，约 1~2 秒）
    ///
    /// 找到就填进地址、存下来、立刻重连。手动点「自动检测」和"地址为空时自动触发"
    /// 走的是同一条路。
    func autoDetectPeer() {
        guard !Self.isRunningInPreview else { return }
        guard !discovering else { return }
        let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) ?? KVMProtocol.defaultPort

        discovering = true
        log("正在自动查找 Windows…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var hits = PeerDiscovery.askByBroadcast(timeout: 1.2)
            if hits.isEmpty {
                // ⚠️ 扫描前回主线程确认两件事，**这一步不能省**：
                //   ① 这 1.2 秒里可能已经通过心跳连上了 —— 那就根本不用扫；
                //   ② 扫的时候必须把当前连着的地址排掉。
                //   原因是服务端同一时刻只接受一个客户端：探测包会把已经连上的自己
                //   挤下线（Windows 侧文档里记过这个坑）。实测踩到过 —— 日志表现为
                //   "连接结束（本次维持 0.8 秒）"然后重连。
                let snap: (connected: Bool, host: String) =
                    DispatchQueue.main.sync { (self.isConnected, self.host) }
                if snap.connected {
                    self.log("已经连上了 → 跳过扫描")
                } else {
                    self.log("广播没有回应 → 扫描本机网段（最多 254 个地址，约 1~2 秒）")
                    hits = PeerDiscovery.scan(port: port, excluding: [snap.host])
                        .map { (ip: $0, port: port) }
                }
            } else {
                self.log("广播有 \(hits.count) 台应答")
            }

            // 结果一律回主线程处理：host / portText 是 @Published，只能在主线程改
            DispatchQueue.main.async {
                self.discovering = false
                guard let best = hits.first else {
                    self.log("没找到 Windows —— 请确认它在同一网段，且 Windows 上 Traiectus 已经启动")
                    return
                }
                if hits.count > 1 {
                    self.log("同网段找到 \(hits.count) 台，先用第一台：\(best.ip)")
                }
                self.log("找到 Windows：\(best.ip):\(best.port)")
                self.adoptDetectedPeer(best.ip, port: best.port)
            }
        }
    }

    /// 找到地址之后统一走这里：填上、存下、立刻连。
    ///
    /// ⚠️ 两条路**只能走一条**：它们是各自独立的连接发起入口，都调就会同时建两条 TCP，
    /// 而服务端同一时刻只接受一个客户端 —— 结果是刚连上就被自己顶掉（实测踩到，
    /// 日志里表现为"连接结束（本次维持 0.2 秒）"然后重连）。
    ///
    ///   · 客户端没在跑（全新安装开机自动连）→ `start()` 从零开始
    ///   · 客户端已经在跑（用户点了「自动检测」）→ `applyEditedParameters()` 用新地址重连
    private func adoptDetectedPeer(_ ip: String, port: UInt16?) {
        host = ip
        if let p = port { portText = String(p) }
        if isRunning {
            applyEditedParameters()
        } else {
            start()
        }
    }

    func stop() {
        wantConnected = false
        DispatchQueue.main.async { self.isRunning = false }
        DispatchQueue.main.async { self.pairingState = .idle }
        queue.async { [weak self] in
            guard let self else { return }
            self.log("用户断开连接")
            self.sendLine("BYE")
            usleep(120_000)          // 给 BYE 一点时间发出去
            self.dropConnection()
        }
    }

    func clearLog() {
        logLines.removeAll()
    }

    func setAutostart(_ on: Bool) {
        autostart = on
        TraiectusClient.defaults.set(on, forKey: "traiectus.autostart")
        log(on ? "已开启：启动时自动连接" : "已关闭：启动时自动连接")
    }

    /// 登录时启动（设置里那个开关）。真正登记在系统里（SMAppService），app 只负责转达。
    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        launchAtLoginError = LoginItem.set(on)
        log(on ? "已开启：登录时启动" : "已关闭：登录时启动")
        if let launchAtLoginError { log("⚠️ 登录时启动没改成功：\(launchAtLoginError)") }
    }

    /// 用户在「系统设置 → 通用 → 登录项」里改过之后，界面上的开关要跟上
    func refreshLaunchAtLogin() {
        launchAtLogin = LoginItem.isEnabled
        launchAtLoginError = nil
    }

    /// 键盘联动开关：按键盘上的切换快捷键时，屏幕 + 鼠标跟着键盘一起切
    func setLinkEnabled(_ on: Bool) {
        linkEnabled = on
        TraiectusClient.defaults.set(on, forKey: "traiectus.link")
        if on {
            if Self.isRunningInPreview {
                log("预览环境：不启动联动（避免占用抢跑端口 45790）")
            } else {
                keyboardLink.start()
                log("已开启：键盘联动（键盘切换键 → 键盘 + 鼠标 + 屏幕一起切）")
            }
        } else {
            keyboardLink.stop()
            log("已关闭：键盘联动")
        }
    }

    // ---------------------------------------------------------------- 睡眠快捷键

    /// 开关：打开时立刻注册热键（顺手把「自动化」授权框引出来），关掉时注销
    func setSleepHotKeyEnabled(_ on: Bool) {
        sleepHotKeyEnabled = on
        TraiectusClient.defaults.set(on, forKey: "traiectus.sleephotkey.enabled")
        if on {
            log("已开启：睡眠快捷键 \(SleepHotKey.displayString(keyCode: sleepHotKeyCode, modifiers: sleepHotKeyModifiers))")
            applySleepHotKey(reason: "开关打开")
        } else {
            sleepHotKey.unregister()
            sleepHotKeyConflict = false
            sleepHotKeyNeedsAutomation = false
            log("已关闭：睡眠快捷键")
        }
    }

    /// 录制到新组合键：先存下来，再按新键重新注册
    func setSleepHotKeyCombo(keyCode: UInt32, modifiers: UInt32) {
        sleepHotKeyCode = keyCode
        sleepHotKeyModifiers = modifiers
        TraiectusClient.defaults.set(Int(keyCode), forKey: "traiectus.sleephotkey.keycode")
        TraiectusClient.defaults.set(Int(modifiers), forKey: "traiectus.sleephotkey.modifiers")
        let text = SleepHotKey.displayString(keyCode: keyCode, modifiers: modifiers)
        log("睡眠快捷键已改为 \(text)")
        if sleepHotKeyEnabled { applySleepHotKey(reason: "改键") }
    }

    /// 设置里那行状态被点了一下：未启用就直接开；被占用就重试；缺授权就跳到系统设置
    func tapSleepHotKeyStatus() {
        switch sleepHotKeyStatus {
        case .notRunning:      setSleepHotKeyEnabled(true)
        case .conflict:        applySleepHotKey(reason: "手动重试")
        case .needsPermission: openAutomationSettings()
        default:               break
        }
    }

    /// 「自动化」授权在 系统设置 → 隐私与安全性 → 自动化
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // ---------------------------------------------------------------- 鼠标切换快捷键

    /// 开关：打开时立刻注册系统级热键，关掉时注销
    func setMouseHotKeyEnabled(_ on: Bool) {
        mouseHotKeyEnabled = on
        TraiectusClient.defaults.set(on, forKey: "traiectus.mousehotkey.enabled")
        if on {
            let text = GlobalHotKey.displayString(keyCode: mouseHotKeyCode, modifiers: mouseHotKeyModifiers)
            log("已开启：鼠标切换快捷键 \(text)")
            applyMouseHotKey(reason: "开关打开")
        } else {
            mouseHotKey.unregister()
            mouseHotKeyConflict = false
            log("已关闭：鼠标切换快捷键")
        }
    }

    /// 录制到新组合键：先存下来，再按新键重新注册
    func setMouseHotKeyCombo(keyCode: UInt32, modifiers: UInt32) {
        mouseHotKeyCode = keyCode
        mouseHotKeyModifiers = modifiers
        TraiectusClient.defaults.set(Int(keyCode), forKey: "traiectus.mousehotkey.keycode")
        TraiectusClient.defaults.set(Int(modifiers), forKey: "traiectus.mousehotkey.modifiers")
        let text = GlobalHotKey.displayString(keyCode: keyCode, modifiers: modifiers)
        log("鼠标切换快捷键已改为 \(text)")
        if mouseHotKeyEnabled { applyMouseHotKey(reason: "改键") }
    }

    /// 设置里那行状态被点了一下：未启用就直接开；被占用就重试
    func tapMouseHotKeyStatus() {
        switch mouseHotKeyStatus {
        case .notRunning: setMouseHotKeyEnabled(true)
        case .conflict:   applyMouseHotKey(reason: "手动重试")
        default:          break
        }
    }

    /// 注册热键。**必须在主线程**（Carbon 的事件目标在主 run loop 上），
    /// 所以这里自己做一次跳转，调用方不用记这条规矩。
    private func applyMouseHotKey(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyMouseHotKey(reason: reason) }
            return
        }
        let status = mouseHotKey.register(keyCode: mouseHotKeyCode,
                                          modifiers: mouseHotKeyModifiers) { [weak self] in
            self?.toggleMouseControlByHotKey()
        }
        let text = GlobalHotKey.displayString(keyCode: mouseHotKeyCode, modifiers: mouseHotKeyModifiers)
        mouseHotKeyConflict = (status != noErr)
        guard !mouseHotKeyConflict else {
            log("⚠️ 鼠标切换快捷键 \(text) 注册失败（OSStatus \(status)）—— 多半已被别的程序占用")
            return
        }
        log("鼠标切换快捷键已生效：\(text)（\(reason)）")
    }

    /// 热键动作：请求把鼠标控制权切到**另一边**。
    /// 目标从"当前在哪边"算 —— 服务端的 MODE 行是唯一真相（见 handleLine 的 MODE 分支）。
    private func toggleMouseControlByHotKey() {
        let target = mouseOnMac ? "Win" : "Mac"
        guard winOnline else {
            log("[鼠标切换] ⏸ Win 端未运行，跳过（本来要切到 \(target)）")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            // 协议 §3.3：和"联动"用的是同一条请求，服务端走的是与 Ctrl+Alt+M 完全相同的路径
            self.sendLine("MODE \(target)")
            self.pendingModeRequest = (target, Date())
            self.log("[鼠标切换] 快捷键触发 → 已请求控制权切到 \(target)")
        }
    }

    // ---------------------------------------------------------------- 键盘识别（换键盘不用查厂商 ID）

    /// 重新枚举当前挂在 Mac 上的键盘。IOKit 调用很快，但不在主线程做更稳妥。
    func refreshKeyboards() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = KeyboardDetect.connectedKeyboards()
            DispatchQueue.main.async { self?.keyboardCandidates = found }
        }
    }

    /// 当前配置的厂商 ID 有没有对上真正插着的键盘
    var keyboardVendorMatches: Bool {
        guard let want = KeyboardDetect.parseVendorID(TraiectusConfig.shared.keyboardVendorID) else {
            return false
        }
        return keyboardCandidates.contains { $0.vendorID == want }
    }

    /// 界面那一行的值：「CORSAIR K70 MINI · 蓝牙 · 0x1B1C」/「未检测到键盘」/「配置的 0x1B1C 看不到设备」
    var keyboardIdentityText: String {
        let configured = TraiectusConfig.shared.keyboardVendorID
        if let match = keyboardCandidates.first(where: {
            $0.vendorID == KeyboardDetect.parseVendorID(configured) ?? -1
        }) {
            return match.displaySummary
        }
        if keyboardCandidates.isEmpty {
            return L("未检测到键盘（可能正连在 Win 上）")
        }
        return L("配置的 {id} 在 Mac 上看不到 —— 点这里选一把", ["id": configured])
    }

    /// 选定"联动要盯哪把键盘"：写进 config.json → 重启 kvm-keywatch 子进程。
    func chooseKeyboard(_ candidate: KeyboardCandidate) {
        do {
            try TraiectusConfig.saveKeyboardVendorID(candidate.vidHex)
        } catch {
            log("⚠️ 键盘厂商 ID 写入 config.json 失败：\(error.localizedDescription)")
            return
        }
        log("[键盘识别] 已改为盯 \(candidate.summary)（写入 config.json）")
        // 联动关着的时候不要顺手把子进程拉起来 —— 只写配置，下次开联动自然生效
        if linkEnabled { keyboardLink.restartKeywatch() }
    }

    /// 启动时的自愈：配的 VID 在 Mac 上找不到任何键盘，而**只检测到一把**时，
    /// 直接改成它 —— 换键盘的人不该看到"联动一声不响地完全不动"。
    ///
    /// 检测到多把（笔记本自带 + 外接）时**不自动选**：选错了比不选更糟，
    /// 交给界面上的「检测键盘…」让用户点。
    private func autoHealKeyboardVendorID() {
        let candidates = KeyboardDetect.connectedKeyboards()
        DispatchQueue.main.async { self.keyboardCandidates = candidates }
        guard !candidates.isEmpty else { return }        // 键盘在 Windows 那边 → 判不了，先不动

        let configured = TraiectusConfig.shared.keyboardVendorID
        if let want = KeyboardDetect.parseVendorID(configured),
           candidates.contains(where: { $0.vendorID == want }) {
            return                                       // 对得上，什么都不用做
        }
        guard candidates.count == 1 else {
            log("[键盘识别] ⚠️ 配置的厂商 ID \(configured) 在 Mac 上看不到，而检测到 \(candidates.count) 把键盘："
                + candidates.map(\.summary).joined(separator: "、")
                + " —— 请在「设置 → 键盘」里选一把")
            return
        }
        let only = candidates[0]
        log("[键盘识别] 配置的厂商 ID \(configured) 在 Mac 上看不到任何键盘 → 自动改用检测到的唯一键盘：\(only.summary)")
        do {
            try TraiectusConfig.saveKeyboardVendorID(only.vidHex)
            if linkEnabled { keyboardLink.restartKeywatch() }
        } catch {
            log("⚠️ 键盘厂商 ID 写入 config.json 失败：\(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------- 键盘体检

    // ---------------------------------------------------------------- 键盘学习向导

    var learnButtonTitle: String {
        switch learnStep {
        case .idle:     return L("开始学习键盘切换")
        case .captureA: return L("开始采集（8 秒）")
        case .captureB: return L("开始采集（8 秒）")
        case .verify:   return L("开始复测（15 秒）")
        }
    }

    /// 向导的主按钮：按当前步骤做对应的事
    func advanceKeyboardLearn() {
        switch learnStep {
        case .idle:     beginKeyboardLearn()
        case .captureA: captureLearn(.captureA)
        case .captureB: captureLearn(.captureB)
        case .verify:   verifyKeyboardLearn()
        }
    }

    func cancelKeyboardLearn() {
        learnStep = .idle
        learnMessage = ""
        learnRulesText = ""
        learnFramesA = []
        learnFramesB = []
        learnRules = []
    }

    private func beginKeyboardLearn() {
        guard linkEnabled else {
            learnMessage = L("先打开「键盘联动」—— 学习靠它收帧。")
            return
        }
        guard winOnline else {
            learnMessage = L("Win 端没连上：状态帧要靠它转发过来。")
            return
        }
        guard keyboardLink.snapshotKeyboardOnMac() else {
            learnMessage = L("先把键盘切回 Mac（键盘上切 Mac 的那个快捷键），再开始 —— "
                             + "第一段采集要录「切去 Win」那一刻。")
            return
        }
        learnFramesA = []
        learnFramesB = []
        learnRules = []
        learnRulesText = ""
        learnStep = .captureA
        // ⚠️ 顺序必须是"先点采集、再按键"：
        //    状态帧**只在键盘归属变化的那一刻发一条**（实测 1.5 小时里只有 7 条，
        //    全是切换瞬间），而采集是"从点下去才开始录"、没有回看。
        //    所以先按后点会把那一帧整个漏掉 —— 这正是"学了好几次都是没收到帧"的原因。
        learnMessage = L("① 点「开始采集」，然后在 8 秒内按键盘上切到 Win 的快捷键")
    }

    private func captureLearn(_ step: LearnStep) {
        keyboardProbeRunning = true
        learnMessage = L("采集 8 秒…（现在就可以按键盘切换）")
        keyboardLink.capture(seconds: 8) { [weak self] frames in
            guard let self else { return }
            self.keyboardProbeRunning = false
            switch step {
            case .captureA:
                self.learnFramesA = frames
                guard !frames.isEmpty else {
                    self.learnStep = .idle
                    self.learnMessage = L("① 没收到任何帧。请确认：键盘已经切到 Win、接收器插在「这台」Win 上、"
                                          + "而且「键盘联动」是开着的。然后重来一次。")
                    return
                }
                self.learnStep = .captureB
                self.learnMessage = L("① 收到 {n} 帧 ✓　② 点「开始采集」，"
                                      + "然后在 8 秒内按键盘上切回 Mac 的快捷键",
                                      ["n": "\(frames.count)"])
            case .captureB:
                self.learnFramesB = frames
                guard !frames.isEmpty else {
                    self.learnStep = .idle
                    self.learnMessage = L("② 没收到任何帧。请确认键盘真的切回了 Mac（能在 Mac 上打字），再重来一次。")
                    return
                }
                self.buildAndSaveLearnRules()
            default:
                break
            }
        }
    }

    private func buildAndSaveLearnRules() {
        let result = KeyboardRuleBuilder.build(framesA: learnFramesA, sideA: "windows",
                                              framesB: learnFramesB, sideB: "mac")
        guard result.isOK else {
            learnStep = .idle
            learnMessage = localizedLearnFailure(result)
            log("[键盘学习] 失败：\(result.failure ?? "?") —— \(result.detail)")
            return
        }

        learnRules = result.rules
        learnRulesText = result.rules.map { rule in
            // 显示成 "win"（和下一行 "mac" 宽度对齐、也更短）。
            // 注意：**配置文件里存的值仍然是 "windows"** —— 只改展示，不动存盘格式，
            // 免得以前学过规则的那份 config.json 对不上。
            let label = (rule.side == "windows") ? "Win" : "Mac"
            return "\(label)：\(KeyboardRuleBuilder.hexString(rule.bytes))"
                + (rule.mask.contains(0x00) ? "   mask \(KeyboardRuleBuilder.hexString(rule.mask))" : "")
        }.joined(separator: "\n") + "\n" + L("（区分位：第 {bytes} 字节；掩码 {mask}）", [
            "bytes": result.discriminatingBytes
                .map { String($0 + 1) }
                .joined(separator: Localization.isEnglish ? ", " : "、"),
            "mask": result.maskHex,
        ])

        do {
            try TraiectusConfig.saveRules(result.rules)
            keyboardLink.reloadRules()
        } catch {
            learnStep = .idle
            learnMessage = L("规则学出来了，但写配置文件失败：{why}", ["why": error.localizedDescription])
            return
        }

        log("[键盘学习] 规则已保存并生效：")
        for line in learnRulesText.split(separator: "\n") {
            log("[键盘学习]   \(line)")
        }

        learnStep = .verify
        learnMessage = L("③ 规则已保存并生效 ✓　现在复测：点「开始复测」，"
                         + "然后在 15 秒内用键盘上的切换快捷键各切 2 次")
    }

    private func verifyKeyboardLearn() {
        learnStep = .idle
        keyboardProbeRunning = true
        learnMessage = L("复测中…15 秒，请用键盘上的切换快捷键各切 2 次")
        keyboardLink.runProbe(seconds: 15) { [weak self] report in
            guard let self else { return }
            self.keyboardProbeRunning = false
            // 界面上只给结论 + 收到几帧（见 KeyboardProbeReport.concise 的注释）
            self.learnMessage = L("复测结果：") + Self.localizedConcise(report)
            self.log("[键盘学习] 复测：\(report.verdict)")
            for line in report.detail.split(separator: "\n") {
                self.log("[键盘学习]   \(line)")
            }
        }
    }

    // ---------------------------------------------------------------- 键盘页文案（本地化）
    //
    //  KeyboardFrameRules 是纯函数模块（离线测试只编译它，不编译 Localization），
    //  所以那边只出中文原文；**界面文案在这里按结构化信息重新拼**，两边共用同一套用词。

    /// 复测结论 + 收到几帧（`KeyboardProbeReport.concise` 的本地化版）
    private static func localizedConcise(_ r: KeyboardProbeReport) -> String {
        let verdict = L(r.verdict)
        if Localization.isEnglish {
            return "\(verdict)\n\(Int(r.seconds)) s: \(r.frames) frames"
                + " (to Win: \(r.matchedWindows) / to Mac: \(r.matchedMac))"
        }
        return "\(verdict)\n\(Int(r.seconds)) 秒收到 \(r.frames) 帧"
            + "（去 Win \(r.matchedWindows) / 回 Mac \(r.matchedMac)）"
    }

    /// 学习失败的提示：原因（结构化标识 → 本地化）+ 明细 + 两侧帧数
    private func localizedLearnFailure(_ r: KeyboardRuleBuildResult) -> String {
        let why: String
        switch r.failureKind {
        case .noFramesBoth:         why = L("两侧都没有收到能解析的帧")
        case .noFramesSideA:        why = L("Win 那一侧没收到能解析的帧")
        case .noFramesSideB:        why = L("Mac 那一侧没收到能解析的帧")
        case .tooShort:             why = L("帧长度太短，没法比对")
        case .representativeFailed: why = L("取代表帧失败")
        case .notDistinguishable:   why = L("两组样本区分不开")
        case .ruleCreationFailed:   why = L("生成规则失败")
        case .none:                 why = L("未知原因")
        }

        var lines = [L("学不出来：") + why]
        switch r.failureKind {
        case .noFramesBoth, .noFramesSideA, .noFramesSideB:
            lines.append(L("收到 A 组 {a} 条、B 组 {b} 条（能解析成十六进制的：{pa} / {pb}）",
                           ["a": "\(learnFramesA.count)", "b": "\(learnFramesB.count)",
                            "pa": "\(r.parsedCounts.a)", "pb": "\(r.parsedCounts.b)"]))
        case .notDistinguishable:
            lines.append(L(r.detail))       // 固定文案，中英都整句放在对照表里
        default:
            break
        }
        lines.append(L("（A 组 {a} 帧 / B 组 {b} 帧）",
                       ["a": "\(learnFramesA.count)", "b": "\(learnFramesB.count)"]))
        return lines.joined(separator: "\n")
    }

    // ---------------------------------------------------------------- 运行期自检与诊断报告

    /// 键盘切换有多快（设置面板显示用）
    ///
    /// 界面上只给"很快 / 慢一点 / 未开启联动"这种大白话，
    /// 不说"抢跑""状态帧"这类内部术语（用户明确说过看不懂）。
    /// 术语和数字都放进 `detail`，挂在界面的 tooltip 和诊断报告里。
    var keyboardDetectionMode: (label: String, detail: String) {
        guard linkEnabled else {
            return (L("未开启（联动关着）"), L("打开「键盘联动」后才会收键盘信号（状态帧）"))
        }
        guard keyboardMatchedFrameCount > 0, let at = keyboardLastMatchedAt else {
            return (L("未开启（还没收到键盘信号）"),
                    L("本次运行还没收到键盘信号（状态帧）—— 切一次键盘就能判断。"
                      + "收不到时只能等 Mac 自己发现，切过去会晚约 1.7 秒。"))
        }
        let age = Date().timeIntervalSince(at)
        let ago = Localization.isEnglish
            ? (age < 120 ? "\(Int(age)) s ago" : "\(Int(age / 60)) min ago")
            : (age < 120 ? "\(Int(age)) 秒前" : "\(Int(age / 60)) 分钟前")

        return (L("已开启"),
                L("键盘信号（状态帧）正常在收（本次运行 {n} 条，最近一次 {ago}）：",
                  ["n": "\(keyboardMatchedFrameCount)", "ago": ago])
                + L("键盘刚从 Win 那边离开，屏幕就先切过去了 —— 切过去几乎无感。"))
    }

    private func diagnosticPath(for date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/Traiectus-键盘诊断-\(stamp).json")
    }

    /// 抢跑判定与实际归属不一致 → 落一份报告（帧序列 + 两个判定都在里面，可直接贴 issue）
    private func handleKeyboardMismatch(_ report: KeyboardDiagnosticReport) {
        // 把"当前检测方式"也记进报告（界面上不再显示这行细节，但排查时有用）
        var report = report
        report.detail.append("当前检测方式：\(keyboardDetectionMode.label)（\(keyboardDetectionMode.detail)）")
        let path = diagnosticPath(for: report.when)
        do {
            try report.json.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { self.keyboardMismatchCount += 1 }
            log("[键盘自检] ⚠️ 判定与实际不一致，诊断报告已落盘：\(path)")
        } catch {
            log("[键盘自检] ⚠️ 诊断报告写盘失败：\(error.localizedDescription)")
        }
    }

    /// 注册热键 + 预检自动化权限（预检走后台：首次会弹系统授权框，不能阻塞界面）
    private func applySleepHotKey(reason: String) {
        let status = sleepHotKey.register(keyCode: sleepHotKeyCode, modifiers: sleepHotKeyModifiers)
        let text = SleepHotKey.displayString(keyCode: sleepHotKeyCode, modifiers: sleepHotKeyModifiers)
        sleepHotKeyConflict = (status != noErr)
        guard !sleepHotKeyConflict else {
            log("⚠️ 睡眠快捷键 \(text) 注册失败（OSStatus \(status)）—— 多半已被别的程序占用")
            return
        }
        log("睡眠快捷键已生效：\(text)（\(reason)）")
        sleepHotKey.probeAutomation { [weak self] authorized in
            guard let self else { return }
            self.sleepHotKeyNeedsAutomation = !authorized
            if !authorized {
                self.log("⚠️ 睡眠快捷键缺少「自动化」授权 —— 系统设置 → 隐私与安全性 → 自动化 → 勾上 Traiectus")
            }
        }
    }

    /// 允许启动时自动连接，便于自动化测试与脚本化使用：
    ///   open build/Traiectus.app --args -traiectus.autostart YES -traiectus.host 192.168.1.20
    /// （UserDefaults 会把 `-键 值` 形式的命令行参数当成临时偏好值读进来）
    func autostartIfRequested() {
        guard !autostartDone else { return }
        autostartDone = true
        guard !Self.isRunningInPreview else {
            log("检测到 Xcode 预览环境 —— 跳过自动连接")
            return
        }
        guard TraiectusClient.defaults.bool(forKey: "traiectus.autostart") else { return }
        log("检测到自动连接开关，直接开始连接")
        start()
    }

    // ---------------------------------------------------------------- 连接生命周期（只在 queue 上调用）

    private func connect() {
        // 防御 + 取证：主机字段为空会让解析报 NoSuchRecord，这里给出默认值并留日志
        if currentHost.isEmpty {
            // 默认地址不再写死在代码里：先在 config.json 的 network.defaultHost 里找
            let fromConfig = TraiectusConfig.shared.defaultHost
            let fixed = host.isEmpty ? fromConfig : host
            guard !fixed.isEmpty else {
                log("[连接] 主机字段为空，也没配置默认地址 → 请在设置里填 Windows 的地址")
                DispatchQueue.main.async { self.isRunning = false }
                return
            }
            log("[连接] 主机字段为空 → 改用 \(fixed)"
                + (fromConfig.isEmpty ? "" : "（来自 config.json）"))
            currentHost = fixed
        }
        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        guard let port = NWEndpoint.Port(rawValue: currentPort) else {
            log("端口无法使用：\(currentPort)")
            return
        }

        reconnectAttempt += 1
        handshaken = false
        readyAt = nil
        framer.reset()
        lastReceive = Date()
        setStatus("连接中 \(currentHost):\(currentPort)（第 \(reconnectAttempt) 次）")

        // 显式关掉 Nagle：鼠标事件是十几字节的小包，被攒起来就是几十毫秒的延迟
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // ⚠️ 一定要绕开系统代理，否则"用户开着代理"就等于连不上。
        //
        // 2026-10-03 实测：Network.framework 默认会尊重系统代理设置。用户装了
        // Clash / v2rayN / Surge 这类软件时，系统代理里通常只把**某几个具体 IP**
        // 列进例外名单；局域网里别的地址会被丢给代理，而代理根本到不了内网 ——
        // 表现是 NWConnection 报"已连接"，但**一个字节都没到 Windows**，
        // 于是客户端永远停在"连上→断→重连"的循环里（实测连着几十次都这样）。
        //
        // 更麻烦的是：这台机器以前能用，只是因为 Windows 当时的 IP 恰好在例外名单里；
        // Windows 一换 IP（DHCP 很常见）就突然连不上了，用户完全看不出跟代理有关。
        //
        // 设成 true 之后，本连接不再受任何代理设置影响，直连局域网。
        // 我们连的本来就是同一网段的私有地址，没有任何理由走代理。
        // 实测对照：同一个地址、同一个开关关掉时，服务端收不到数据；
        // 打开后立刻收到。
        parameters.preferNoProxies = true

        // ⚠️ 关键：地址是 IP 时**直接构造 IP 端点**，不要交给解析器。
        // 用 `NWEndpoint.Host("192.168.1.20")` 会被当成"主机名"去解析，
        // 而 v2rayN 之类的代理会劫持 DNS → 解析失败（NWError -65554 NoSuchRecord）
        // → 表现就是"开着代理就连不上、鼠标不动"。
        let hostEndpoint: NWEndpoint.Host
        if let v4 = IPv4Address(currentHost) {
            hostEndpoint = .ipv4(v4)
        } else if let v6 = IPv6Address(currentHost) {
            hostEndpoint = .ipv6(v6)
        } else {
            hostEndpoint = NWEndpoint.Host(currentHost)      // 真主机名才走解析
        }
        let conn = NWConnection(host: hostEndpoint, port: port, using: parameters)
        log("[连接] 目标 \(hostEndpoint)（字段=\"\(currentHost)\" 端口 \(currentPort) 第 \(reconnectAttempt) 次）")
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }
            self.handle(state: state, on: conn)
        }
        conn.start(queue: queue)
        receive(on: conn)
        startHeartbeat()
    }

    private func handle(state: NWConnection.State, on conn: NWConnection) {
        switch state {
        case .preparing:
            setStatus("正在建立 TCP 连接…")
        case .ready:
            readyAt = Date()
            offlineSince = nil          // 连上了：重置退避计时（P1）
            handshaken = false
            if token.trimmingCharacters(in: .whitespaces).isEmpty {
                // 本地还没有口令 → 走配对：请用户在 Windows 上点一下「允许」。
                // 全程零输入，口令由服务端生成后回给这里（PROTOCOL.md §2.1）。
                pairingSentAt = Date()
                log("TCP 已连接。本地还没有口令 → 发起配对，请在 Windows 上点「允许」")
                DispatchQueue.main.async { self.pairingState = .requesting }
                sendLine("PAIR? \(Self.deviceName)")
            } else {
                pairingSentAt = nil
                log("TCP 已连接，发送握手…")
                sendLine("HELLO \(KVMProtocol.version) Mac \(token)")
            }
        case .waiting(let error):
            log("网络等待中：\(error.localizedDescription)")
        case .failed(let error):
            logConnectFailure(error.localizedDescription)
            dropConnection()
            scheduleReconnect()
        case .cancelled:
            dropConnection()
            scheduleReconnect()
        default:
            break
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }

            if let data, !data.isEmpty {
                // 打点：两次 socket 回调之间的间隔（如果这里出现上百毫秒，说明是接收侧的问题）
                let gapMs = Date().timeIntervalSince(self.lastRxCallbackAt) * 1000
                if gapMs > self.maxRxGapMs { self.maxRxGapMs = gapMs }
                self.lastRxCallbackAt = Date()
                self.lastReceive = Date()
                self.framer.append(data)
                guard conn === self.connection else { return }   // framer 可能已触发断开
            }

            if let error {
                if self.readyAt == nil {
                    // 连接还没建立成功：这是"连不上"，不是"收到坏数据"
                    self.logConnectFailure(error.localizedDescription)
                } else {
                    self.log("接收出错：\(error.localizedDescription)")
                    if !handshaken { self.noteHandshakeAbort() }   // 见下面那个函数的注释
                }
                self.dropConnection()
                self.scheduleReconnect()
                return
            }
            if isComplete {
                if !handshaken { self.noteHandshakeAbort() }
                self.dropConnection()
                self.scheduleReconnect()
                return
            }
            self.receive(on: conn)
        }
    }

    private func dropConnection() {
        availability.online = false      // P0-1：断线立即判定离线（不必等 3 秒心跳超时）
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        if let ready = readyAt, handshaken {
            log(String(format: "连接结束（本次维持 %.1f 秒）", Date().timeIntervalSince(ready)))
        }
        handshaken = false
        readyAt = nil
        pingSentAt.removeAll()
        framer.reset()

        let released = injector.releaseAllHeldButtons()
        if !released.isEmpty {
            log("补发抬起（防止按键卡住）：\(released.joined(separator: " "))")
        }

        DispatchQueue.main.async { self.isConnected = false }
        setStatus(wantConnected ? "未连接（稍后重连）" : "未连接")
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        // P1 自适应：前 30 秒维持 ≤1 秒退避；超过 30 秒改成 10 秒一次（对端可能长时间不在）
        if offlineSince == nil { offlineSince = Date() }
        let offlineFor = Date().timeIntervalSince(offlineSince ?? Date())
        let delay = offlineFor > 30
            ? 10.0
            : min(KVMProtocol.maxReconnectDelay, 0.25 * pow(2, Double(max(0, reconnectAttempt - 1))))
        setStatus(String(format: "%.2f 秒后重连…", delay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnected, self.connection == nil else { return }
            self.connect()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + KVMProtocol.heartbeatInterval,
                       repeating: KVMProtocol.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        timer.resume()
        heartbeatTimer = timer
    }

    /// 每 500 ms 判定一次"Windows 端是否在线"：
    /// TCP 已 ready **且** 3 秒内收到过 PONG —— 只看 ready 不够，
    /// 对端进程卡死时 TCP 可能还在，只有心跳停了才算真离线。
    private func startOnlineWatchdog() {
        onlineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let ready = (self.connection?.state == .ready)
            let fresh = Date().timeIntervalSince(self.lastPongAt) < 3
            self.availability.online = (ready && fresh)
        }
        timer.resume()
        onlineTimer = timer
    }

    /// 监听系统网络路径（代理/VPN 起停、换节点、Wi-Fi 切换…）。
    /// 路径一变，就**立即重连**，不等 3 秒心跳超时、也不等退避 ——
    /// 否则 v2rayN 开关一次就可能让鼠标"卡死"到需要重开 app。
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async { self.handlePathChange(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.traiectus.client.pathmonitor"))
    }

    private func handlePathChange(_ path: NWPath) {
        let names = Set(path.availableInterfaces.map { $0.name })
        let status = path.status
        let firstUpdate = (lastPathStatus == nil)
        let changed = (status != lastPathStatus) || (names != lastInterfaceNames)
        lastPathStatus = status
        lastInterfaceNames = names
        guard !firstUpdate, changed else { return }

        log("[网络] 路径变化（状态 \(status == .satisfied ? "可用" : "不可用")、"
            + "接口 \(names.sorted().joined(separator: ","))）")
        guard wantConnected else { return }
        // 去抖：路径抖动时可能连续回调，1 秒内只重连一次
        guard Date().timeIntervalSince(lastPathReconnectAt) > 1 else { return }
        lastPathReconnectAt = Date()
        log("[网络] 立即重连（不等心跳超时 / 不等退避）")
        offlineSince = nil          // 重置 P1 退避，让它走最短路径
        reconnectAttempt = 0
        dropConnection()
        connect()
    }

    private func heartbeatTick() {
        guard connection != nil else { return }

        // 1) 握手超时
        if !handshaken, let ready = readyAt {
            // 配对期间要等用户走到 Windows 那边点确认，3 秒远远不够 —— 用服务端
            // 30 秒确认窗口 + 余量。普通握手仍然按原来的 3 秒判死。
            if let sentAt = pairingSentAt {
                if Date().timeIntervalSince(sentAt) > KVMProtocol.pairingTimeout {
                    log("配对超时（\(Int(KVMProtocol.pairingTimeout)) 秒没有等到 Windows 上的确认）")
                    pairingSentAt = nil
                    DispatchQueue.main.async { self.pairingState = .denied("timeout") }
                    dropConnection()
                    scheduleReconnect()
                    return
                }
            } else if Date().timeIntervalSince(ready) > KVMProtocol.handshakeTimeout {
                log("握手超时（\(Int(KVMProtocol.handshakeTimeout)) 秒没有收到 HELLO-OK）")
                dropConnection()
                scheduleReconnect()
                return
            }
        }

        // 2) 对端超时（拔网线 / 对端睡眠时靠这个发现）
        //    ⚠️ 配对期间必须跳过：这几秒本来就在等用户走到 Windows 那边点「允许」，
        //    对端不发任何数据是正常的。不跳过的话，用户手慢一点连接就被掐掉、
        //    然后重连再弹一次确认框，永远配不上（实测踩到过）。
        //    配对本身的时限由上面的 pairingTimeout 负责。
        if pairingSentAt == nil,
           Date().timeIntervalSince(lastReceive) > KVMProtocol.peerTimeout {
            log("超过 \(Int(KVMProtocol.peerTimeout)) 秒没有收到对端任何数据，判定断线")
            peerTimeouts += 1
            // 握手成功后却反复失联：最常见的解释是"服务端同一时刻只接受一个客户端"，
            // 也就是说有第二个 Traiectus Client 实例在互相踢。
            if handshaken && peerTimeouts % 3 == 0 {
                log("提示：已多次「握手成功后又失联」。服务端同一时刻只接受一个客户端 ——"
                    + "请确认没有第二个 Traiectus Client 实例在运行（Dock / 活动监视器里检查）。")
            }
            dropConnection()
            scheduleReconnect()
            return
        }

        // 3) 心跳
        if handshaken {
            let id = nextPingId
            nextPingId += 1
            if pingSentAt.count > 32 { pingSentAt.removeAll() }
            pingSentAt[id] = Date()
            sendLine("PING \(id)")
        }

        // 3.5) 我们的 MODE 请求服务端有没有响应？（没响应＝多半是旧版服务端）
        if let pending = pendingModeRequest, Date().timeIntervalSince(pending.at) > 1.5 {
            // 服务端只在"模式真的变了"时才回 MODE 行。如果它本来就在这个模式上，
            // 我们请求的是同一个值 —— 那不是"没响应"，是没什么可响应的。
            // （实测：唤醒后连发两次 MODE Mac，第二次服务端没回，旧代码会误报"旧版服务端"。）
            if pending.mode.uppercased() == serverMode.uppercased() {
                pendingModeRequest = nil
            } else {
                log("⚠ 已请求鼠标控制权 → \(pending.mode)，但服务端 1.5 秒内没有确认。"
                    + "最常见的原因是 Windows 上跑的是**旧版**服务端（不认识客户端的 MODE 请求）——"
                    + "请用共享目录里的 重编并启动服务端.bat 重编并重启。")
                pendingModeRequest = nil
            }
        }

        // 4) 速率统计（每秒更新一次界面）
        let now = Date()
        let elapsed = now.timeIntervalSince(countedAt)
        if elapsed >= 1 {
            let rate = Double(eventCount) / elapsed
            eventCount = 0
            countedAt = now
            let total = injectedTotal
            DispatchQueue.main.async {
                self.eventRate = rate
                self.injectedEvents = total
            }
        }

        // 5) 每 5 秒写一行诊断统计，用来和服务端的往返数据交叉验证：
        //    如果这里"最大收包间隔"只有几毫秒，而服务端报的往返是几十上百毫秒，
        //    那延迟就在 Windows 侧的收发循环里，不在 Mac。
        let sinceStats = now.timeIntervalSince(statsWindowAt)
        if sinceStats >= 5 {
            let rxRate = Double(rxLinesInWindow) / sinceStats
            let injectionRate = Double(injectedInWindow) / sinceStats
            let rtt = lastLatencyMs >= 0 ? String(format: "%.1f ms", lastLatencyMs) : "—"
            log(String(format: "统计 %.0f 秒：收 %5.1f 行/秒 · 注入 %5.1f 事件/秒 · 往返(最近) %@ · 最大收包间隔 %.1f ms · 单行最长处理 %.2f ms",
                       sinceStats, rxRate, injectionRate, rtt, maxRxGapMs, maxHandleMs))
            rxLinesInWindow = 0
            injectedInWindow = 0
            maxRxGapMs = 0
            maxHandleMs = 0
            statsWindowAt = now
        }
    }

    private func sendLine(_ line: String) {
        guard let conn = connection else { return }
        conn.send(content: Data((line + "\n").utf8),
                  completion: .contentProcessed { [weak self] error in
            if let error { self?.log("发送失败：\(error.localizedDescription)") }
        })
    }

    /// 握手还没完成连接就没了 —— 这是个**很容易被误判**的现象，专门记一笔。
    ///
    /// 2026-10-03 实测：用户开着代理（Clash / v2rayN / Surge）时，系统代理会把本机到
    /// 内网地址的连接**在本地"接住"**：NWConnection 报"已连接"，对端却一个字节都没收到，
    /// 自然不会有任何应答。表现就是"连上 → 立刻断 → 重连"，循环几十次，
    /// **日志里一句原因都没有**（那次排查花了几个小时）。
    ///
    /// 所以连着几次之后主动把话说明白，别再让人从头查一遍。
    private func noteHandshakeAbort() {
        handshakeEofs += 1
        log("对端在握手完成前就断开了（第 \(handshakeEofs) 次）—— TCP 连上了但没收到任何应答")
        if handshakeEofs == 3 {
            log("提示：TCP 能连上却收不到应答，最常见的原因是**代理软件**（Clash / v2rayN / "
                + "Surge 等）把到局域网地址的连接吞掉了。请在代理里把本机网段设为直连/绕过。")
        }
    }

    // ---------------------------------------------------------------- 协议处理（只在 queue 上调用）

    private func handle(line: String) {
        let started = Date()
        defer {
            let ms = Date().timeIntervalSince(started) * 1000
            if ms > maxHandleMs { maxHandleMs = ms }
        }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first?.uppercased() else { return }
        rxLinesInWindow += 1

        guard handshaken else {
            switch command {
            case "HELLO-OK":
                handshaken = true
                handshakeEofs = 0        // 握手成功了 → "连上就断"的计数重新开始
                reconnectAttempt = 0
                connectFailures = 0
                countedAt = Date()
                let version = parts.count > 1 ? parts[1] : "?"
                log("握手成功（协议版本 \(version)）")
                setStatus("已连接 \(currentHost):\(currentPort)")
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.authFailed = false
                    self.pairingState = .idle
                }
            case "PAIR-OK":
                // 用户在 Windows 上点了「允许」。口令是这一行的**余下全部内容**
                // （和 HELLO 的口令同规矩），随后在**同一条连接**上继续正常握手。
                let newToken = parts.dropFirst().joined(separator: " ")
                guard !newToken.isEmpty else {
                    log("配对应答里没有口令 → 视为失败，断开")
                    pairingSentAt = nil
                    dropConnection()
                    scheduleReconnect()
                    return
                }
                pairingSentAt = nil
                TraiectusClient.defaults.set(newToken, forKey: "traiectus.token")
                log("配对成功 —— 口令已保存（\(newToken.count) 字符），继续握手")
                // currentToken 必须一起更新，理由见 ERR NOPAIR 那段的注释
                currentToken = newToken
                DispatchQueue.main.async {
                    self.token = newToken
                    self.pairingState = .idle
                }
                sendLine("HELLO \(KVMProtocol.version) Mac \(newToken)")
            case "PAIR-NO":
                let why = parts.dropFirst().joined(separator: " ")
                pairingSentAt = nil
                log("配对未完成（\(why)）—— 已停止自动重连。"
                    + "可以在「连接设置」里手动填口令，或确认后在 Windows 上点「允许」再重连。")
                DispatchQueue.main.async {
                    self.pairingState = .denied(why)
                    self.authFailed = true      // 面板显示「异常」，别再自动重连去打扰用户
                }
                wantConnected = false
                DispatchQueue.main.async { self.isRunning = false }
                dropConnection()
            case "ERR":
                let why = parts.dropFirst().joined(separator: " ")
                log("服务端拒绝连接：\(why)")
                let upper = why.uppercased()
                if upper.contains("NOPAIR") || upper.contains("AUTH") {
                    // 这两条都属于"本地这份口令已经不作数，重新配对才能修"：
                    //   NOPAIR = 服务端压根没有口令   → 重新配对必然成功（会弹框）
                    //   AUTH   = 服务端有口令但对不上 → 重新配对会被回 already-paired，
                    //            但至少把用户引到"去 Windows 托盘点重新配对"这条明路上
                    //
                    // 口令已经**没有输入框**了（PROTOCOL.md §2.1：口令由配对生成），
                    // 所以这里必须自愈，不能停在"口令错误"让用户无从下手。
                    log(upper.contains("NOPAIR")
                        ? "Windows 端没有口令（可能刚重新配对过）→ 清掉本地口令并重新配对"
                        : "本地口令和服务端对不上 → 清掉本地口令，改用配对重新申请")
                    TraiectusClient.defaults.removeObject(forKey: "traiectus.token")
                    // ⚠️ currentToken 必须同步清掉：设置页盯着 host / portText 做
                    // "改完自动重连"，它分不清"用户改的"和"代码改的"。不同步的话，
                    // 清口令可能被当成用户改动 → 1.2 秒后又重连一次 → 第二个 PAIR?
                    // 撞上 Windows 还开着的确认框 → PAIR-NO busy（2026-10-01 实测踩到）。
                    currentToken = ""
                    DispatchQueue.main.async {
                        self.token = ""
                        self.pairingState = .idle
                    }
                    wantConnected = true
                    reconnectAttempt = 0
                    DispatchQueue.main.async { self.isRunning = true }
                    dropConnection()
                    scheduleReconnect()
                    return
                }
                // 其余错误（例如协议版本不符）：停在这里，别自动重连去打扰用户
                DispatchQueue.main.async { self.authFailed = true }   // 面板显示「异常」
                wantConnected = false
                DispatchQueue.main.async { self.isRunning = false }
                dropConnection()
            default:
                // 握手完成之前，任何事件行都必须丢弃
                break
            }
            return
        }

        switch command {
        case "MODE":
            // PROTOCOL.md v1.1：服务端告知当前控制权在哪一端
            guard parts.count == 2 else { protocolError("MODE 参数不对：\(line)"); return }
            let mode = parts[1].uppercased()
            if let pending = pendingModeRequest, pending.mode.uppercased() == mode {
                pendingModeRequest = nil        // 服务端确认了我们刚才的请求
            }
            if mode == "WIN" {
                serverMode = "Win"
                DispatchQueue.main.async { self.mouseOnMac = false }
                let released = injector.releaseAllHeldButtons()
                log("服务端切到 Windows 模式：停止注入"
                    + (released.isEmpty ? "" : "，并补发抬起 \(released.joined(separator: " "))"))
            } else if mode == "MAC" {
                serverMode = "Mac"
                DispatchQueue.main.async { self.mouseOnMac = true }
                log("服务端切到 Mac 模式：恢复注入")
            } else {
                protocolError("MODE 取值不认识：\(parts[1])")
            }
            return

        case "MOVE":
            // Windows 模式下服务端本就不该发事件；真收到了就防御性忽略
            guard serverMode == "Mac" else { return }
            guard parts.count == 3, let dx = Int(parts[1]), let dy = Int(parts[2]) else {
                protocolError("MOVE 参数不对：\(line)"); return
            }
            injector.move(dx: dx, dy: dy)
            countEvent()

        case "DOWN", "UP":
            guard serverMode == "Mac" else { return }
            guard parts.count == 2 else { protocolError("\(command) 参数不对：\(line)"); return }
            if !injector.button(name: parts[1], down: command == "DOWN") {
                protocolError("未知按键名：\(parts[1])"); return
            }
            countEvent()

        case "WHEEL", "HWHEEL":
            guard serverMode == "Mac" else { return }
            guard parts.count == 2, let delta = Int(parts[1]) else {
                protocolError("\(command) 参数不对：\(line)"); return
            }
            injector.wheel(delta: delta, horizontal: command == "HWHEEL")
            countEvent()

        case "PING":
            if parts.count == 2 { sendLine("PONG \(parts[1])") }

        case "PONG":
            if parts.count == 2, let id = UInt64(parts[1]), let sent = pingSentAt.removeValue(forKey: id) {
                let ms = Date().timeIntervalSince(sent) * 1000
                DispatchQueue.main.async { self.lastLatencyMs = ms }
            }
            lastPongAt = Date()      // 心跳存活 → 供在线判定使用

        case "BYE":
            log("服务端主动结束连接")
            dropConnection()
            scheduleReconnect()

        default:
            protocolError("未知命令：\(line)")
        }
    }

    private func countEvent() {
        eventCount += 1
        injectedInWindow += 1
        injectedTotal += 1
    }

    private func protocolError(_ text: String) {
        protocolErrorCount += 1
        if protocolErrorCount <= 5 {
            log("协议：\(text)")
        } else if protocolErrorCount == 6 {
            log("协议：继续收到不认识的命令，后续不再逐条打印")
        }
    }

    /// 连不上时不要每秒刷一行日志：前两次照打，之后每 10 次打一行。
    /// （Windows 机器没开机时，客户端会一直处于重连状态。）
    private func logConnectFailure(_ text: String) {
        let offlineFor = offlineSince.map { Date().timeIntervalSince($0) } ?? 0
        // 连续失败时给一条"最可能的原因"提示：九成是 Windows 那边的服务端没在跑
        // （端口 45789）。每 5 次提示一次，避免刷屏。
        if reconnectAttempt > 0 && reconnectAttempt % 5 == 0 {
            log("提示：连不上 \(currentHost):\(currentPort) 最常见的原因是——"
                + "Windows 上的 Traiectus-Server 窗口没在跑（双击 start-server.bat 或 重编并启动服务端.bat），"
                + "其次是本机「本地网络」权限未授权（系统设置 → 隐私与安全性 → 本地网络）。")
        }
        // P1 降噪：离线超过 30 秒后，连接失败日志改为每 10 次一行
        if offlineFor > 30 && reconnectAttempt % 10 != 0 {
            connectFailures += 1
            return
        }
        connectFailures += 1
        if connectFailures <= 2 || connectFailures % 10 == 0 {
            log("连接失败（第 \(connectFailures) 次）：\(text)")
        }
    }

    // ---------------------------------------------------------------- 日志

    private func log(_ text: String) {
        let line = "[\(Self.stampFormatter.string(from: Date()))] \(text)"
        // 同时写到 stderr：从终端直接跑这个二进制时能看见完整日志，方便排查。
        FileHandle.standardError.write(Data((line + "\n").utf8))
        // 再写一份到日志文件：不管是谁启动的，事后都能读到程序自己看到的真实状态。
        logFileQueue.async {
            let path = Self.logFilePath
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
            }
        }
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 400 {
                self.logLines.removeFirst(self.logLines.count - 400)
            }
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }
}

// MARK: - 界面状态与动作（供 src/ui/ 使用）

extension TraiectusClient {
    /// 面板与菜单栏图标用的状态（由 TCP / 心跳 / 控制权派生）
    public var linkState: LinkState {
        if authFailed { return .error }
        if !winOnline { return .windowsOffline }
        if !isConnected { return .connecting }
        return .connected(side: mouseOnMac ? .mac : .win)
    }

    /// 「键盘联动」的状态行：未授权 → 需要授权；开关关着 → 未运行
    var keyboardLinkStatus: FeatureStatus {
        if !trusted { return .needsPermission }
        if !linkEnabled { return .notRunning }
        return .enabled
    }

    /// 「睡眠快捷键」的状态行：关着 → 未运行；注册不上 → 被占用；缺自动化授权 → 需要授权
    var sleepHotKeyStatus: FeatureStatus {
        if !sleepHotKeyEnabled { return .notRunning }
        if sleepHotKeyConflict { return .conflict }
        if sleepHotKeyNeedsAutomation { return .needsPermission }
        return .enabled
    }

    /// 「鼠标切换」的状态行：没开 → 未运行；被别的程序占了 → 快捷键被占用。
    /// 它不像睡眠热键那样要「自动化」授权 —— 发 MODE 走的是已有的 TCP 连接。
    var mouseHotKeyStatus: FeatureStatus {
        if !mouseHotKeyEnabled { return .notRunning }
        if mouseHotKeyConflict { return .conflict }
        return .enabled
    }

    /// 「自动连接」的状态行：没连着 → 未运行（可点击立即重连）
    var autoConnectStatus: FeatureStatus {
        if winOnline { return .enabled }
        if let until = manualReconnectUntil, Date() < until { return .connecting }
        return .notRunning
    }

    /// 立即重连：不等退避（设置里"未运行"状态点一下用）
    func reconnectNow() {
        guard !Self.isRunningInPreview else { return }
        let until = Date().addingTimeInterval(6)
        DispatchQueue.main.async { self.manualReconnectUntil = until }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
            guard let self else { return }
            if let u = self.manualReconnectUntil, Date() >= u { self.manualReconnectUntil = nil }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.log("手动触发重连")
            self.offlineSince = nil
            self.reconnectAttempt = 0
            self.wantConnected = true
            DispatchQueue.main.async { self.isRunning = true }
            self.dropConnection()
            self.connect()
        }
    }

    /// 打开日志目录（~/Library/Logs）
    func openLogsFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        NSWorkspace.shared.open(dir)
    }
}
