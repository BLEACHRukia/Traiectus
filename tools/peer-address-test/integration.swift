import Foundation
import AppKit

/// 独立裸可执行文件使用自己的偏好域；假服务器只回握手与 PONG，不注入任何输入。
@main
struct AddressIntegrationTest {
    static var client: TraiectusClient!
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: \(message)"); exit(1) }
        count += 1
        print("PASS: \(message)")
    }
    static func at(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }
    static func main() {
        // 初始化时借用预览保护，跳过登录项登记；关闭键盘联动与系统热键。
        setenv("XCODE_RUNNING_FOR_PREVIEWS", "1", 1)
        let d = UserDefaults.standard
        for key in ["traiectus.link", "traiectus.autostart", "traiectus.sleephotkey.enabled", "traiectus.mousehotkey.enabled"] { d.set(false, forKey: key) }
        d.set("integration-test-token", forKey: "traiectus.token")
        d.set("127.0.0.1", forKey: "traiectus.host")
        _ = NSApplication.shared
        client = TraiectusClient()
        unsetenv("XCODE_RUNNING_FOR_PREVIEWS")
        client.setAddressMode(.fixed)
        client.portText = "45788"
        check(client.saveAddressAndConnect("127.0.0.1"), "保存固定地址并启动真实 TCP")
        at(2) {
            check(client.isConnected, "假服务器握手成功")
            client.receivePeerHeartbeat("192.168.1.100")
            check(client.host == "127.0.0.1", "已连接时忽略旧 IP 心跳")
        }
        // 假服务器在第 3 秒断开、第 9 秒恢复。
        at(7) {
            check(!client.isConnected, "服务器断开后进入重连")
            client.receivePeerHeartbeat("192.168.1.100")
            client.autoDetectPeer()
            check(client.host == "127.0.0.1" && !client.discovering, "断线时不采用旧 IP，也不自动扫描")
        }
        at(13) {
            check(client.isConnected && client.host == "127.0.0.1", "服务器恢复后自动连回固定地址")
            client.stop()
        }
        at(14) {
            client.setAddressMode(.automatic)
            client.receivePeerHeartbeat("192.168.1.100")
            check(client.host == "127.0.0.1" && !client.isRunning, "手动断开在自动模式下也不会被心跳重新连接")
            client.beginAddressEditing()
            check(!client.saveAddressAndConnect("192.1"), "保存半截地址被拒绝")
            check(client.host == "127.0.0.1", "无效草稿不改变已保存地址")
            client.cancelAddressEditing()
            client.shutdownCleanly()
            print("集成测试通过：\(count)/\(count)")
            exit(0)
        }
        RunLoop.main.run()
    }
}
