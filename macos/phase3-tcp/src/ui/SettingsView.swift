// ============================================================================
//  SettingsView —— 设置窗口（标签页：通用 / 键盘 / 连接 / 高级）
// ----------------------------------------------------------------------------
//  每个标签页都是**独立的 View**（GeneralSettings / KeyboardSettings /
//  ConnectionSettings / AdvancedSettings）—— 这样在 Xcode 里可以单独开预览调版式，
//  不用每次装到机器上看。
//
//  退出入口刻意只放在「高级」里：面板要极简，而退出会直接断掉键盘联动与鼠标转发。
// ============================================================================

import SwiftUI

/// 设置窗口的标识。用普通 Window 场景（不是 Settings）时，打开窗口靠这个 id。
/// 定义在这里而不是 TraiectusApp.swift —— 那个文件不在 Xcode 的 SwiftPM 包里
/// （见 Package.swift 的 exclude），PanelView 引用不到它。
enum SettingsWindow {
    static let id = "traiectus.settings"
}

/// 设置窗口只留一个「关闭」，去掉最小化和缩放。
///   · 最小化：这是菜单栏 app，没有 Dock 图标 —— 窗口一旦被最小化，就再没有任何
///     入口能把它找回来（面板齿轮、菜单「设置…」都只是把已存在的窗口提到前面）。
///     去掉 styleMask 里的 .miniaturizable，顺手把 ⌘M 也一起废掉。
///     （macOS 26 SDK 起 NSWindow.isMiniaturizable 是只读的，只能改 styleMask。）
///   · 缩放：窗口由 .windowResizability(.contentSize) fixed 成 460 宽，四个页面
///     都是照这个宽度排的版；缩放按钮点不动、只剩一个灰色的死按钮，不如去掉。
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let w = window else { return }
            w.styleMask.remove(.miniaturizable)
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            // 窗口标题跟着界面语言走。Window 场景那个标题只在 scene 建立时求值一次，
            //   运行中切语言它不会变（「窗口」菜单 / 调度中心里就能看到），所以这里补一刀。
            w.title = L("设置")
        }
    }
}

public struct SettingsView: View {
    @EnvironmentObject var client: TraiectusClient
    /// 去抖用的延迟任务：停止输入 1.2 秒后才把新参数交给客户端
    @State private var applyWork: DispatchWorkItem?

    public init() {}

    public var body: some View {
        TabView {
            tab(L("通用"), "slider.horizontal.3")    { GeneralSettings() }
            tab(L("键盘"), "keyboard")               { KeyboardSettings() }
            tab(L("显示"), "display")                { DisplaySettings() }
            tab(L("连接"), "network")                { ConnectionSettings() }
            tab(L("高级"), "wrench.and.screwdriver") { AdvancedSettings() }
        }
        // 英文标签/正文比中文长，英文模式窗口宽 60px（中文 460 一字不动）。
        // 高度 560：通用页现在是「语言 + 四个开关区」，自然高度约 555pt（原 476，
        // 加了「启动 → 登录时启动」这一区）。窗口偏矮会把最后一行压掉半行 —— 实测踩过。
        //
        // `.id(语言)` 让整块**重建**，两件事都靠它（都是实测踩到的）：
        //   ① 标签栏：切语言时窗口宽从 520 变 460，但标签栏还按旧语言的宽度在量 ——
        //      英文切回中文后，五个中文标签会一直收进右边的 » 里（重建就好了）；
        //   ② 「语言」那行自己的选项文案同理，不重建会停在旧语言。
        .frame(width: Localization.isEnglish ? 520 : 460, height: 560)
        .id(Localization.language)
        // 地址 / 端口"随时可改、改完自动重连"。
        // ⚠️ 监听必须挂在这里（TabView），不能挂在「连接」页里：SwiftUI 只求值当前
        // 选中的标签页，端口挪到「高级」之后，挂在连接页就再也收不到它的变化了。
        .onChange(of: client.host)     { _, _ in scheduleApply() }
        .onChange(of: client.portText) { _, _ in scheduleApply() }
    }

