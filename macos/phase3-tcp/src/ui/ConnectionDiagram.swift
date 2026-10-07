// ============================================================================
//  ConnectionDiagram —— Mac ●———○ Win 连接可视化
//  设计文档 §3（面板视觉稿）、§4（状态映射）；尺寸规格见 §2
//
//  线的语义（2026-09-27 调整）：**线只说"链路通不通"，点才说"控制权在谁手里"**。
//    · Mac 控制中：整条线全绿实线，左边点亮绿、右边点灰
//    · Win 控制中：整条线全绿实线，右边点亮绿、左边点灰
//    （旧版是"绿→灰"渐变，两半截两种颜色，容易被误读成 Win 侧掉线 —— 已按用户意见改掉）
// ============================================================================

import SwiftUI

struct ConnectionDiagram: View {
    let state: LinkState

    var body: some View {
        HStack(spacing: 0) {
            Node(label: "Mac",
                 suffix: nil,
                 active: state.activeSide == .mac,
                 online: state.isOnline)

            Connector(state: state)
                .frame(height: 2)
                .padding(.horizontal, 10)

            Node(label: "Win",
                 suffix: winSuffix,
                 active: state.activeSide == .win,
                 online: state.isOnline)
        }
        .padding(.horizontal, 40)      // 20pt 面板内边距 + 40pt = 圆点距面板边缘 60pt
        .frame(height: 60)
    }

    private var winSuffix: String? {
        switch state {
        case .connecting:     return L("连接中")
        case .windowsOffline: return L("未运行")
        case .error:          return L("异常")
        case .connected:      return nil       // 正常状态不显示后缀
        }
    }
}

private struct Node: View {
    let label: String
    let suffix: String?
    let active: Bool
    let online: Bool

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(fillColor)
                .frame(width: 12, height: 12)
                .scaleEffect(pulse && active && !reduceMotion ? 1.18 : 1.0)
                .animation(
                    active && !reduceMotion
                    ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                    : .default,
                    value: pulse
                )

            Text(displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(labelColor)
                .fixedSize()
                .offset(y: 20)
                .allowsHitTesting(false)
        }
        .frame(width: 12, height: 12)
        .onAppear { if active { pulse = true } }
        .onChange(of: active) { _, newValue in pulse = newValue }
    }

    private var displayText: String {
        if let s = suffix { return "\(label)（\(s)）" }
        return label
    }

    private var fillColor: Color {
        if active { return .green }
        if !online { return .secondary.opacity(0.3) }
        return .secondary.opacity(0.4)
    }

    private var labelColor: Color {
        if suffix != nil { return .secondary }
        return active ? .primary : .secondary
    }
}

private struct Connector: View {
    let state: LinkState

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width
                let h = geo.size.height
                p.move(to: CGPoint(x: 0, y: h))
                p.addQuadCurve(
                    to: CGPoint(x: w, y: h),
                    control: CGPoint(x: w / 2, y: h - 4)      // 微弧向上拱 4pt
                )
            }
            .stroke(style: strokeStyle)
            .foregroundStyle(strokeColor)
        }
    }

    private var strokeStyle: StrokeStyle {
        switch state {
        case .connected:
            return StrokeStyle(lineWidth: 1.5)
        case .connecting:
            return StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        case .windowsOffline, .error:
            return StrokeStyle(lineWidth: 1.5, dash: [3, 3])
        }
    }

    private var strokeColor: AnyShapeStyle {
        switch state {
        case .connected:
            // 连上就是一根绿线；"控制权在谁那边"由圆点的颜色表达（见 Node.fillColor）
            return AnyShapeStyle(Color.green)
        case .connecting:
            return AnyShapeStyle(Color.orange)
        case .windowsOffline:
            return AnyShapeStyle(Color.secondary.opacity(0.3))
        case .error:
            return AnyShapeStyle(Color.red)
        }
    }
}

// ---------------------------------------------------------------- 预览（Xcode）
// 在 Xcode 里打开本目录（含 Package.swift）后，右侧画布可直接看到这几种状态

#Preview("Mac 控制中") {
    ConnectionDiagram(state: .connected(side: .mac))
        .padding(20)
        .frame(width: 320)
}

#Preview("Win 控制中") {
    ConnectionDiagram(state: .connected(side: .win))
        .padding(20)
        .frame(width: 320)
}

#Preview("连接中 / 未运行 / 异常") {
    VStack(spacing: 24) {
        ConnectionDiagram(state: .connecting).padding(20).frame(width: 320)
        ConnectionDiagram(state: .windowsOffline).padding(20).frame(width: 320)
        ConnectionDiagram(state: .error).padding(20).frame(width: 320)
    }
}
