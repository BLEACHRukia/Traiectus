// ============================================================================
//  KeyboardDetect —— "现在 Mac 上插着哪把键盘"（用来免掉用户查厂商 ID）
// ----------------------------------------------------------------------------
//  为什么需要它：
//    联动靠 kvm-keywatch 盯**某一家的 VID**（默认 Corsair 0x1B1C）——
//    键盘一切到 Windows，那个 VID 的设备就从 Mac 上消失，于是判定"键盘走了"。
//    换一把别的牌子的键盘，这个 VID 就对不上：**联动会一声不响地完全不工作**，
//    而用户唯一的办法是去手编 config.json 里的 `keyboard.vendorID`。
//
//  这里做的是"把数字换成名字"：枚举当前挂在 Mac 上的键盘（GenericDesktop/Keyboard），
//  按 VID 去重，交给界面显示成「CORSAIR K70 MINI · 0x1B1C」这种一眼能认的东西。
//  只要一个 VID 就能让联动工作，而 VID 从设备上直接读得到 —— 用户不需要知道它。
//
//  只读：只读设备属性（VID/PID/名字/传输方式），不打开、不发送、不修改任何东西。
// ============================================================================

import Foundation
import IOKit.hid

struct KeyboardCandidate: Identifiable, Equatable {
    let vendorID: Int
    let productID: Int
    let name: String
    let transport: String

    /// 同一个 VID 只留一条 —— 界面上的候选就是"一把键盘"
    var id: Int { vendorID }

    /// 配置里用的写法，例如 "0x1B1C"
    var vidHex: String { String(format: "0x%04X", vendorID) }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "未命名键盘" : trimmed
    }

    /// 传输方式说人话（kvm-keywatch 只认这个 VID 的出现/消失，接法无所谓）
    var transportText: String {
        let t = transport.lowercased()
        if t.contains("bluetooth") { return "蓝牙" }
        if t.contains("usb") { return "USB" }
        return transport
    }

    /// 「CORSAIR K70 MINI · 蓝牙 · 0x1B1C」
    var summary: String {
        var parts = [displayName]
        if !transportText.isEmpty { parts.append(transportText) }
        parts.append(vidHex)
        return parts.joined(separator: " · ")
    }

    /// 界面显示用的摘要：和 `summary` 同格式，但名字/传输方式跟着界面语言走。
    /// `summary` 保持中文 —— 日志和排查记录里两端要对得上，所以两边分开。
    var displaySummary: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var parts = [trimmed.isEmpty ? L("未命名键盘") : trimmed]
        let t = transport.lowercased()
        let label = t.contains("bluetooth") ? L("蓝牙") : (t.contains("usb") ? "USB" : transport)
        if !label.isEmpty { parts.append(label) }
        parts.append(vidHex)
        return parts.joined(separator: " · ")
    }
}

enum KeyboardDetect {

    /// 当前挂在 Mac 上的键盘类设备，按 VID 去重后返回（通常就是一把）。
    ///
    /// 注意匹配的是 **GenericDesktop / Keyboard usage** —— 键盘的厂商自定义接口
    /// （状态帧那个 FF42）不在此列，但那不影响判定：kvm-keywatch 只按 VID 匹配，
    /// 而同一把键盘的键盘接口和厂商接口 VID 相同。
    static func connectedKeyboards() -> [KeyboardCandidate] {
        guard let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                               IOOptionBits(kIOHIDOptionsTypeNone)) as IOHIDManager? else {
            return []
        }
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        var byVID: [Int: KeyboardCandidate] = [:]
        for device in devices {
            guard let vid = property(device, kIOHIDVendorIDKey) as? Int else { continue }
            let pid = property(device, kIOHIDProductIDKey) as? Int ?? 0
            let name = property(device, kIOHIDProductKey) as? String ?? ""
            let transport = property(device, kIOHIDTransportKey) as? String ?? ""

            // 同一把键盘可能有多个 collection → 名字最长的那个通常最完整
            if let existing = byVID[vid], existing.name.count >= name.count { continue }
            byVID[vid] = KeyboardCandidate(vendorID: vid, productID: pid,
                                           name: name, transport: transport)
        }
        return byVID.values.sorted { $0.vendorID < $1.vendorID }
    }

    /// "0x1B1C" / "1B1C" / "7092" 都认；认不出来返回 nil
    static func parseVendorID(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let hexDigits = "0123456789abcdefABCDEF"
        if s.lowercased().hasPrefix("0x") {
            return Int(s.dropFirst(2), radix: 16)
        }
        if s.allSatisfy({ $0.isNumber }) { return Int(s) }
        if s.allSatisfy({ hexDigits.contains($0) }) { return Int(s, radix: 16) }
        return nil
    }

    static func hex(_ value: Int) -> String { String(format: "0x%04X", value) }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }
}