    private func scheduleApply() {
        applyWork?.cancel()
        let work = DispatchWorkItem { client.applyEditedParameters() }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// 四个标签页长一个样：一个 Form、不画滚动条、顶部一个标签
    private func tab<Content: View>(_ title: String, _ symbol: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        content()
            .settingsPageStyle()
            .tabItem { Label(title, systemImage: symbol) }
    }
}

// ============================================================================
//  ⚠️ 设置页的样式必须挂到「页面自身」上，不能只挂在外层的 TabView 上。
//  原因：Xcode 预览直接渲染单个页面（GeneralSettings / KeyboardSettings …），
//  根本不经过 TabView。样式只挂外层时，预览里会退回 Form 的默认样式 —— 没有分组框、
//  标签被挤到左边缘、整页看着"乱"，和真机完全是两个样子，照它调版式全是白费功夫。
//  所以四个页面统一套 .settingsPageStyle()，预览和真机才会长得一模一样。
// ============================================================================

extension View {
    func settingsPageStyle() -> some View {
        formStyle(.grouped)
            .scrollIndicators(.never)
    }
}

// ============================================================================
//  通用
// ============================================================================

struct GeneralSettings: View {
    @EnvironmentObject var client: TraiectusClient

    var body: some View {
        Form {
            // 界面语言：中文 / English（切了立刻生效，不用重启）
            // 刻意不做「跟随系统」这一项 —— 用户说什么就是什么，不用猜系统。
            // 首次启动（还没选过）才按系统偏好挑一个，见 Localization.systemDefault。
            Section(L("语言")) {
                Picker(L("语言"), selection: Binding(
                    get: { Localization.language },
                    set: { new in
                        Localization.language = new
                        client.objectWillChange.send()        // 触发界面重绘
                    }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 这一行的选项文案也是"首次布局时算的"，重建由外面 TabView 上那个
                // .id(Localization.language) 负责，这里不用再单独挂一个。
            }
            // 键盘联动：**这一行以前只是个只读状态**（"键盘联动 已启用"），
            // 而 setLinkEnabled() 在整个界面里没人调用 —— 等于关不掉。改成开关。
            Section(L("键盘联动")) {
                Toggle(L("启用键盘联动"), isOn: Binding(
                    get: { client.linkEnabled },
                    set: { client.setLinkEnabled($0) }
                ))
                .tint(.green)
                // 关掉会连带停三件事，必须在按下去之前说清（放悬停提示，不占版面）
                .help(L("按键盘上的切换快捷键时，屏幕和鼠标跟着一起切。\n"
                        + "关掉后：① 不再自动切屏 / 切鼠标（键盘本身照常在两边切，只是本软件不跟）；"
                        + "② Mac 睡眠时不再自动把屏幕和鼠标交给 Windows（醒来也不会自动切回）；"
                        + "③ 键盘页的「学习」收不到状态帧，用不了。"))
                // 平时不显示状态 —— 开关本身就是状态。只在"开着但有问题"时多一行：
                // 缺「辅助功能」授权。点它先去请求授权，再把系统设置打开。
                // （先让系统弹一次"想控制这台电脑"的申请框 —— 只有申请过的 app 才会
                //   出现在「辅助功能」列表里，否则用户在那里找不到 Traiectus，只能手动 + 添加。）
                if client.linkEnabled && client.keyboardLinkStatus != .enabled {
                    StatusRow(title: L("需要注意"), status: client.keyboardLinkStatus) {
                        if client.keyboardLinkStatus == .needsPermission {
                            client.requestTrust()
                            client.openAccessibilitySettings()
                        }
                    }
                }
            }

            Section(L("睡眠热键")) {
                Toggle(L("启用睡眠快捷键"), isOn: Binding(
                    get: { client.sleepHotKeyEnabled },
                    set: { client.setSleepHotKeyEnabled($0) }
                ))
                // 明确指定"开启=绿色"：系统强调色被设成石墨/灰时，开关开着也是灰的，
                // 一眼看不出状态（也能和下面状态行的绿点对上）
                .tint(.green)
                LabeledContent(L("组合键")) {
                    ShortcutRecorder(keyCode: client.sleepHotKeyCode,
                                     modifiers: client.sleepHotKeyModifiers,
                                     isEnabled: client.sleepHotKeyEnabled) { code, mods in
                        client.setSleepHotKeyCombo(keyCode: code, modifiers: mods)
                    }
                    .frame(width: 150, height: 22)
                }
                // 平时不显示状态 —— 开关本身就是状态，再挂一个绿点"已启用"是噪音。
                // 只在"需要处理"时（缺「自动化」授权 / 快捷键被别的程序占了）才出现这一行。
                if client.sleepHotKeyStatus != .enabled {
                    StatusRow(title: L("需要注意"), status: client.sleepHotKeyStatus) {
                        client.tapSleepHotKeyStatus()
                    }
                }
            }

            // 鼠标控制权默认跟着键盘走（联动），但也给一个能单独切的键 ——
            // 和 Windows 侧那个 Ctrl+Alt+M 是同一个组合键，键盘在哪边就在哪边生效。
            Section(L("鼠标切换")) {
                Toggle(L("启用鼠标切换快捷键"), isOn: Binding(
                    get: { client.mouseHotKeyEnabled },
                    set: { client.setMouseHotKeyEnabled($0) }
                ))
                .tint(.green)
                // 说明放悬停提示：通用页已经三块，多一行正文会把页面顶出窗口
                .help(L("按一下就在 Mac 与 Win 之间切换鼠标控制权（等价于在 Win 上按 Ctrl+Alt+M）"))
                LabeledContent(L("组合键")) {
                    ShortcutRecorder(keyCode: client.mouseHotKeyCode,
                                     modifiers: client.mouseHotKeyModifiers,
                                     isEnabled: client.mouseHotKeyEnabled) { code, mods in
                        client.setMouseHotKeyCombo(keyCode: code, modifiers: mods)
                    }
                    .frame(width: 150, height: 22)
                }
                if client.mouseHotKeyStatus != .enabled {
                    StatusRow(title: L("需要注意"), status: client.mouseHotKeyStatus) {
                        client.tapMouseHotKeyStatus()
                    }
                }
            }

            // 登录时启动：app 自己用系统的 SMAppService 注册（第一次启动默认开）。
            // 状态以系统为准 —— 用户可能在系统设置里关掉，所以 onAppear 重新读一次。
            Section(L("启动")) {
                Toggle(L("登录时启动"), isOn: Binding(
                    get: { client.launchAtLogin },
                    set: { client.setLaunchAtLogin($0) }
                ))
                .tint(.green)
                .help(L("登录这台 Mac 时自动启动 Traiectus。关了也能用 —— 双击图标打开就行。"))
                if let error = client.launchAtLoginError {
                    Text(L("没能改成功：") + error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
        .settingsPageStyle()
        .onAppear {
            client.refreshDisplayInfo()
            client.refreshLaunchAtLogin()
        }
    }
}

// ============================================================================
//  键盘
// ============================================================================

struct KeyboardSettings: View {
    @EnvironmentObject var client: TraiectusClient
    /// 「学到的规则」默认收起 —— 展开时页面会超出窗口高度（实测 450 > 430）
    @State private var rulesOpen = false
    /// 「我的键盘」选择器（点一下弹出：列出当前检测到的键盘）
    @State private var keyboardsOpen = false

    var body: some View {
        Form {
            Section {
                // 联动靠 kvm-keywatch 盯"某一家的 VID"。换一把别的牌子的键盘，
                // 这个 VID 就对不上 —— 表现是**联动一声不响地完全不动**，
                // 而以前唯一的办法是去手编 config.json。这里改成点一下选。
                LabeledContent(L("我的键盘")) {
                    Button {
                        client.refreshKeyboards()
                        keyboardsOpen = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(client.keyboardIdentityText)
                                .font(.system(size: 12))
                                .foregroundStyle(client.keyboardVendorMatches ? Color.secondary : Color.orange)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("点一下从检测到的键盘里选一把（联动要认准是哪一把）"))
                    .popover(isPresented: $keyboardsOpen, arrowEdge: .bottom) { keyboardPicker }
                }

                LabeledContent(L("提前切屏")) {
                    // 标签本身就写清了状态；术语/条数/时间放在整行的悬停提示里
                    Text(client.keyboardDetectionMode.label)
                }
                .help(client.keyboardDetectionMode.detail)

                Button(client.learnButtonTitle) { client.advanceKeyboardLearn() }
                    .disabled(client.keyboardProbeRunning)
                if client.learnStep != .idle {
                    Button(L("取消学习")) { client.cancelKeyboardLearn() }
                        .foregroundStyle(.secondary)
                }
                // 把"要做什么"列成清单；进行中由下面的动态提示接管，
                // **学完之后也不再显示** —— 那时候这 4 行是噪音，而它占掉的高度
                // 会把"复测结果 + 展开的规则"顶出窗口（实测 450 > 430）。
                if client.learnStep == .idle && client.learnRulesText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("学习步骤"))
                            .font(.system(size: 12, weight: .medium))
                        // 第 1 步是**前置检查**：接法不对、或者键盘的 Fn 切换本身不灵，
                        // 后面怎么学都学不到 —— 先让用户自己确认一遍，比事后猜快得多。
                        StepRow(index: 1, text: L("先确认接法（Win 走无线、Mac 走蓝牙），")
                                 + L("并按键盘上切到 Win / 切回 Mac 的快捷键各切一次，确认两边都能正常打字"))
                        // ⚠️ 顺序是"先点按钮、再按键盘"：状态帧只在切换那一刻发一条，
                        //    采集没有回看 —— 先按后点会把那一帧漏掉。
                        StepRow(index: 2, text: L("点上面那个按钮，然后在 8 秒内按键盘上切到 Win 的快捷键"))
                        StepRow(index: 3, text: L("再点一次，然后在 8 秒内按键盘上切回 Mac 的快捷键"))
                        StepRow(index: 4, text: L("自动算规则并保存（立刻生效）"))
                        StepRow(index: 5, text: L("点「开始复测」验证一遍"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                if !client.learnMessage.isEmpty {
                    // 按行拆开渲染：提示里本来就有 \n，整段塞进一个 Text 会挤在一起
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(client.learnMessage
                                        .split(separator: "\n", omittingEmptySubsequences: false)
                                        .map(String.init).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                if !client.learnRulesText.isEmpty {
                    // 默认收起 —— 规则是"想核对才看"的东西，摆在版面上会占掉一整块，
                    // 把页面顶出窗口变成可滚动（实测：展开时 450pt > 窗口 430）。
                    ExpandRow(title: L("学到的规则"), isOpen: $rulesOpen)
                    if rulesOpen {
                        Text(client.learnRulesText)
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    }
                }
            } header: {
                Text(L("键盘识别"))
            }

        }
        .settingsPageStyle()
        .onAppear {
            client.refreshDisplayInfo()
            client.refreshKeyboards()
        }
    }

    /// 「我的键盘」弹出的选择器：列出 Mac 上现在认到的键盘（按 VID 去重）
    private var keyboardPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("选择你的键盘"))
                .font(.system(size: 12, weight: .medium))
            Text(L("选错了，按键盘上的切换键时屏幕和鼠标不会跟着切。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if client.keyboardCandidates.isEmpty {
                Text(L("现在没检测到键盘 —— 键盘正连在 Win 上时就是这样。切到 Mac 再点「重新检测」。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(client.keyboardCandidates) { candidate in
                    Button {
                        client.chooseKeyboard(candidate)
                        keyboardsOpen = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isCurrent(candidate)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isCurrent(candidate) ? Color.accentColor : .secondary)
                            Text(candidate.displaySummary)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Button(L("重新检测")) { client.refreshKeyboards() }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func isCurrent(_ candidate: KeyboardCandidate) -> Bool {
        KeyboardDetect.parseVendorID(TraiectusConfig.shared.keyboardVendorID) == candidate.vendorID
    }
}

// ============================================================================
//  连接
// ----------------------------------------------------------------------------
//  这块要回答两个问题："现在通不通、连的是谁"（状态块），
//  以及"不通的时候去哪改"（参数）。所以状态放最上面，参数在下。
// ============================================================================

struct ConnectionSettings: View {
    @EnvironmentObject var client: TraiectusClient

    /// 参数默认收起：地址/端口/口令都是"填一次就忘"的东西，正常连着的时候
    /// 不该占着大半屏。连不上时自动展开（见下面的 onChange），平时也能手点开。
    @State private var paramsOpen = false

    /// 菜单栏图标、面板用的是同一套状态（LinkState），这里只是翻译成人话 + 一个颜色点
    private var statusText: String {
        if client.discovering { return L("正在查找 Windows…") }
        // 配对进度优先显示 —— 这时候用户唯一要知道的就是"去 Windows 上点一下"
        if case .requesting = client.pairingState {
            return L("等待在 Windows 上确认…")
        }
        if case .denied(let why) = client.pairingState {
            return L("配对未完成（") + Self.pairingReasonText(why) + L("）")
        }
        switch client.linkState {
        case .connected(let side):
            return side == .mac ? L("已连接 · 鼠标在本机") : L("已连接 · 鼠标在 Windows")
        case .connecting:     return L("连接中…")
        case .windowsOffline: return L("Windows 端未运行")
        case .error:          return L("异常：口令或版本不对")
        }
    }

    /// 服务端回的原因是英文短码，翻译成人话给界面用（太长会把右上角地址挤到折行）
    private static func pairingReasonText(_ why: String) -> String {
        switch why.lowercased() {
        case "timeout":        return L("等太久没确认")
        case "denied":         return L("被拒绝")
        case "already-paired": return L("Windows 已配对过")
        case "busy":           return L("Windows 正忙")
        default:               return why
        }
    }

    /// 参数区下面那句提示。`already-paired` 要单独说 —— 那种情况 Mac 自己解决不了，
    /// 光说"配对没完成"用户不知道下一步该干嘛（必须回 Windows 操作）。
    /// 注意：Mac 上**没有**"手动填口令"这条路了（口令由配对生成），所以不提它。
    private var pairingHint: String {
        if case .denied(let why) = client.pairingState,
           why.lowercased() == "already-paired" {
            // 压到一行：展开态本来就偏高，多一行就会被窗口底部裁掉
            return L("要在 Windows 托盘点「重新配对」，然后回来点「连接」。")
        }
        return L("口令由配对自动生成 —— 在 Windows 上点「允许」即可，不用填任何东西。")
    }

    private var statusColor: Color {
        if case .requesting = client.pairingState { return .orange }
        if case .denied     = client.pairingState { return .red }
        switch client.linkState {
        case .connected:                        return .green
        case .connecting:                       return .orange
        case .windowsOffline, .error:           return .red
        }
    }

    /// 对端地址：优先用填过的，没填就用 config.json 里的默认值
    private var peerText: String {
        let host = client.host.isEmpty ? TraiectusConfig.shared.defaultHost : client.host
        return host.isEmpty ? L("未填写地址") : "\(host):\(client.portText)"
    }

    var body: some View {
        Form {
            Section(L("状态")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).font(.system(size: 13, weight: .medium))
                            .layoutPriority(1)
                        Spacer()
                        Text(peerText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            // 地址不能被折行 —— 宁可让上面那行状态文字换行
                            .fixedSize()
                    }
                    HStack(spacing: 8) {
                        // 按钮跟着状态走：连着的日常动作是"断开"，没连才需要"连接"。
                        if client.isRunning {
                            Button(L("断开")) { client.stop() }
                            Button(L("重新连接")) { client.reconnectNow() }
                        } else {
                            Button(L("连接")) { client.start() }
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                ExpandRow(title: L("连接设置"), isOpen: $paramsOpen)

                if paramsOpen {
                    HStack(spacing: 8) {
                        // 手动触发一次自动发现（广播问 + 扫本网段）。
                        // 平时用不到 —— 地址为空时开机就会自动找；这是给"地址填错了/换网了"用的。
                        // 提示挂**外层容器**：查找中这个按钮是 disabled，
                        // 挂它自己身上的话鼠标放上去不会弹（macOS 的禁用视图收不到悬停）
                        HStack(spacing: 0) {
                            Button(client.discovering ? L("正在查找…") : L("自动检测")) {
                                client.autoDetectPeer()
                            }
                            .disabled(client.discovering)
                        }
                        .contentShape(Rectangle())
                        .help(L("在本机网段里自动寻找 Windows，找到就填到这里并立刻重连"))
                        Spacer(minLength: 0)
                    }
                    SettingField(title: L("Windows 地址"), locked: client.linkState.isOnline) {
                        // TextField 的第一个参数就是占位符（标签被 labelsHidden 藏掉了）
                        TextField(TraiectusConfig.shared.defaultHost.isEmpty
                                  ? "192.168.1.20" : TraiectusConfig.shared.defaultHost,
                                  text: $client.host)
                    }
                    // 口令**没有输入框**：它由配对自动生成并在两端各自保存
                    // （PROTOCOL.md §2.1）。用户看不到、也不需要知道它是什么。
                    // 端口也不在这里 —— 它几乎不用改，收进「高级」了。
                }

                Toggle(L("启动时自动连接"), isOn: Binding(
                    get: { client.autostart },
                    set: { client.setAutostart($0) }
                ))
            } footer: {
                // 收起时不占地方。连着的时侯一句说明都不留 —— 那时候本来也没什么要解释的。
                if paramsOpen && !client.linkState.isOnline {
                    Text(pairingHint)
                        .font(.system(size: 12))
                }
            }
        }
        .settingsPageStyle()
        // 连不上就把参数顶出来 —— 那时候用户唯一要做的就是来改这里
        .onAppear { if !client.linkState.isOnline { paramsOpen = true } }
        .onChange(of: client.linkState) { _, new in
            if !new.isOnline { paramsOpen = true }
        }
        // 配对没成 → 把参数顶出来，用户可以直接手填口令兜底
        .onChange(of: client.pairingState) { _, new in
            if case .denied = new { paramsOpen = true }
        }
    }

    // 这一行参数的排版用一个共享的 SettingField —— 见文件末尾
}

// ============================================================================
//  高级
// ============================================================================

struct AdvancedSettings: View {
    @EnvironmentObject var client: TraiectusClient
    @State private var confirmQuit = false

    var body: some View {
        Form {
            Section {
                // 端口默认 45789、两端一致，只有被别的软件占了才需要改 ——
                // 所以不摆在「连接」页，免得用户以为每次都要管它。
                SettingField(title: L("端口（两端默认 45789）"), locked: client.linkState.isOnline) {
                    TextField("45789", text: $client.portText)
                }
                // 说明放进悬停提示，不占版面 —— 高级页比窗口还高一点，
                // 多一行页脚就会把「退出」挤到窗口外面（实测）。
                .help(client.linkState.isOnline
                      ? L("连接中不可修改 —— 先在「连接」页点「断开」")
                      : L("只有端口冲突时才需要改；改完会自动重连"))
            } header: {
                Text(L("连接参数"))
            }

            Section {
                Button(L("打开日志目录")) { client.openLogsFolder() }
                Button(L("打开配置文件")) {
                    // 文件不存在时先造一份起步配置 —— 否则 Finder 没法"选中不存在的文件"，
                    // 点下去就是"没反应"（用户报过这个）。
                    TraiectusConfig.ensureFileExists()
                    if FileManager.default.fileExists(atPath: TraiectusConfig.path) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: TraiectusConfig.path)])
                    } else {
                        NSWorkspace.shared.open(TraiectusConfig.directory)   // 兜底：至少打开所在目录
                    }
                }
            } header: {
                Text(L("文件"))
            } footer: {
                // 一行写完：高级页要装下三段，页脚多一行就会顶出窗口（实测）
                Text(L("日志在 ~/Library/Logs；硬件参数改 config.json 后重启生效。"))
                    .font(.system(size: 12))
            }

            Section {
                // 退出入口刻意只放在这里，不放主面板：
                // 面板要极简（设计文档 §1），且它是"随手点"的地方，误触退出会直接
                // 断掉键盘联动与鼠标转发，而且菜单栏 app 退出后没有任何界面提示。
                Button(L("退出 Traiectus")) { confirmQuit = true }
                    .confirmationDialog(L("确定退出 Traiectus？"), isPresented: $confirmQuit) {
                        Button(L("退出"), role: .destructive) { NSApp.terminate(nil) }
                        Button(L("取消"), role: .cancel) {}
                    } message: {
                        Text(L("退出后键盘联动、鼠标转发与抢跑都会停止。想再用就双击桌面图标。"))
                    }
            } header: {
                Text(L("退出"))
            }
        }
        .settingsPageStyle()
    }
}

// ============================================================================
//  小组件
// ============================================================================

/// 可折叠的一行：整行可点、箭头够大。
/// 刻意不用原生 DisclosureGroup —— 那个只有小三角本身能点（又小又浅、紧贴文字），
/// 用户明确报过"箭头不好按"。「连接设置」和「学到的规则」共用这一个。
struct ExpandRow: View {
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? L("收起") : L("展开"))
    }
}

/// 一行参数：上面小标签，下面整宽输入框（「连接」页的地址和「高级」页的端口共用）
///
/// ⚠️ 末尾的 `.labelsHidden()` 不能删：macOS 的 Form 会把「VStack{标签, 输入框}」
/// 自动拆成"标签左 + 控件右"两列，输入框缩在右下角、标签只剩 12pt 像注脚。
/// 加上它，Form 才把这一行当成整体，标签在上、输入框占满整行。
struct SettingField<Content: View>: View {
    let title: String
    /// 连上了就锁住；没连上（含正在重试）随时可改，改完自动重连
    let locked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .disabled(locked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden()
    }
}

/// 学习步骤里的一行：左侧序号 + 右侧文字，序号右对齐，各行文字左边缘对齐
struct StepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// 状态行：标题 + 可点的状态（文字 + 圆点）
struct StatusRow: View {
    let title: String
    let status: FeatureStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain)
                .disabled(!status.isActionable)
        }
    }
}

// ============================================================================
//  Xcode 预览（每个标签页单独一份，方便调版式）
// ============================================================================

/// 预览宿主：Xcode 进程的 UserDefaults 跟 app 不共享，所以预览里参数是空的。
/// 需要看"填好参数"的样子时用 `PreviewHost(fill: true)`。
struct PreviewHost<Content: View>: View {
    @StateObject private var client = TraiectusClient()
    private let fill: Bool
    private let content: (TraiectusClient) -> Content

    init(fill: Bool = false, @ViewBuilder content: @escaping (TraiectusClient) -> Content) {
        self.fill = fill
        self.content = content
    }

    var body: some View {
        content(client)
            .frame(width: 460, height: 430)
            .onAppear {
                guard fill else { return }
                if client.host.isEmpty { client.host = "192.168.1.20" }
                if client.token.isEmpty { client.token = "example-token" }
                // 让预览看起来像"已连接"，方便调版式（预览里的真实连接状态没有意义）
                client.winOnline = true
                client.isConnected = true
                client.mouseOnMac = true
            }
    }
}

#Preview(L("设置 · 通用"))        { PreviewHost { c in GeneralSettings().environmentObject(c) } }
#Preview(L("设置 · 键盘"))        { PreviewHost { c in KeyboardSettings().environmentObject(c) } }
#Preview(L("设置 · 连接"))        { PreviewHost { c in ConnectionSettings().environmentObject(c) } }
#Preview(L("设置 · 连接（填好）")) { PreviewHost(fill: true) { c in ConnectionSettings().environmentObject(c) } }
#Preview(L("设置 · 高级"))        { PreviewHost { c in AdvancedSettings().environmentObject(c) } }
#Preview(L("设置 · 整体"))        { PreviewHost { c in SettingsView().environmentObject(c) } }

// ============================================================================
//  显示
// ----------------------------------------------------------------------------
//  单独一个标签页：这段内容（前提说明 + 显示器信息 + 两步学习 + 状态提示）有 170pt 左右，
//  塞进任何一个已有页面都会让那页超出窗口高度、变成可滚动 —— 而"每个页面都不用滚"
//  是明确要求。给它自己一页，谁都挤不着。
// ============================================================================

struct DisplaySettings: View {
    @EnvironmentObject var client: TraiectusClient

    var body: some View {
            // ── 显示器切换 ─────────────────────────────────────────────────
        Form {
            Section {
                // ⚠️ 这句必须放在最前面：它是**前提**，不满足的话下面所有步骤都"点了没反应"，
                //    而"点了没反应"是最难查的一种现象（用户只会觉得软件坏了）。
                // ⚠️ 这里必须用 Text 相加、不能用 **markdown**：Text 只在"字符串字面量"
                // 里解析 markdown，一旦用 + 拼接就走普通 String 重载，星号会原样打出来
                // （实测踩到过）。
                // 注意：.foregroundStyle / .fixedSize 返回的是 some View，不能挂在相加的
                // Text 链里；把整串括起来再套修饰符。
                // 版面上只留"要做什么"；"为什么"（不少型号出厂是关的、不开会点了没反应）
                // 挪进悬停提示 —— 信息还在，但不占地方。
                (Text(L("先在显示器的 OSD 菜单里把 "))
                 + Text(L("DDC/CI 打开")).bold())
                    .help(L("不少型号出厂默认是关的；不开的话下面点了不会有任何反应。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(client.displayInfo.isEmpty ? L("正在读取显示器…") : client.displayInfo)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 学习期间**没有第二个按钮**：切到 Windows 之后 Mac 的界面就不在屏幕上了，
                // 用户不可能再点任何东西 —— 剩下的那半由程序自己轮询认出来。
                if client.displayLearnStep == .idle {
                    Button(L("开始学习显示器切换")) { client.advanceDisplayLearn() }
                } else {
                    Button(L("取消学习")) { client.cancelDisplayLearn() }
                        .foregroundStyle(.secondary)
                }
                if !client.displayLearnMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(client.displayLearnMessage
                                        .split(separator: "\n", omittingEmptySubsequences: false)
                                        .map(String.init).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } header: {
                Text(L("显示器切换"))
            }
        }
        .settingsPageStyle()
        .onAppear { client.refreshDisplayInfo() }
    }
}
