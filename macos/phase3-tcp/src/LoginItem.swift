// ============================================================================
//  LoginItem —— 「登录时启动」（macOS 13+ 官方 API：SMAppService）
// ----------------------------------------------------------------------------
//  为什么要有它：
//    以前"开机自启"只有 install-app.sh 写的那份 LaunchAgent 管 —— 那条路只有
//    **跑过安装脚本**的人才有。把 .app 直接拖进「应用程序」的用户不会自启，
//    而且 app 里没有任何地方能打开它，用户只能自己去手编 LaunchAgent。
//
//  现在的规则（默认开、之后完全听用户的）：
//    · 第一次启动：注册一次 → 登录时就启动（macOS 会弹"已添加后台项目"，能看到）
//    · 之后**不再自动注册** —— 用户在「系统设置 → 通用 → 登录项」里关掉，
//      我们不会偷偷注册回来（那样最招人烦）
//    · 想再打开：设置窗口「通用 → 启动 → 登录时启动」那个开关，或系统设置里加回来
//
//  前提：app 要有稳定签名（我们用的是自签证书，满足），放在 ~/Applications
//  或 /Applications 里都行。
// ============================================================================

import Foundation
import ServiceManagement

enum LoginItem {

    /// 用户是不是已经"拥有"这个决定 —— 首次自动注册之后置位。
    /// 置位后我们只读状态、不再自动注册，免得和用户在系统设置里的选择打架。
    private static let configuredKey = "traiectus.loginitem.configured"

    /// 现在是不是"登录时会启动"
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 设置窗口里显示的状态（也是那个开关右侧的小字）
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return L("已开启")
        case .notRegistered:     return L("未开启")
        case .requiresApproval:  return L("要在系统设置的「登录项」里允许")
        case .notFound:          return L("找不到 app —— 先把它放进「应用程序」")
        @unknown default:        return L("未知状态")
        }
    }

    /// 第一次启动时注册一次（默认开）。返回一句给日志用的话。
    @discardableResult
    static func registerOnFirstRun() -> String {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: configuredKey) {
            return "已经登记过（当前 \(isEnabled ? "开" : "关")）"
        }
        defaults.set(true, forKey: configuredKey)
        guard !isEnabled else { return "系统里本来就开着" }
        do {
            try SMAppService.mainApp.register()
            return "已登记开机自启（默认开；不要的话在「系统设置 → 通用 → 登录项」里关）"
        } catch {
            return "登记失败：\(error.localizedDescription)"
        }
    }

    /// 设置窗口那个开关用的。返回 nil = 成功，否则是错误描述。
    @discardableResult
    static func set(_ on: Bool) -> String? {
        UserDefaults.standard.set(true, forKey: configuredKey)   // 用户手动动过，之后都听他的
        let status = SMAppService.mainApp.status
        do {
            if on {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
