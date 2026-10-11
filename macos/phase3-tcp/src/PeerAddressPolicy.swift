import Foundation
import Network

/// 固定地址与自动寻找是两种不同的意图，不能用“当前断线”推断用户允许换地址。
enum PeerAddressMode: String, CaseIterable {
    case automatic
    case fixed
}

/// 只在主线程使用；每轮扫描带身份，取消后即使旧结果晚到也不能覆盖新设置。
struct PeerAddressPolicy {
    var mode: PeerAddressMode = .automatic
    var editing = false
    var connectionRequested = false
    private(set) var discoveryID: UUID?

    var allowsDiscovery: Bool { mode == .automatic && !editing && connectionRequested }

    mutating func beginDiscovery() -> UUID? {
        guard allowsDiscovery, discoveryID == nil else { return nil }
        let id = UUID()
        discoveryID = id
        return id
    }

    mutating func cancelDiscovery() { discoveryID = nil }

    mutating func finishDiscovery(_ id: UUID) -> Bool {
        guard discoveryID == id else { return false }
        discoveryID = nil
        return allowsDiscovery
    }

    static func validHost(_ text: String) -> Bool {
        let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        // 不接受 inet_aton 风格的缩写（192.1），避免半截输入被解析成另一个地址。
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && UInt8($0) != nil }
        }
        if IPv6Address(host) != nil { return true }
        // 保留主机名连接；地址栏不接受 URL、路径或空格。
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 }
        }
    }
}
