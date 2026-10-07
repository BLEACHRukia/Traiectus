// ============================================================================
//  PanelView —— 菜单栏下拉面板（320pt 固定宽）
//  内容只有三样：名字 + 连接可视化 + 齿轮（设计文档 §1、§3）
// ============================================================================

import SwiftUI

public struct PanelView: View {
    /// 面板只依赖"当前状态" —— 这样 Xcode 预览里可以直接喂各种状态，不必真连网
    let state: LinkState
    @Environment(\.openWindow) private var openWindow

    public init(state: LinkState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Spacer().frame(height: 32)
            ConnectionDiagram(state: state)
            Spacer().frame(height: 32)
        }
        .padding(20)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Traiectus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                openWindow(id: SettingsWindow.id)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("设置（⌘,）"))
        }
    }
}

#Preview("面板 · Mac 控制中") {
    PanelView(state: .connected(side: .mac))
}

#Preview("面板 · Win 控制中") {
    PanelView(state: .connected(side: .win))
}

#Preview("面板 · 连接中") {
    PanelView(state: .connecting)
}

#Preview("面板 · Win 未运行") {
    PanelView(state: .windowsOffline)
}

#Preview("面板 · 异常") {
    PanelView(state: .error)
}
