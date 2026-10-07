// ============================================================================
//  KeyboardLink —— 键盘联动（做进 Traiectus Client 里的版本）
// ----------------------------------------------------------------------------
//  目的：一次 Fn 按键 → 键盘 + 鼠标 + 屏幕一起切（Mac 侧只需开这一个 app）。
//
//  原理：
//    · Fn 组合是键盘固件内部的键，主机收不到 —— 只能靠"键盘归属变了"来推断
//    · 检测复用已经在用的 kvm-link/kvm-keywatch（IOKit 设备事件，毫秒级）
//    · Windows 桥接会把接收器的状态帧提前 1.5 秒发过来（UDP 45790），用来抢跑切屏
//    · 鼠标控制权通过 Traiectus 自己那条 TCP 连接发 `MODE Mac|Win`（协议 §3.3），
//      不再需要额外通道
//    · 屏幕输入源用 m1ddc（启动约 5 ms；dwc 要 300~400 ms），没有 m1ddc 时回退 dwc
//    · 切换时把 Mac 光标移到主屏中心，并重新关联鼠标（warp 会解绑，必须补）
//
//  只读设备、只调本机工具，不改任何系统设置。
// ============================================================================

import Foundation
import CoreGraphics

final class KeyboardLink {

    enum Side: String {
        case windows = "Win"
        case mac = "Mac"
    }

    // 依赖工具（kvm-keywatch / m1ddc）**随 app 一起打包**：build.sh 会把它们拷进
    // Contents/Resources/，所以装到哪儿都能自给自足，不再依赖仓库路径
    // （相对路径是以 app 可执行文件所在目录为基准：Contents/MacOS/）
    // 想用别的位置 → 在 config.json 的 tools 里写绝对路径（见 config.example.json）
    static let keywatchRelativePaths = [
        "../Resources/kvm-keywatch",                       // 打包在 app 内（推荐路径）
        "../../../kvm-link/kvm-keywatch",                  // 从仓库 build/ 直接跑时
    ]
    static let m1ddcRelativePaths = [
        "../Resources/m1ddc",                              // 打包在 app 内
        "../../../kvm-link/m1ddc/m1ddc",
    ]
    static let dwcCandidates = [
        "../Resources/dwc",
        "../../../display-input/dwc",
    ]

    // ---- 对外
    var log: ((String) -> Void)?
    /// 每收到一条「规则认得」的帧时回调（客户端用来显示"当前检测方式：抢跑"）
    var onMatchedFrame: ((Date) -> Void)?
    /// 抢跑判定与实际归属不一致时回调（客户端负责落盘诊断报告）
    var onMismatch: ((KeyboardDiagnosticReport) -> Void)?
    /// 收到 Windows 发来的任何 UDP 包时，把**来源 IP** 报上去。
    /// Windows 每 2 秒发一次 HB 心跳，所以这条几乎总是有货 —— 用来"自己学会 Windows 的地址"。
    /// （在 queue 上回调，调用方自己注意线程。）
    var onPeerSeen: ((String) -> Void)?
    /// 需要把鼠标控制权切到某一侧时回调（由客户端发 `MODE <值>` 给服务端）
    var onMouseSide: ((Side, String) -> Void)?
    /// Windows 端是否在线（由客户端注入：TCP ready + 3 秒内有 PONG）。
    /// 离线时**只挡输出动作**（切屏 / 发 MODE / Warp 光标），本地键盘归属照常更新。
    var isOnline: (() -> Bool)?

    // ---- 系统睡眠 / 唤醒（由 TraiectusClient 监听 NSWorkspace 事件后调用）
    /// 键盘此刻是否在 Mac 上
    var keyboardOnMac: Bool { detectedState != nil }

    // ---- 内部
    private var proc: Process?
    private var readBuffer = Data()
    private var udpFD: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var ticker: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.traiectus.client.keyboardlink")

