// ============================================================================
//  KeyboardFrameRules —— 键盘状态帧的「判定规则」与「帧记录」
// ----------------------------------------------------------------------------
//  为什么要把规则抽出来：以前判定写死在 KeyboardLink 里（mode == "02" → 去 Windows），
//  只有 K70 Pro Mini 能用。现在规则来自配置，任何键盘都可以由用户自己"教"出来。
//  设计见 docs/design/2026-09-30-键盘状态帧检测与验证.md
//
//  两个组件：
//    · KeyboardFrameRule / KeyboardFrameClassifier —— 纯函数，能用离线样本回放测试
//      （第 1 步：规则配置化）
//    · KeyboardFrameLog —— 环形缓冲：收到的**每一帧**都记下来，包括没匹配上的
//      （第 4 步：先记录再判定 —— 没有它，"收到了帧但没匹配"在日志里根本看不见）
// ============================================================================

import Foundation

// MARK: - 单条规则

struct KeyboardFrameRule {
    /// 命中后判定为哪一侧："windows" / "mac"
    let side: String
    /// 要比对的字节（例如 "00 00 01 36 00 02"）
    let bytes: [UInt8]
    /// 哪些字节参与比对：0xFF = 必须相等，0x00 = 忽略（也支持 0x0F 这类部分掩码）
    let mask: [UInt8]
    let note: String?

    init?(side: String, match: String, mask: String? = nil, note: String? = nil) {
        guard let parsed = Self.bytes(from: match), !parsed.isEmpty else { return nil }
        self.side = side.lowercased()
        self.bytes = parsed
        if let mask, let m = Self.bytes(from: mask), m.count == parsed.count {
            self.mask = m
        } else {
            self.mask = [UInt8](repeating: 0xFF, count: parsed.count)   // 没给 mask = 全都要比
        }
        self.note = note
    }

    /// 帧比分前先比长度：帧比规则短一定不命中
    func matches(_ frame: [UInt8]) -> Bool {
        guard frame.count >= bytes.count else { return false }
        for i in 0..<bytes.count where mask[i] != 0 {
            if (frame[i] & mask[i]) != (bytes[i] & mask[i]) { return false }
        }
        return true
    }

    /// "00 00 01 36" / "0x00 0x00 …" / "00-00-01" 都能解析；有任何一个字节解析不了就返回 nil
    static func bytes(from hex: String) -> [UInt8]? {
        let parts = hex
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !parts.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            var text = String(part)
            if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
            guard let value = UInt8(text, radix: 16) else { return nil }
            out.append(value)
        }
        return out
    }
}

// MARK: - 一条帧 → 哪一侧

struct KeyboardFrameClassifier {
    let rules: [KeyboardFrameRule]
    /// 命中不了任何规则时怎么办："log"（默认，记一笔但不动作）/ "ignore"
    let unknownPolicy: String

    func side(for frame: [UInt8]) -> String? {
        for rule in rules where rule.matches(frame) { return rule.side }
        return nil
    }

    /// 直接吃一行帧文本（可带 "key" 前缀，也能只有 hex）
    func side(forFrameText text: String) -> String? {
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let first = tokens.first, first.lowercased() == "key" { tokens.removeFirst() }
        guard let frame = KeyboardFrameRule.bytes(from: tokens.joined(separator: " ")) else { return nil }
        return side(for: frame)
    }

    // ---- 内置默认：Corsair K70 Pro Mini（2.4G 接收器 FF42/02 的状态帧）
    //      用户没配规则时用它，行为与"规则还没配置化之前"完全一致。
    //
    //      ⚠️ 这里**不写 mask**（= 每个字节都要比）。写过一次 mask="…00"，
    //      结果把第 6 字节（方向字节）也忽略了，两条规则命中同一批帧 —— 被离线测试抓到。
    //      经验：区分方向的那个字节，掩码必须是 ff。
    static let k70Default: [KeyboardFrameRule] = [
        KeyboardFrameRule(side: "windows", match: "00 00 01 36 00 02",
                          note: "K70 Pro Mini：键盘去 SLIPSTREAM（去 Windows）")!,
        KeyboardFrameRule(side: "mac", match: "00 00 01 36 00 00",
                          note: "K70 Pro Mini：键盘回蓝牙（回 Mac）")!,
    ]
}

