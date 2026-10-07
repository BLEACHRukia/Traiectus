// ============================================================================
//  PeerDiscovery —— 自动找 Windows 在哪
// ----------------------------------------------------------------------------
//  要解决的问题：Mac 是**主动连**的一侧，所以它必须先知道 Windows 的地址。
//  全新安装时两边都不知道对方在哪，必须有个人先开口。这里做三件事，按顺序：
//
//    ① 广播问一声：往网段广播地址发 `WHO 1`，跑着 Traiectus 的 Windows 会
//       单播回 `HERE 1 <TCP端口>`（见给Windows端的「地址自动发现」任务单）。
//       毫秒级，但**要 Windows 新版**才认这个报文。
//    ② 扫自己网段：挨个试自己那个 /24 的 45789。慢一点（1~2 秒），
//       但**不需要 Windows 配合**，任何版本都能用。
//    ③ 从 HB 心跳学：Windows 每 2 秒往本机 45790 发一次心跳，来源地址就是它。
//       这条在 KeyboardLink 里做（它拿着那个 socket），这里不重复。
//
//  设计约束：
//    · 只扫**自己所在的那个 /24**。大网段（/16 之类）也不越界去扫六万个地址。
//    · 先试记住的地址，其次广播，最后才扫描 —— 扫描是兜底，不是首选。
//    · 全程只发探测包，不改系统任何设置。
// ============================================================================

import Foundation

enum PeerDiscovery {

    /// 广播发现用的 UDP 端口。复用原来控制通道那个 —— 它的防火墙规则还在，
    /// 用户不用再点一次防火墙（见任务单 §1）。
    static let discoveryPort: UInt16 = 45791
    /// WHO/HERE 的版本号。对不上就互不打扰。
    static let discoveryVersion = 1

    // ---------------------------------------------------------------- 网络信息

    /// 本机所有活动 IPv4 网卡：(地址, 掩码)
    static func localIPv4() -> [(address: String, mask: String)] {
        var out: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        var p = first
        while true {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               let nm = p.pointee.ifa_netmask {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                _ = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                _ = getnameinfo(nm, socklen_t(nm.pointee.sa_len), &mask, socklen_t(mask.count),
                                nil, 0, NI_NUMERICHOST)
                let h = String(cString: host), m = String(cString: mask)
                if !h.isEmpty, !m.isEmpty, m != "255.255.255.255" { out.append((h, m)) }
            }
            guard let next = p.pointee.ifa_next else { break }
            p = next
        }
        return out
    }

    private static func ipToUInt32(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    private static func uint32ToIP(_ v: UInt32) -> String {
        var a = in_addr(s_addr: v.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// 每个网卡的**定向广播地址**（x.y.z.255 这种），WHO 往这儿发。
    /// 比 255.255.255.255 可靠：某些 Wi-Fi 会吃掉全局广播，但对本网段的定向广播放行。
    static func broadcastAddresses() -> [String] {
        localIPv4().compactMap { iface in
            guard let ip = ipToUInt32(iface.address), let mk = ipToUInt32(iface.mask) else { return nil }
            return uint32ToIP((ip & mk) | ~mk)
        }
    }

    /// 要扫的地址：**只扫自己所在的那个 /24**（x.y.z.1 ~ x.y.z.254），排除自己。
    /// 哪怕本机在 /16 里，也只扫这 254 个 —— 不越界去扫六万个地址。
    static func scanTargets() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for iface in localIPv4() {
            guard let ip = ipToUInt32(iface.address) else { continue }
            let base = (ip & 0xFFFFFF00) >> 8          // 取前三个字节
            for host in UInt32(1)...UInt32(254) {
                let addr = uint32ToIP((base << 8) | host)
                if addr == iface.address { continue }
                if seen.insert(addr).inserted { out.append(addr) }
            }
        }
        return out
    }

    // ---------------------------------------------------------------- ① 广播问

    /// 往网段广播发 `WHO 1`，收 `HERE 1 <port>` 应答。返回 (地址, 端口)。
    static func askByBroadcast(timeout: TimeInterval) -> [(ip: String, port: UInt16)] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        // 绑到随机端口，应答才会回来找我们
        var me = sockaddr_in()
        me.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        me.sin_family = sa_family_t(AF_INET)
        me.sin_port = 0
        me.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &me) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        // 广播出去（定向广播优先，再补一条全局广播）
        var targets = broadcastAddresses()
        targets.append("255.255.255.255")
        let payload = Data("WHO \(discoveryVersion)\n".utf8)
        for t in targets {
            var dst = sockaddr_in()
            dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = discoveryPort.bigEndian
            guard inet_pton(AF_INET, t, &dst.sin_addr) == 1 else { continue }
            // 每层闭包都用具名参数：嵌套着用 $0/$1 编译器会分不清是谁的
            _ = withUnsafePointer(to: &dst) { dstPtr -> Int in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int in
                    payload.withUnsafeBytes { raw -> Int in
                        sendto(fd, raw.baseAddress, payload.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // 收应答
        var found: [(String, UInt16)] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var tv = timeval(tv_sec: Int(left), tv_usec: Int32((left - Double(Int(left))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 256)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &len)
                }
            }
            guard n > 0 else { break }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: " ").map(String.init)
            // 形如：HERE 1 45789
            guard parts.count >= 3, parts[0].uppercased() == "HERE",
                  Int(parts[1]) == discoveryVersion, let port = UInt16(parts[2]) else { continue }
            var a = from.sin_addr
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            if seen.insert(ip).inserted { found.append((ip, port)) }
        }
        return found
    }

    // ---------------------------------------------------------------- ② 扫描

    /// 试一个地址的 TCP 端口开不开。非阻塞 connect + poll，超时很短。
    private static func probe(_ ip: String, port: UInt16, timeoutMs: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }                 // 立刻连上
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// 扫自己网段，返回开着该端口的地址。
    /// `concurrency` 控制同时探测多少个 —— 太高会被某些路由器当攻击，64 是安全的量级。
    ///
    /// ⚠️ `excluding` 一定要把**当前连着的那个地址**排除掉：服务端同一时刻只接受一个
    /// 客户端，探测包会把已经连上的自己挤下线（Windows 侧文档里记过这个坑：
    /// 「用『连一下 45789』判断服务端就绪 —— 会把 Mac 挤下线」）。
    static func scan(port: UInt16, timeoutMs: Int32 = 350, concurrency: Int = 64,
                     excluding: Set<String> = []) -> [String] {
        let targets = scanTargets().filter { !excluding.contains($0) }
        guard !targets.isEmpty else { return [] }

        var found: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: concurrency)

        for ip in targets {
            sem.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = probe(ip, port: port, timeoutMs: timeoutMs)
                if ok { lock.lock(); found.append(ip); lock.unlock() }
                sem.signal()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 8)       // 兜底，别把自己卡死
        return found.sorted()
    }
}