    private var state: String?          // "bt" / "usb" / nil（不在 Mac 上）
    private var pending: String?
    private var changedAt = Date()
    private var lastActed: String?
    private var hint: Side?             // 抢跑后等蓝牙跟上
    private var hintDeadline = Date()
    private var udpPort: UInt16 = 45790
    /// 正在睡眠：键盘的蓝牙链路会掉，那是"Mac 睡过去了"，不是"键盘走了"
    private var isSleeping = false
    /// 睡眠窗口的起点（看门狗用：睡太久还没收到唤醒通知就自己收尾）
    private var sleepStartedAt = Date()
    /// 唤醒后的宽限窗口：这段时间只同步状态、不触发动作
    private var wakeGraceUntil: Date?

    private let debounce: TimeInterval = 0.35

    // ---- 状态帧：判定规则 + 帧记录
    /// 判定规则来自 config.json；没配就用内置的 K70 Pro Mini 默认
    private var classifier: KeyboardFrameClassifier
    /// 收到的**每一帧**都进这里（含没匹配上的）—— 体检/诊断/回放都靠它
    private let frameLog = KeyboardFrameLog()
    /// 已经提示过的"未匹配帧"种类（避免刷屏）
    private var loggedUnknownFrames = Set<String>()

    // ---- 体检（"这把键盘支不支持抢跑"）的窗口计数
    //      结果类型 KeyboardProbeReport 定义在 KeyboardFrameRules.swift（纯函数，可离线测）
    private var probeRunning = false
    private var probeFrames = 0
    private var probeWindows = 0
    private var probeMac = 0
    private var probeUnmatched: [String: Int] = [:]
    private var probeOwnershipChanges = 0

    // ---- 采集（学习向导用）
    private var captureActive = false
    private var captureFrames: [String] = []
    /// 最近一次「规则认得」的帧的时间（运行期自检 / 档位显示用）
    private var lastMatchedFrameAt: Date?

    init() {
        classifier = TraiectusConfig.shared.frameClassifier
    }

    // ---------------------------------------------------------------- 生命周期

    func start(udpPort: UInt16 = 45790) {
        self.udpPort = udpPort
        startKeywatch()
        startUDP()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
        log?("[联动] 已启动（检测：kvm-keywatch；抢跑：UDP \(udpPort)"
             + "；状态帧规则：\(TraiectusConfig.shared.frameRuleSource)）")
    }

    func stop() {
        ticker?.cancel(); ticker = nil
        udpSource?.cancel(); udpSource = nil
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
        log?("[联动] 已停止")
    }

    /// 只重启 kvm-keywatch 子进程（换键盘厂商 ID 之后用）。
    /// 不动 UDP、不动 ticker、不动已判定的键盘归属 —— 只是让新 VID 立刻生效。
    func restartKeywatch() {
        queue.async { [weak self] in
            guard let self else { return }
            if let p = self.proc, p.isRunning { p.terminate() }
            self.proc = nil
            self.startKeywatch()
        }
    }

    // ---------------------------------------------------------------- 系统睡眠 / 唤醒

    /// 系统即将睡眠：**立刻**把屏幕与鼠标控制权交给 Windows。
    ///
    /// 为什么不由"键盘离开 Mac"来触发：Mac 睡下去时蓝牙链路会掉，联动会把它误判成
    /// "键盘走了"，那要等入睡约 1.4 秒后才动作 —— Windows 那边的鼠标就卡着。
    /// 改成监听系统事件后，按 ⌘1 的同一刻就交接出去。
    func handleWillSleep() {
        queue.async { [weak self] in
            guard let self else { return }
            self.log?("[联动] 系统即将睡眠 → 把屏幕与鼠标交给 Windows")
            self.isSleeping = true
            self.sleepStartedAt = Date()
            self.perform(.windows, why: "系统即将睡眠", force: true)
        }
    }

    /// 系统已唤醒：按键盘的**真实归属**决定谁来接管。
    /// 键盘还在 Mac 上 → 切回 HDMI + MODE Mac；不在 → 什么都不做，
    /// 交给后续的键盘事件（用户可能睡前就把键盘切走了）。
    func handleDidWake() {
        queue.async { [weak self] in
            guard let self else { return }
            self.endSleepWindow()
            self.pending = self.detectedState
            self.lastActed = self.detectedState
            if self.keyboardOnMac {
                self.log?("[联动] 系统已唤醒：键盘在 Mac 上 → 切回 Mac")
                self.perform(.mac, why: "系统唤醒", force: true)
            } else {
                self.log?("[联动] 系统已唤醒：键盘不在 Mac 上 → 不做动作")
            }
        }
    }