// MARK: - 帧环形缓冲（先记录、再判定）

/// 收到的每一帧都记下来，含没匹配上的 —— 体检 / 诊断报告 / 回放测试都靠它。
/// UDP 回调在 KeyboardLink 自己的队列上，导出可能从主线程来，所以加锁。
final class KeyboardFrameLog {
    struct Entry {
        let at: Date
        let hex: String
        let side: String?       // nil = 没匹配到任何规则
    }

    private var entries: [Entry] = []
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int = 200) { self.limit = limit }

    func record(hex: String, side: String?, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(at: at, hex: hex, side: side))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }

    /// 没匹配上任何规则的帧（去重）—— 诊断用
    func unmatchedSummary() -> [(hex: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in snapshot() where entry.side == nil {
            if counts[entry.hex] == nil { order.append(entry.hex) }
            counts[entry.hex, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }
}

// MARK: - 体检结果与结论

/// 一次「键盘体检」的结果：窗口内收到了什么、规则认出了什么、键盘真的切了几次。
///
/// 结论文案（`verdict` / `detail`）是**直接给用户看的**，所以也放在这个纯函数文件里 ——
/// 这样六种分支都能用离线测试覆盖，不用真的点界面按钮。
struct KeyboardProbeReport {
    let seconds: Double
    let frames: Int                 // 窗口内收到的帧总数
    let matchedWindows: Int
    let matchedMac: Int
    let unmatched: [(hex: String, count: Int)]
    let ownershipChanges: Int       // 窗口内键盘归属变化次数（真值活动）
    let slept: Bool                 // 窗口内系统睡过 → 样本会偏少

    var verdict: String {
        if matchedWindows > 0 && matchedMac > 0 {
            return "支持抢跑（两个方向都能认）"
        }
        if matchedWindows > 0 {
            return "支持抢跑（只认「去 Win」方向 —— 这是常态，提前量只在这个方向）"
        }
        if matchedMac > 0 {
            return "只认「回 Mac」方向（少见；该方向本来就没有提前量）"
        }
        if frames > 0 {
            return "不支持抢跑（收到了帧，但现有规则一条都认不出）"
        }
        if ownershipChanges == 0 {
            return "这次没检测到键盘切换 —— 再跑一次，期间用键盘上的切换快捷键去 Win / 回 Mac 各一次"
        }
        return "读不到状态帧 → 这把键盘用不了抢跑"
    }

    /// 界面上只显示这一句：结论 + 收到几帧、两个方向各几条。
    /// 细节（没认出的帧、Mac 自己发现的切换次数）留在 `detail` 里进日志和诊断报告 ——
    /// 那些数字对用户是噪音，而且像"Mac 自己发现的切换 0 次"这种**抢跑越灵越接近 0**，
    /// 摆在界面上只会让人以为键盘没动（实测用户就问了这句）。
    var concise: String {
        "\(verdict)\n\(Int(seconds)) 秒收到 \(frames) 帧"
        + "（去 Win \(matchedWindows) / 回 Mac \(matchedMac)）"
    }

    var detail: String {
        var lines: [String] = []
        lines.append("窗口 \(Int(seconds)) 秒；收到状态帧 \(frames) 条"
                     + "（去 Win \(matchedWindows) / 回 Mac \(matchedMac)）")
        if !unmatched.isEmpty {
            let top = unmatched.prefix(3).map { "\($0.hex)×\($0.count)" }.joined(separator: "、")
            lines.append("没被规则认出的帧：\(top)")
        }
        // 这个数只算"Mac 自己发现的切换"：抢跑那条路会先把状态设成目标值，
        // 之后蓝牙检测就看不到差值了 —— 所以**抢跑越灵，这个数越接近 0**，
        // 原来写成"键盘真的切了 N 次"会让人以为键盘没动（实际屏幕都跟着切了）。
        lines.append("Mac 自己发现的切换：\(ownershipChanges) 次（抢跑先认出来的那次不计）")
        if slept {
            lines.append("⚠️ 窗口内系统睡过，样本会偏少，建议再跑一次")
        }
        if frames == 0 && ownershipChanges > 0 {
            lines.append("仍然能用：走蓝牙方案 —— 去 Win 方向慢约 1.7 秒，回 Mac 方向本来就一样快，")
            lines.append("功能完全一样。想再确认一次，可以把接收器换到另一个 USB 口重试（扩展坞有时会挡掉厂商接口）。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 学习：从两组样本里算出规则

/// 学习结果。失败时 `failure` 有值、`rules` 为空 —— **失败原因要具体**，
/// 因为用户下一步该做什么完全取决于原因（换接口 / 重录 / 换键盘）。
struct KeyboardRuleBuildResult {
    var rules: [KeyboardFrameRule] = []
    var maskHex: String = ""
    var failure: String?
    var detail: String = ""
    /// 失败原因的**结构化标识** —— 界面文案由客户端本地化（见 TraiectusClient）。
    /// `failure` / `detail` 保持中文原文：日志和离线测试都按中文对账。
    var failureKind: FailureKind = .none
    /// 界面用：能解析成十六进制的条数（`detail` 里有同样信息，这里给结构化值好本地化）
    var parsedCounts: (a: Int, b: Int) = (0, 0)
    /// 界面用：区分位（**下标**，显示时 +1）；`detail` 里的那句同样信息
    var discriminatingBytes: [Int] = []

    var isOK: Bool { failure == nil && !rules.isEmpty }

    enum FailureKind {
        case none
        case noFramesBoth          // 两侧都没收到能解析的帧
        case noFramesSideA         // A 组（去 Windows 那侧）没收到
        case noFramesSideB         // B 组（回 Mac 那侧）没收到
        case tooShort
        case representativeFailed
        case notDistinguishable
        case ruleCreationFailed
    }
}

enum KeyboardRuleBuilder {

    /// 从两组样本里学规则：
    ///   `framesA` 是"切到 sideA"时收到的帧（例如切到 Windows 时收到了什么）
    ///   `framesB` 是"切回 sideB"时收到的帧
    ///
    /// 算法（纯集合运算，可以离线测）：
    ///   1. 每组取**出现次数最多**的那条当代表
    ///   2. 逐字节看：**每组内部各自恒定**的字节 → 掩码 ff（要比）；否则 → 00（忽略，
    ///      因为它在组内就会变，拿来比会误判）
    ///   3. 两组都恒定、且**彼此不同**的字节 = 区分位；一个都没有就失败
    static func build(framesA: [String], sideA: String,
                      framesB: [String], sideB: String) -> KeyboardRuleBuildResult {
        var result = KeyboardRuleBuildResult()

        let parsedA = framesA.compactMap { KeyboardFrameRule.bytes(from: $0) }
        let parsedB = framesB.compactMap { KeyboardFrameRule.bytes(from: $0) }
        guard !parsedA.isEmpty, !parsedB.isEmpty else {
            result.failure = parsedA.isEmpty && parsedB.isEmpty
                ? "两侧都没有收到能解析的帧"
                : (parsedA.isEmpty ? "「\(sideA)」那一侧没收到能解析的帧"
                                   : "「\(sideB)」那一侧没收到能解析的帧")
            result.failureKind = parsedA.isEmpty && parsedB.isEmpty
                ? .noFramesBoth
                : (parsedA.isEmpty ? .noFramesSideA : .noFramesSideB)
            result.detail = "收到 A 组 \(framesA.count) 条、B 组 \(framesB.count) 条"
                + "（能解析成十六进制的：\(parsedA.count) / \(parsedB.count)）"
            result.parsedCounts = (parsedA.count, parsedB.count)
            return result
        }

        let shortest = min(parsedA.map(\.count).min() ?? 0, parsedB.map(\.count).min() ?? 0)
        guard shortest >= 1 else {
            result.failure = "帧长度太短，没法比对"
            result.failureKind = .tooShort
            return result
        }
        let length = min(shortest, 8)      // 只关心前 8 字节（和转发给 Mac 的内容一致）

        func representative(_ frames: [String]) -> [UInt8] {
            var counts: [String: Int] = [:]
            for f in frames { counts[f.lowercased().replacingOccurrences(of: "key ", with: ""), default: 0] += 1 }
            // 并列时取字典序最小的那条，保证同一批样本每次跑出同一个结果
            var best: (key: String, count: Int)?
            for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
                if best == nil || count > (best?.count ?? 0) { best = (key, count) }
            }
            return KeyboardFrameRule.bytes(from: best?.key ?? "") ?? []
        }
        func byteConstant(_ frames: [[UInt8]], _ index: Int) -> UInt8? {
            let values = Set(frames.map { $0[index] })
            return values.count == 1 ? values.first : nil
        }

        let repA = Array(representative(framesA).prefix(length))
        let repB = Array(representative(framesB).prefix(length))
        guard repA.count == length, repB.count == length else {
            result.failure = "取代表帧失败"
            result.failureKind = .representativeFailed
            return result
        }

        var mask = [UInt8](repeating: 0x00, count: length)
        var discriminating: [Int] = []
        for i in 0..<length {
            guard let a = byteConstant(parsedA, i), let b = byteConstant(parsedB, i) else { continue }
            mask[i] = 0xff
            if a != b { discriminating.append(i) }
        }

        guard !discriminating.isEmpty else {
            result.failure = "两组样本区分不开"
            result.failureKind = .notDistinguishable
            result.detail = "逐字节比过：没有任何一个字节是「两侧各自恒定、且彼此不同」。\n"
                + "常见原因：接口选错了（比如读到了 FF42/01 而不是 FF42/02）；"
                + "两次采集其实是同一个方向；或者这把键盘不吐方向信息。"
            return result
        }

        // 规则只保留到"最后一个区分位"为止：更长的部分对区分没有贡献，只会让规则更容易过拟合
        // （K70 的帧尾两个 00 就不必进规则 —— 这样学出来正好是内置默认那 6 个字节）
        let ruleLength = (discriminating.max() ?? 0) + 1
        let finalMask = Array(mask.prefix(ruleLength))
        let maskHex = hexString(finalMask)
        guard let ruleA = KeyboardFrameRule(side: sideA, match: hexString(Array(repA.prefix(ruleLength))), mask: maskHex),
              let ruleB = KeyboardFrameRule(side: sideB, match: hexString(Array(repB.prefix(ruleLength))), mask: maskHex) else {
            result.failure = "生成规则失败"
            result.failureKind = .ruleCreationFailed
            return result
        }

        result.rules = [ruleA, ruleB]
        result.maskHex = maskHex
        result.discriminatingBytes = discriminating
        result.detail = "区分位：第 " + discriminating.map { String($0 + 1) }.joined(separator: "、")
            + " 字节；掩码 " + maskHex
        return result
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - 诊断报告（判定与实际归属不一致时落盘）

/// 一份可以直接贴到 issue 里的诊断报告：
/// 当时用的规则、最近收到的帧（含没匹配上的）、以及"抢跑说 X、实际是 Y"。
///
/// 为什么要有它：出了问题不再需要两台机器对着看日志 —— 帧序列和两个判定都在一个文件里。
struct KeyboardDiagnosticReport {
    let when: Date
    let summary: String
    var detail: [String]
    let rules: [String]
    let frames: [KeyboardFrameLog.Entry]

    var json: String {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "when": iso.string(from: when),
            "kind": "keyboard-diagnostic",
            "summary": summary,
            "detail": detail,
            "rules": rules,
            "frameCount": frames.count,
            "frames": frames.map { entry in
                [
                    "t": iso.string(from: entry.at),
                    "frame": entry.hex,
                    "verdict": entry.side ?? "unmatched",
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"报告序列化失败\"}"
        }
        return text
    }
}
