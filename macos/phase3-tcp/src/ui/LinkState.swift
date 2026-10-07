// ============================================================================
//  LinkState —— 面板与菜单栏图标的状态模型（纯展示层）
//  设计文档《MiniKVM Mac 客户端 UI 重设计》§6.2
// ============================================================================

import SwiftUI

public enum LinkSide {
    case mac
    case win
}

public enum LinkState: Equatable {
    case connected(side: LinkSide)
    case connecting
    case windowsOffline
    case error

    var isOnline: Bool {
        if case .connected = self { return true }
        return false
    }

    var activeSide: LinkSide? {
        if case .connected(let s) = self { return s }
        return nil
    }

    public var menuBarSymbol: String {
        switch self {
        // 四种状态各配一个符号，一眼能分清：
        //   已连接 → 显示器 + 连接线（现在的样子就是"连着"）
        //   连接中 → 循环箭头（正在重试/建立连接）
        //   未运行 → 斜杠方块（对面没开，链路不存在）
        //   异常   → 感叹号三角（口令/版本不对之类）
        // 注意：菜单栏图标是模板图（单色，跟随系统深浅色），只能用 SF Symbols 或单色模板图
        case .connected:      return "rectangle.connected.to.line.below"
        case .connecting:     return "arrow.triangle.2.circlepath"
        case .windowsOffline: return "rectangle.slash"
        case .error:          return "exclamationmark.triangle"
        }
    }
}

enum FeatureStatus {
    case enabled
    case needsPermission
    case notRunning
    case connecting      // 刚点了"重连"，正在尝试
    case conflict        // 快捷键已被别的程序占用

    var label: String {
        switch self {
        case .enabled:         return L("已启用")
        case .needsPermission: return L("需要授权")
        case .notRunning:      return L("未运行")
        case .connecting:      return L("重连中…")
        case .conflict:        return L("快捷键被占用")
        }
    }

    var color: Color {
        switch self {
        case .enabled:         return .green
        case .needsPermission: return .orange
        case .notRunning:      return .red
        case .connecting:      return .orange
        case .conflict:        return .orange
        }
    }

    var isActionable: Bool {
        self != .enabled
    }
}
