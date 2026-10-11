import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: \(name)") }
    count += 1
    print("PASS: \(name)")
}

var policy = PeerAddressPolicy()
check(!policy.allowsDiscovery, "未请求连接时，心跳不能自行建立连接")
policy.connectionRequested = true
check(policy.allowsDiscovery, "自动模式保留心跳学习")
let old = policy.beginDiscovery()!
check(policy.beginDiscovery() == nil, "不并发启动第二轮扫描")
policy.mode = .fixed
policy.cancelDiscovery()
check(!policy.allowsDiscovery, "固定模式拒绝旧 Wi-Fi 心跳（包括断线时）")
check(policy.beginDiscovery() == nil, "固定模式不广播、不扫描")
policy.mode = .automatic
let fresh = policy.beginDiscovery()!
check(!policy.finishDiscovery(old), "旧扫描晚到不能覆盖新一轮结果")
check(policy.discoveryID == fresh, "旧结果不能清掉当前扫描")
check(policy.finishDiscovery(fresh), "当前有效扫描正常采用")
let editingScan = policy.beginDiscovery()!
policy.editing = true
policy.cancelDiscovery()
check(!policy.allowsDiscovery, "编辑草稿期间拒绝心跳学习")
check(!policy.finishDiscovery(editingScan), "编辑时作废在途扫描结果")
policy.editing = false
let stoppedScan = policy.beginDiscovery()!
policy.connectionRequested = false
policy.cancelDiscovery()
check(!policy.finishDiscovery(stoppedScan), "手动断开后不被扫描结果重新连接")
check(!policy.allowsDiscovery, "手动断开后不被心跳重新连接")
for host in ["192.168.50.1", " 192.168.50.1 ", "10.0.0.1", "::1", "fe80::1", "windows-pc", "win.local"] {
    check(PeerAddressPolicy.validHost(host), "接受完整地址 \(host)")
}
for host in ["", "192.", "192.1", "192.168.50.", "256.1.1.1", "192.168.50.1.2", "http://win", "win pc", "win..local", "-win", "win-"] {
    check(!PeerAddressPolicy.validHost(host), "拒绝半截或无效地址 \(host)")
}
print("全部通过：\(count)/\(count)")
