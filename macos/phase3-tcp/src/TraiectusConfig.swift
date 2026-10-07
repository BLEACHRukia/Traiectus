// ============================================================================
//  TraiectusConfig —— 外部配置文件：换硬件时只改这里，不用改代码、不用重编
// ----------------------------------------------------------------------------
//  位置：~/Library/Application Support/Traiectus/config.json
//  模板：仓库里的 config.example.json（复制过去改就行）
//
//  为什么要有它：这些东西以前是写死在代码里的，换一台显示器 / 换一把键盘 /
//  换个工具安装位置就得改源码重编 —— 对别人（和三个月后的自己）都不友好。
//
//  文件不存在 / 写错 / 只写了几个字段 → 全部回落到内置默认值，不影响运行。
//  改动会在启动时写进日志（`[配置] …`），出问题先看那一行。
// ============================================================================

import Foundation

struct TraiectusConfig: Codable {

    struct Display: Codable {
        /// DDC/CI 输入源编号：Mac 那一侧（默认 17 = HDMI-1）
        var macInput: String?
        /// DDC/CI 输入源编号：Windows 那一侧（默认 15 = DP-1）
        var windowsInput: String?
    }

    struct Keyboard: Codable {
        /// 监听哪家厂商的键盘设备（默认 Corsair = 0x1B1C）
        var vendorID: String?
        /// 键盘状态帧的检测配置。省略 = 用内置的 K70 Pro Mini 默认规则
        var detect: Detect?

        struct Detect: Codable {
            struct Interface: Codable {
                var vid: String?
                var usagePage: String?
                var usage: String?
                var reportBytes: Int?
            }
            struct Rule: Codable {
                var match: String
                var mask: String?
                var side: String
                var note: String?
            }
            /// 可读的厂商接口（体检 / 学习用；运行时判定不需要它）
            var interfaces: [Interface]?
            /// 判定规则：状态帧 → 哪一侧
            var rules: [Rule]?
            /// 命中不了任何规则时怎么办："log"（默认）/ "ignore"
            var unknownFramePolicy: String?
        }
    }

    struct Tools: Codable {
        /// 三个外部工具的位置。留空 = 用 app 内置的/自动查找。
        var keywatch: String?
        var m1ddc: String?
        var dwc: String?
    }

    struct Network: Codable {
        /// Windows 地址的默认值（留空 = 设置里不预填）
        var defaultHost: String?
    }

    var display: Display?
    var keyboard: Keyboard?
    var tools: Tools?
    var network: Network?

    // ---- 带默认值的读取口

    var macDisplayInput: String { display?.macInput ?? "17" }
    var windowsDisplayInput: String { display?.windowsInput ?? "15" }
    var keyboardVendorID: String { keyboard?.vendorID ?? "0x1B1C" }

    /// 键盘状态帧的判定器。配置里没写规则 → 用内置的 K70 默认（行为与配置化之前一致）
    var frameClassifier: KeyboardFrameClassifier {
        let configured = (keyboard?.detect?.rules ?? []).compactMap { rule in
            KeyboardFrameRule(side: rule.side, match: rule.match, mask: rule.mask, note: rule.note)
        }
        return KeyboardFrameClassifier(
            rules: configured.isEmpty ? KeyboardFrameClassifier.k70Default : configured,
            unknownPolicy: keyboard?.detect?.unknownFramePolicy ?? "log")
    }

    /// 规则从哪来（打日志、诊断用）
    var frameRuleSource: String {
        let configured = keyboard?.detect?.rules ?? []
        return configured.isEmpty ? "内置默认（K70 Pro Mini）" : "config.json（\(configured.count) 条）"
    }