    /// 结束睡眠窗口：清掉"正在睡"的标记，并开一个宽限窗口 ——
    /// 唤醒后 IOKit 会把睡眠期间漏掉的 REMOVE/ADD 一起补发，
    /// 宽限窗口里只同步状态、不触发动作，免得刚醒就把屏幕又切走。
    private func endSleepWindow() {
        isSleeping = false
        wakeGraceUntil = Date().addingTimeInterval(3)
        hint = nil
        changedAt = Date()
    }

    // ---------------------------------------------------------------- kvm-keywatch

    private func resolve(_ rel: String) -> String? {
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        if let base = exe?.appendingPathComponent(rel) {
            let p = base.standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let expanded = (rel as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
    }

    private func startKeywatch() {
        guard let path = firstExecutable([TraiectusConfig.shared.keywatchPath],
                                         Self.keywatchRelativePaths) else {
            log?("[联动] ⚠ 找不到 kvm-keywatch（联动不可用）—— 可在 config.json 的 tools.keywatch 指定路径")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        // 键盘的厂商 ID 也是可配的（换品牌键盘就改这里，不用重编）
        p.arguments = ["--vid", TraiectusConfig.shared.keyboardVendorID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        do {
            try p.run()
            proc = p
        } catch {
            log?("[联动] ⚠ kvm-keywatch 启动失败：\(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<nl]
            readBuffer = readBuffer[(nl + 1)...]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            handleKeywatchLine(line)
        }
    }

    private func handleKeywatchLine(_ line: String) {
        guard !line.isEmpty, !line.hasPrefix("#") else { return }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 3 else { return }
        let kind = parts[1].lowercased()
        let transport = parts[2].split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""

        if kind.hasPrefix("add") { transports.insert(transport) }
        else if kind.hasPrefix("remov") { transports.remove(transport) }
        else if kind == "display" { return }     // 显示器事件：只用于观察，不参与判断
        else { return }
    }

    private var transports = Set<String>()

    private var detectedState: String? {
        if transports.contains(where: { $0.contains("bluetooth") }) { return "bt" }
        if transports.contains(where: { $0.contains("usb") }) { return "usb" }
        return nil
    }

    // ---------------------------------------------------------------- 抢跑（Windows 桥接）

    private func startUDP() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log?("[联动] ⚠ UDP socket 创建失败"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = udpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            log?("[联动] ⚠ UDP \(udpPort) 绑定失败（抢跑不可用，其余功能正常）")
            close(fd)
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readUDP(fd) }
        src.resume()
        udpSource = src
        udpFD = fd
    }

    private func readUDP(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 256)
        // 用 recvfrom 而不是 recv：来源地址是**免费**的线索 —— Windows 每 2 秒发一次
        // HB 心跳，那个包的源地址就是它的 IP。以前用 recv 把它扔了。
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
            }
        }
        guard n > 0 else { return }
        if let cb = onPeerSeen, fromLen >= socklen_t(MemoryLayout<sockaddr_in>.size) {
            var a = from.sin_addr
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            if !ip.isEmpty { cb(ip) }
        }
        let text = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased() == "HB" { return }        // 桥接心跳：只用于维持防火墙回包通道
        // 形如 "KEY 00 00 01 36 00 02 00 00"
        let upper = text.uppercased()
        guard upper == "KEY" || upper.hasPrefix("KEY ") else { return }

        // ① 先记录：不管认不认识，都进环形缓冲
        //    （以前这里对不上的帧直接 return，于是"收到了帧但没匹配上"这件事
        //      在日志里根本看不见 —— 体检与诊断报告都靠这一步）
        let side = classifier.side(forFrameText: text)
        frameLog.record(hex: frameHexOnly(text), side: side)
        if captureActive { captureFrames.append(frameHexOnly(text)) }

        // ② 再判定（顺手记进体检计数）
        probeFrames += 1
        switch side {
        case "windows":
            probeWindows += 1
            lastMatchedFrameAt = Date()
            if let at = lastMatchedFrameAt { onMatchedFrame?(at) }
            handleHint(.windows)
        case "mac":
            probeMac += 1
            lastMatchedFrameAt = Date()
            if let at = lastMatchedFrameAt { onMatchedFrame?(at) }
            handleHint(.mac)
        default:
            probeUnmatched[frameHexOnly(text), default: 0] += 1
            logUnknownFrameIfNeeded(text)
        }
    }

    /// "KEY 00 00 …" → "00 00 …"（落缓冲时去掉前缀，报告里更好读）
    private func frameHexOnly(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        if let first = tokens.first, first.lowercased() == "key" { tokens.removeFirst() }
        return tokens.joined(separator: " ").lowercased()
    }

    /// 收到但没有任何规则认得的帧：每种只提示一次（最多 20 种），避免刷屏。
    /// 这是"读到了帧、但规则不认"的唯一可见信号。
    private func logUnknownFrameIfNeeded(_ text: String) {
        guard classifier.unknownPolicy.lowercased() != "ignore" else { return }
        let hex = frameHexOnly(text)
        guard !loggedUnknownFrames.contains(hex) else { return }
        loggedUnknownFrames.insert(hex)
        guard loggedUnknownFrames.count <= 20 else {
            if loggedUnknownFrames.count == 21 {
                log?("[联动] ⚠ 未匹配的帧已超过 20 种，后续不再逐条提示（帧仍在缓冲里）")
            }
            return
        }
        // 区分"能解析但规则不认"和"根本解析不出来" —— 排查时含义完全不同
        log?(KeyboardFrameRule.bytes(from: hex) != nil
             ? "[联动] ⚠ 收到未匹配的状态帧：\(hex)（规则里没有它，已记录；可用诊断报告导出全部）"
             : "[联动] ⚠ 收到无法解析的帧：\(hex)（不是十六进制字节？已记录）")
    }

    /// 诊断用：最近收到的帧（含未匹配）
    func recentFrames() -> [KeyboardFrameLog.Entry] { frameLog.snapshot() }

    /// 规则热更新（学习向导保存新规则后调用，不用重启 app）
    func reloadRules() {
        queue.async { [weak self] in
            guard let self else { return }
            self.classifier = TraiectusConfig.shared.frameClassifier
            self.log?("[键盘] 规则已重新加载：\(TraiectusConfig.shared.frameRuleSource)")
        }
    }

    /// 键盘此刻在不在 Mac 上（线程安全的快照，给界面用）
    func snapshotKeyboardOnMac() -> Bool {
        queue.sync { detectedState != nil }
    }

    /// 采集一段时间的帧（学习向导用）：到点回调收集到的帧（hex 文本，不含 KEY 前缀）
    func capture(seconds: Double, completion: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.captureActive else { return }
            self.captureActive = true
            self.captureFrames = []
            self.log?("[键盘学习] 开始采集 \(Int(seconds)) 秒…")
            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.captureActive = false
                let frames = self.captureFrames
                self.captureFrames = []
                self.log?("[键盘学习] 采集结束：收到 \(frames.count) 帧")
                DispatchQueue.main.async { completion(frames) }
            }
        }
    }

    private func handleHint(_ side: Side) {
        // 睡眠窗口里不抢跑：那段时间的键盘事件都是"Mac 睡过去了"的余波
        guard !isSleeping else { return }
        guard isOnline?() ?? true else {
            // 离线：不静默消费掉这个信号，也不推进"已切"状态，
            // 这样恢复后仍能从真实归属重新推导。
            log?("[联动] ⏸ Windows 端未运行，跳过抢跑动作（\(side == .windows ? "去 Windows" : "回 Mac")）")
            return
        }
        switch side {
        case .windows where lastActed != nil:
            // 键盘还在 Mac 上，但 Windows 已经看到它过来了 → 抢跑
            log?("[联动] ⚡ Windows 抢跑：键盘正在去 Windows")
            perform(.windows, why: "抢跑")
            lastActed = nil
            pending = nil
            hint = .windows
            hintDeadline = Date().addingTimeInterval(8)
        case .mac where lastActed == nil:
            log?("[联动] ⚡ Windows 抢跑：键盘正在回 Mac")
            perform(.mac, why: "抢跑")
            lastActed = "bt"
            pending = "bt"
            hint = .mac
            hintDeadline = Date().addingTimeInterval(8)
        default:
            break
        }
    }

    // ---------------------------------------------------------------- 主循环

    private func tick() {
        let now = detectedState

        // 睡眠窗口：键盘的蓝牙链路会掉（实测还会短暂跳去 SLIPSTREAM 再跳回来），
        // 那是"Mac 睡过去了"，不是"键盘走了" —— 这段时间只同步状态、绝不动作。
        // 退出这条分支只有一条路：didWake 通知（或下面那个看门狗）。
        if isSleeping {
            pending = now
            lastActed = now
            changedAt = Date()
            // 看门狗：睡眠被取消、或 didWake 通知没送到时，别让联动一直"失聪"。
            // 真睡过去的话 app 是冻结的，这个判断会在醒来后才跑到 —— 那时
            // endSleepWindow 已经被 didWake 调过了，这里不会重复触发。
            if Date().timeIntervalSince(sleepStartedAt) > 60 {
                log?("[联动] 睡眠窗口超过 60 秒仍未收到唤醒通知 → 按「已结束」处理")
                endSleepWindow()
            }
            return
        }
        // 唤醒后的宽限窗口：只同步状态，不触发动作
        if let until = wakeGraceUntil {
            if Date() < until {
                pending = now
                lastActed = now
                changedAt = Date()
                return
            }
            wakeGraceUntil = nil
        }

        if let h = hint {
            let matched = (h == .windows && now == nil) || (h == .mac && now != nil)
            if matched { hint = nil }
            else if Date() > hintDeadline {
                hint = nil
                // 抢跑说"键盘正朝这边来"，但等了 8 秒也没等到它真的出现。
                // 最常见的原因是**键盘的蓝牙没连上 Mac**（配对失效 / 电量低 / 键盘自己回落 2.4G）。
                // 紧接着下面那段会按"实际归属"纠正回来（通常是退回 Windows）——
                // 以前只打一句"键盘离开 Mac → 去 Windows"，看不出真实原因，很容易被当成灵异现象。
                log?("[联动] ⚠️ 抢跑后 8 秒没等到键盘"
                     + (h == .mac ? "回到 Mac（蓝牙没连上？）" : "离开 Mac")
                     + " → 按实际归属纠正（下面这条是纠正结果，不是新的按键）")
                // 运行期自检：把这次"判定 ≠ 实际"连同最近的帧一起交出去落盘
                let expect = (h == .mac) ? "回 Mac" : "去 Windows"
                let iso = ISO8601DateFormatter()
                onMismatch?(KeyboardDiagnosticReport(
                    when: Date(),
                    summary: "抢跑判定与实际归属不一致：抢跑说「键盘正在\(expect)」，但 8 秒内没等到",
                    detail: [
                        "抢跑方向：\(expect)",
                        "实际归属：键盘\(now == nil ? "不在 Mac 上" : "在 Mac 上")",
                        "最近一次命中规则的帧：\(lastMatchedFrameAt.map { iso.string(from: $0) } ?? "（从未）")",
                        "常见原因：键盘的蓝牙没连上 Mac（配对失效 / 电量低 / 键盘自己回落 2.4G）",
                    ],
                    rules: classifier.rules.map { rule in
                        "\(rule.side)：\(KeyboardRuleBuilder.hexString(rule.bytes))"
                            + (rule.mask.contains(0x00) ? "  mask \(KeyboardRuleBuilder.hexString(rule.mask))" : "")
                    },
                    frames: frameLog.snapshot()))
            }
            else { return }
        }

        if now != pending {
            pending = now
            changedAt = Date()
            return
        }
        guard pending != lastActed, Date().timeIntervalSince(changedAt) >= debounce else { return }

        let wasOnMac = lastActed != nil
        lastActed = pending
        if wasOnMac && pending == nil {
            probeOwnershipChanges += 1
            log?("[联动] 键盘离开 Mac → 去 Windows")
            perform(.windows, why: "键盘归属")
        } else if !wasOnMac && pending != nil {
            probeOwnershipChanges += 1
            log?("[联动] 键盘回到 Mac")
            perform(.mac, why: "键盘归属")
        }
    }

    /// 体检：开一个 N 秒的窗口，数"收到几帧、命中几条规则、期间键盘真的切了几次"。
    /// 这里只给数字，结论文案由 KeyboardProbeReport 自己算（可离线测）。
    func runProbe(seconds: Double = 15, completion: @escaping (KeyboardProbeReport) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.probeRunning else { return }
            self.probeRunning = true
            self.probeFrames = 0
            self.probeWindows = 0
            self.probeMac = 0
            self.probeUnmatched = [:]
            self.probeOwnershipChanges = 0
            self.log?("[键盘体检] 开始，\(Int(seconds)) 秒 —— 请用键盘上的切换快捷键：去 Win / 回 Mac 各一次")

            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.probeRunning = false
                let unmatched = self.probeUnmatched
                    .map { (hex: $0.key, count: $0.value) }
                    .sorted { $0.count > $1.count }
                let report = KeyboardProbeReport(seconds: seconds,
                                                 frames: self.probeFrames,
                                                 matchedWindows: self.probeWindows,
                                                 matchedMac: self.probeMac,
                                                 unmatched: unmatched,
                                                 ownershipChanges: self.probeOwnershipChanges,
                                                 slept: self.isSleeping)
                self.log?("[键盘体检] 结束：收到 \(report.frames) 帧"
                          + "（去 Win \(report.matchedWindows) / 回 Mac \(report.matchedMac)）"
                          + "，未匹配 \(report.unmatched.count) 种"
                          + "，期间键盘切换 \(report.ownershipChanges) 次")
                DispatchQueue.main.async { completion(report) }
            }
        }
    }

    // ---------------------------------------------------------------- 动作

    /// `force = true`：即便 Windows 端离线，也要做**本地**动作（切屏 + 光标居中）。
    /// 唤醒后就靠它把画面收回 Mac —— 那时候 Windows 往往还没重连上，
    /// 而"切回 HDMI"是本机的事，不该被对端在线与否挡住。MODE 仍然只在对端在线时发，
    /// 离线的话由恢复后的 syncAfterRecovery() 补上。
    private func perform(_ side: Side, why: String, force: Bool = false) {
        let online = isOnline?() ?? true
        if !online && !force {
            log?("[联动] ⏸ Windows 端未运行，跳过："
                 + "切屏(→\(displayTarget(side)))"
                 + (side == .windows ? " + MODE Win" : " + MODE Mac"))
            return
        }
        switchMonitor(side)
        centerCursor()
        if online {
            onMouseSide?(side, why)
        } else {
            log?("[联动] ⏸ Windows 端未运行：只做本地切屏与光标居中，MODE 等恢复后自动同步")
        }
    }

    /// Windows 端离线（TCP 掉线 + 心跳超时）时复位联动内部状态：
    /// 先无条件重新关联鼠标（防 warp 后解绑导致光标卡死），再清过渡态。
    /// **不清本地键盘归属** —— 那是物理事实，恢复后要靠它重新推导。
    func resetOnOffline() {
        CGAssociateMouseAndMouseCursorPosition(1)      // P3：保险，最先做
        hint = nil
        hintDeadline = Date()
        pending = detectedState
        changedAt = Date()
        lastSource = nil
        log?("[联动] ♻ Windows 端离线，联动状态已复位（本地键盘归属保留：\(describeState(detectedState))）")
    }

    /// Windows 端恢复（重连成功并收到首个 PONG）时做一次状态同步：
    /// 键盘现在挂在 Mac 上 → 主动发一次 `MODE Mac`，让服务端与 Mac 保持一致；
    /// 键盘不在 Mac（用户可能在 Windows 侧）→ 什么都不做，也不切屏。
    func syncAfterRecovery() {
        guard isOnline?() ?? true else { return }
        if detectedState != nil {
            log?("[联动] ⟳ Windows 端已恢复：键盘在 Mac 上，主动同步一次鼠标控制权")
            onMouseSide?(.mac, "恢复同步")
        } else {
            log?("[联动] ⟳ Windows 端已恢复：键盘不在 Mac 上（用户可能在 Windows 侧），不做动作")
        }
    }

    private var lastSource: String?

    private func describeState(_ s: String?) -> String {
        switch s {
        case "bt": return "在 Mac 上（蓝牙）"
        case "usb": return "在 Mac 上（USB 有线）"
        default: return "不在 Mac 上"
        }
    }

    private func switchMonitor(_ side: Side) {
        // 输入源编号走配置：不同显示器不一样（15 = DP-1、17 = HDMI-1 是本机这台 ASUS 的值）
        let config = TraiectusConfig.shared
        let value = (side == .windows) ? config.windowsDisplayInput : config.macDisplayInput
        // 日志里**不能写死 "DP"/"HDMI"**：接线反过来就说反话了。
        // 改成显示真实编号，编号落在标准表里时补上名字（见 DisplaySwitch.inputName）。
        let target = displayTarget(side)
        if let m1 = firstExecutable([config.m1ddcPath], Self.m1ddcRelativePaths) {
            run([m1, "set", "input", value], label: "m1ddc", target: target)
            return
        }
        if let dwc = firstExecutable([config.dwcPath], Self.dwcCandidates) {
            run([dwc, "set", "InputSource", value], label: "dwc", target: target)
            return
        }
        log?("[联动] ⚠ 找不到 m1ddc / dwc，跳过切屏 —— 可在 config.json 的 tools 里指定路径")
    }

    /// 日志里描述"切到哪一边"：用**实际配置的编号**，不再假设 Mac=HDMI、Windows=DP
    private func displayTarget(_ side: Side) -> String {
        let config = TraiectusConfig.shared
        let value = (side == .windows) ? config.windowsDisplayInput : config.macDisplayInput
        let name = DisplaySwitch.inputName(value)
        let label = name.isEmpty ? value : "\(value) \(name)"
        return (side == .windows ? "Windows " : "Mac ") + label
    }

    /// 先看 config 里明确指定的路径，再按内置候选顺序找
    private func firstExecutable(_ overrides: [String?], _ candidates: [String]) -> String? {
        for path in overrides.compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates.compactMap { resolve($0) }.first
    }

    private func run(_ args: [String], label: String, target: String) {
        guard FileManager.default.isExecutableFile(atPath: args[0]) else {
            log?("[联动] ⚠ 找不到 \(label)，跳过切屏")
            return
        }
        // 唤醒那一瞬间 DDC 偶尔会失败（实测：退出码 1、20 ms 就返回，紧接着重试就成功）。
        // 失败必须重试 —— "醒了但屏幕没跟着回来"是这套流程里最难受的故障。
        var status: Int32 = -1
        var ms: Double = 0
        var attempt = 0
        while attempt < 3 {
            attempt += 1
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let t0 = Date()
            do {
                try p.run()
                p.waitUntilExit()
                ms = Date().timeIntervalSince(t0) * 1000
                status = p.terminationStatus
            } catch {
                log?("[联动] ⚠ 切屏失败（\(label)）：\(error.localizedDescription)")
                return
            }
            if status == 0 || attempt == 3 { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        log?(String(format: "[联动] 屏幕 → %@（%@ %.0f ms，退出码 %d%@）",
                    target, label, ms, status,
                    attempt > 1 ? "，重试\(attempt - 1)次" : ""))
    }

    private func centerCursor() {
        let b = CGDisplayBounds(CGMainDisplayID())
        let p = CGPoint(x: b.origin.x + b.size.width / 2, y: b.origin.y + b.size.height / 2)
        let err = CGWarpMouseCursorPosition(p)
        // warp 会把光标与鼠标解绑；不补这一句，指针会卡住/像消失
        CGAssociateMouseAndMouseCursorPosition(1)
        log?("[联动] Mac 光标 → 屏幕中心（\(Int(p.x)), \(Int(p.y))，warp=\(err.rawValue)）")
    }
}
