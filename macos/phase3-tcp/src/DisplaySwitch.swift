// ============================================================================
//  DisplaySwitch —— 显示器输入源的"学习"
// ----------------------------------------------------------------------------
//  为什么需要它：
//    DDC/CI 的**命令码**（VESA MCCS）各品牌基本一致（输入源都是 0x60），
//    但**取值**不一样，而且不是"少数例外"：
//      · 大多数品牌按标准来：HDMI-1 = 17、DP-1 = 15（本机这台 ASUS 就是）
//      · LG 用另一套寻址：HDMI-1 = 144、DP-1 = 208（m1ddc 要加 -alt）
//      · 有些型号干脆自定义（Dell 的 PIP/PBP 是 33/34/36…，KVM 是 1728）
//    所以"15/17 抄过去就能用"是不成立的 —— 换台显示器（哪怕同品牌换型号）
//    就可能完全对不上，而用户无从知道该填几。
//
//  好在**不用猜**：显示器愿意报出自己当前用的是哪个值（`m1ddc get input`）。
//  所以做法是"两步学习"：让用户用显示器按钮切到 Mac 读一次、切到 Windows 再读一次。
//  这比"遍历候选值让用户点确认"可靠得多，而且连 LG 那种非标准寻址都能自动适配。
//
//  ⚠️ 前提：**显示器 OSD 里必须开启 DDC/CI**。有些显示器出厂是关的，
//     有些只在特定输入口上暴露它。这个前提要放在给用户看的第一句 ——
//     不满足的话后面所有步骤都不会有反应，而现象是"点了没反应"，很难查。
// ============================================================================

import Foundation

enum DisplaySwitch {

    /// 和 KeyboardLink 一样的两级查找：config.json 里指定的 → 打包在 app 内的 → 仓库里
    static let relativePaths = [
        "../Resources/m1ddc",                       // 打包在 app 内（推荐路径）
        "../../../kvm-link/m1ddc/m1ddc",            // 从仓库 build/ 直接跑时
        "../../../display-input/m1ddc/m1ddc",
    ]

    static func toolPath() -> String? {
        if let p = TraiectusConfig.shared.m1ddcPath, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        guard let exe = Bundle.main.executableURL else { return nil }
        for rel in relativePaths {
            let p = exe.deletingLastPathComponent().appendingPathComponent(rel).standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 跑一次 m1ddc 并把标准输出读回来。**会阻塞**，别在主线程调。
    static func run(_ args: [String]) -> String? {
        guard let tool = toolPath() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()          // 错误输出丢掉：失败时返回 nil 就够了
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 显示器此刻报出来的输入源编号（例如 "17"）。读不到返回 nil。
    static func currentInput() -> String? {
        let v = run(["get", "input"])
        return (v?.isEmpty == false) ? v : nil
    }

    /// 把编号翻译成**标准表里**的名字（HDMI-1 / DP-1 …）。
    ///
    /// ⚠️ 只在编号确实落在 VESA MCCS 标准表里时才返回名字，否则返回空串 ——
    /// 有些品牌自己定义编号（LG 用 144/208），那种情况硬套一个名字就是说谎，
    /// 不如退回去只显示编号。调用方要自己处理空串。
    static func inputName(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespaces) {
        case "1":  return "VGA-1"
        case "3":  return "DVI-1"
        case "4":  return "DVI-2"
        case "15": return "DP-1"
        case "16": return "DP-2"
        case "17": return "HDMI-1"
        case "18": return "HDMI-2"
        case "27": return "USB-C"
        default:   return ""
        }
    }

    /// 给人看的写法：能翻出来就是「17（HDMI-1）」，翻不出来就只有「144」
    static func describe(_ value: String) -> String {
        let name = inputName(value)
        return name.isEmpty ? value : "\(value)（\(name)）"
    }

    /// 接在视频线上的显示器名字（例如 ["ASUS VG249"]），用来让用户确认选对了设备
    static func monitorNames() -> [String] {
        guard let text = run(["display", "list"]) else { return [] }
        return text.split(separator: "\n").compactMap { line -> String? in
            var s = String(line)
            // 形如：[1] ASUS VG249 (5CA81BBA-…)
            if let r = s.range(of: "] ") { s = String(s[r.upperBound...]) }
            if let r = s.range(of: " (")  { s = String(s[..<r.lowerBound]) }
            let name = s.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }
}