    var keywatchPath: String? { expand(tools?.keywatch) }
    var m1ddcPath: String? { expand(tools?.m1ddc) }
    var dwcPath: String? { expand(tools?.dwc) }
    var defaultHost: String {
        (network?.defaultHost ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func expand(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    // ---- 加载

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Traiectus", isDirectory: true)
    static let path: String = directory.appendingPathComponent("config.json").path

    private static let sharedLock = NSLock()
    private static var sharedCache: TraiectusConfig?

    private static func loadFromDisk() -> TraiectusConfig {
        guard let data = FileManager.default.contents(atPath: path) else {
            return TraiectusConfig()          // 没有配置文件 = 全默认
        }
        do {
            return try JSONDecoder().decode(TraiectusConfig.self, from: data)
        } catch {
            NSLog("[Traiectus] 配置文件解析失败（忽略，改用默认值）：\(path) — \(error)")
            return TraiectusConfig()
        }
    }

    /// 进程内缓存一份（每次访问都读盘没必要）。
    ///
    /// ⚠️ 改完 config.json 之后**必须调 reload()**，否则拿到的还是启动时那份旧值 ——
    /// 表现就是"界面上说保存成功、实际不生效，重启才好"。学习类功能（键盘规则、
    /// 显示器输入源）都要注意这一点。
    static var shared: TraiectusConfig {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let c = sharedCache { return c }
        let c = loadFromDisk()
        sharedCache = c
        return c
    }

    /// 丢掉缓存，下次访问重新读盘
    static func reload() {
        sharedLock.lock(); defer { sharedLock.unlock() }
        sharedCache = loadFromDisk()
    }

    /// 启动时打一行日志，方便排查"到底用了哪套值"
    var summary: String {
        let loaded = FileManager.default.fileExists(atPath: Self.path)
        let source = loaded ? Self.path : "（没有配置文件，全部用默认值）"
        return "[配置] 显示器输入源 Mac=\(macDisplayInput) / Windows=\(windowsDisplayInput)"
             + "；键盘 VID=\(keyboardVendorID)；默认地址=\(defaultHost.isEmpty ? "未设置" : defaultHost)"
             + "；状态帧规则=\(frameRuleSource)"
             + "；来源：\(source)"
    }

    /// 把学到的规则写进配置文件（**保留其它字段**，用 JSONSerialization 合并不是整体覆盖）。
    /// `to` 只给离线测试用；正式调用不传，写到标准位置。
    static func saveRules(_ rules: [KeyboardFrameRule], to destination: String? = nil) throws {
        let target = destination ?? path
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: target),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var keyboard = root["keyboard"] as? [String: Any] ?? [:]
        var detect = keyboard["detect"] as? [String: Any] ?? [:]
        detect["rules"] = rules.map { rule -> [String: Any] in
            var dict: [String: Any] = [
                "match": KeyboardRuleBuilder.hexString(rule.bytes),
                "side": rule.side,
            ]
            // mask 只在"不是全部都要比"时才写出来，配置文件更干净
            if rule.mask.contains(0x00) {
                dict["mask"] = KeyboardRuleBuilder.hexString(rule.mask)
            }
            if let note = rule.note { dict["note"] = note }
            return dict
        }
        keyboard["detect"] = detect
        root["keyboard"] = keyboard

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: target))
    }

    /// 保存"监听哪把键盘"的厂商 ID（界面里点选检测到的键盘时调用），并**立刻重载**
    /// —— 否则重启 kvm-keywatch 时读到的还是旧值。
    /// 和 saveRules / saveDisplayInputs 一样：合并写，**不覆盖其它字段**。
    static func saveKeyboardVendorID(_ vendorID: String, to destination: String? = nil) throws {
        let target = destination ?? path
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: target),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var keyboard = root["keyboard"] as? [String: Any] ?? [:]
        keyboard["vendorID"] = vendorID
        root["keyboard"] = keyboard

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: target))
        reload()
    }

    /// 配置文件不存在就写一份「起步配置」（值就是当前生效的默认值）。
    /// 保存显示器输入源编号（「显示器切换」两步学习学到的），并**立刻重载**
    /// —— 否则切屏读到的还是启动时那份旧的（见 shared 上的注释）。
    static func saveDisplayInputs(mac: String, windows: String, to destination: String? = nil) throws {
        let target = destination ?? path
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: target),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var display = root["display"] as? [String: Any] ?? [:]
        display["_说明"] = "显示器的 DDC/CI 输入源编号（用「显示器切换」学出来的；不同型号不一样）"
        display["macInput"] = mac
        display["windowsInput"] = windows
        root["display"] = display

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: target))
        reload()
    }

    ///
    /// 为什么需要：设置里那个「打开配置文件」按钮原来什么都没发生 ——
    /// 因为文件根本不存在，Finder 没法"选中一个不存在的文件"。
    @discardableResult
    static func ensureFileExists() -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        let starter = """
        {
          "_说明": "这个文件是可选的：删掉它、或删掉其中任何字段，都会回到内置默认值。改完重启 app 生效。",
          "display": {
            "_说明": "显示器的 DDC/CI 输入源编号（本机实测 17 = HDMI-1 / 15 = DP-1）",
            "macInput": "\(TraiectusConfig.shared.macDisplayInput)",
            "windowsInput": "\(TraiectusConfig.shared.windowsDisplayInput)"
          },
          "keyboard": {
            "_说明": "监听哪家厂商的键盘；detect.rules 是状态帧判定规则（跑一次「键盘学习」会自动写进来）",
            "vendorID": "\(TraiectusConfig.shared.keyboardVendorID)"
          },
          "tools": {
            "_说明": "三个外部工具的位置；留空 = 用 app 内置的",
            "keywatch": "", "m1ddc": "", "dwc": ""
          },
          "network": {
            "_说明": "设置里预填的 Windows 地址；留空 = 不预填",
            "defaultHost": ""
          }
        }
        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try starter.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[Traiectus] 写起步配置失败：\(error.localizedDescription)")
            return false
        }
    }
}
