// ============================================================================
//  TraiectusApp —— 菜单栏 app（无 Dock 图标，LSUIElement = true）
//  设计文档 §1：形态 = 菜单栏 app + 面板；退出入口刻意不提供（⌘Q 兜底）
// ============================================================================

import SwiftUI
// SwiftPM/Xcode 构建时 UI 在库里，需要 import；
// build.sh 单模块编译时不存在这个模块，canImport 会为假，于是跳过。
#if canImport(TraiectusKit)
import TraiectusKit
#endif

@main
struct TraiectusApp: App {
    @StateObject private var client = TraiectusClient()

    init() {
        // 悬停提示的延迟：macOS 默认要等约 2 秒（NSInitialToolTipDelay），太慢，
        // 用户会以为"没有提示"。压到 400ms。
        // 只注册在**本 app 的偏好域**里 —— 不动系统的全局设置。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: client.linkState)
        } label: {
            Image(systemName: client.linkState.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // --------------------------------------------------------------------
        //  设置窗口故意**不用 `Settings` 场景**。
        //
        //  macOS 给 `Settings` 场景套的是那套老式「偏好设置」窗口皮肤：标签栏画在
        //  标题栏下方，图标+文字平铺一排，不透明白底 —— 这套皮肤没有跟进 macOS 26
        //  起的 Liquid Glass。同一个 TabView 放进普通 `Window` 场景，macOS 才会画成
        //  新版紧凑分段样式（纯文字、居中、玻璃药丸，切换时药丸会流动）。
        //
        //  实测与部署目标/SDK 无关：macOS 14 目标编译、LSUIElement 菜单栏 app，
        //  照样是玻璃药丸。差别只来自场景类型。
        //
        //  代价（都由下面 .commands 补回来）：
        //    · ⌘, 不再白送 —— 自己接一条「设置…」
        //    · 窗口标题固定为「设置」，不再跟着当前标签变
        // --------------------------------------------------------------------
        Window(L("设置"), id: SettingsWindow.id) {
            SettingsView()
                .environmentObject(client)
                // 去掉最小化按钮（详见 SettingsWindowConfigurator 的注释）
                .background(SettingsWindowConfigurator())
                // 菜单栏 app 没有 Dock 图标，窗口不主动激活的话可能开在别的 app 后面
                .onAppear { NSApp.activate() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }
    }
}

/// 应用菜单里的「设置…」（⌘,）。用 openWindow 而不是 Settings 场景那套
/// showSettingsWindow: selector —— 普通 Window 场景不认那个 selector。
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("设置…")) { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",", modifiers: .command)
    }
}
