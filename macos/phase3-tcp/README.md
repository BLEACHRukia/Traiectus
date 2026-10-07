# Traiectus Client（Phase 3）—— Mac 端接收并注入鼠标事件

本阶段把 Phase 1 的捕获和 Phase 2 的注入接起来：**连接 Windows 端的 Traiectus Server，把转发过来的鼠标事件注入到这台 Mac。**

协议以仓库根目录的 [`PROTOCOL.md`](../../PROTOCOL.md) 为准。方向是 **Mac 主动连 Windows**（Windows 是监听端）。

---

## 1. 项目结构

```text
macos/phase3-tcp/
├─ README.md                 ← 本文件
├─ build.sh                  ← 编译 + 组装 .app + 签名
├─ Info.plist                ← App 元信息（含局域网权限说明）
└─ src/
   ├─ TraiectusClient.swift    ← TCP/心跳/重连 + 事件注入 + 菜单栏状态
   ├─ KeyboardLink.swift       ← 键盘联动（Fn 键 → 键盘+鼠标+屏幕一起切）
   ├─ SleepHotKey.swift        ← 睡眠快捷键（系统级热键 → 本机睡眠）
   └─ ui/
      ├─ TraiectusApp.swift     ← 菜单栏 app 入口（LSUIElement）
      ├─ PanelView.swift        ← 面板
      ├─ SettingsView.swift     ← 设置窗口
      ├─ ShortcutRecorder.swift ← 设置里的"按一下即录制"快捷键输入框
      ├─ ConnectionDiagram.swift← 面板里的连接可视化
      └─ LinkState.swift        ← 状态模型
```

## 2. 编译

```bash
cd macos/phase3-tcp
./build.sh
```

产物：`build/Traiectus-Client.app`。脚本用 `swiftc` 编译，并用本机自签名证书签名——**重新编译不会丢失辅助功能授权**（原理见 [`../phase2-cgevent/README.md`](../phase2-cgevent/README.md) 第 9 节）。

## 配置：换硬件只改这里（config.json）

以前这些值写死在源码里，换显示器 / 换键盘 / 换工具安装位置都得改代码重编。现在统一走一个配置文件：

- **位置**：`~/Library/Application Support/Traiectus/config.json`
- **模板**：[`../../config.example.json`](../../config.example.json)（复制过去改）

```json
{
  "display": { "macInput": "17", "windowsInput": "15" },
  "keyboard": { "vendorID": "0x1B1C" },
  "tools":    { "keywatch": "", "m1ddc": "", "dwc": "" },
  "network":  { "defaultHost": "" }
}
```

| 字段 | 作用 | 默认 |
|---|---|---|
| `display.macInput` | Mac 那一侧的显示器 DDC/CI 输入源编号 | `17`（HDMI-1） |
| `display.windowsInput` | Windows 那一侧的输入源编号 | `15`（DP-1） |
| `keyboard.vendorID` | 监听哪家厂商的键盘（用来判断键盘在不在 Mac 上） | `0x1B1C`（Corsair） |
| `tools.keywatch` / `m1ddc` / `dwc` | 三个外部工具的位置；留空 = 用 app 内置的 | 留空 |
| `network.defaultHost` | 设置窗口里预填的 Windows 地址 | 留空 |

- 文件不存在 / 写错 / 只写一部分 → 缺的字段一律用默认值，**不影响运行**
- 改完重启 app；启动日志里的 `[配置] …` 那一行会显示实际生效的值
- 输入源编号因显示器而异：`m1ddc get input` 能读当前值，或者翻显示器说明书
- 签名身份也能覆盖：`TRAIECTUS_SIGN_IDENTITY=… TRAIECTUS_SIGN_HASH=… ./build.sh`

## 3. 运行与授权

```bash
open "build/Traiectus-Client.app"
```

这是一个**新的 App**（bundle id `com.minikvm.client`），所以要单独授权一次：

1. 点窗口里的 **「请求权限」**
2. 系统设置 → 隐私与安全性 → **辅助功能** → 打开 **Traiectus Client**
3. **退出 App 再重新打开**（权限只在启动时读取）

另外从 macOS 15 起，**首次连接局域网地址时会弹「允许访问 Traiectus Client 访问本地网络？」——要选允许**，否则连不上 Windows。回环地址（127.0.0.1）不受此限制。

窗口里填三样东西：**Windows 的 IP、端口（默认 45789）、口令（与 Windows 端一致）**，然后点「连接」。

## 4. 不用 Windows 也能验证这个客户端

仓库里带了一个模拟 Windows 服务端的测试脚本，可以在 Mac 上单独把客户端跑通：

```bash
# 终端 1：起一个假的 Traiectus Server
python3 tools/traiectus-test-server.py --port 45789 --token test123 --demo --duration 30

# 终端 2：让客户端自动连上去（--args 里的 -键 值 会作为临时偏好读入）
open "macos/phase3-tcp/build/Traiectus-Client.app" --args \
     -minikvm.autostart YES -minikvm.host 127.0.0.1 -minikvm.token test123
```

`--demo` 会让假服务端画一个方形、点一次左键、滚一次滚轮。**光标真的动起来，就说明"连上 → 解析 → 注入"这条链路是通的。**

> ⚠️ **必须用 `open` 启动（等价于双击），不要从终端直接运行 `build/Traiectus-Client.app/Contents/MacOS/TraiectusClient`。**
>
> 从终端直接跑这个二进制时，macOS 会把"权限主体"算到**启动它的那个进程**（终端）头上，于是程序自己 `AXIsProcessTrusted()` 读到的是"未授权"，注入的 `CGEvent` 被系统**静默丢弃**——而同一个 App 用 `open` 启动时明明是"已授权"、工作正常。
>
> 这个坑我们实际踩过一次，排查花了不少时间。所以：
> - 想从命令行启动，用 `open <app> --args ...`，让它由 launchd 拉起；
> - 程序会把自己的日志额外写一份到 `~/Library/Logs/TraiectusClient.log`，不管是谁启动的，事后都能读到它自己看到的真实状态（比如权限结论）。

脚本另外还有一个专门用来验证故障保护的开关：

```bash
python3 tools/traiectus-test-server.py --port 45790 --token test123 --stick-button
```

它会发出一次 `DOWN L` 之后**直接断开、不给抬起**。客户端的日志里应当出现 `补发抬起（防止按键卡住）：L` —— 这条保护防止"Mac 上左键卡住、所有点击都变成拖拽"。

日志同时出现在三个地方：App 窗口、stderr（从终端启动时可见）、以及 `~/Library/Logs/TraiectusClient.log`（超过 1 MB 会重开）。

## 5. 代码里几个值得知道的设计

| 设计 | 为什么 |
|---|---|
| 按 `\n` 切分、残包留在缓冲区（`LineFramer`） | 一次 `recv` 可能拿到半行、一行或多行；不做分帧就会随机丢事件 |
| 断开时 `releaseAllHeldButtons()` | 协议只发按下/抬起，接收端持有"当前按住哪些键"的状态；不清理就会按键卡死 |
| 滚轮零头累积（够 120 才滚一格） | 高分辨率滚轮会送来 `±1` 之类的小值，直接丢弃就完全滚不动 |
| 按住键移动时改发 `.leftMouseDragged` / `.rightMouseDragged` / `.otherMouseDragged` | 一直发 `.mouseMoved` 的话，系统只当"光标在移动"、不认为是拖拽——表现就是**拖不动文件、拖不动选中的文字、拖不动窗口标题栏**（这个 bug 真机上被发现过一次） |
| 心跳 1 秒 / 超时 3 秒 | 拔网线、对端睡眠时 TCP 不会自己报错，必须靠心跳发现 |
| 重连退避 0.25 → 0.5 → 1 秒封顶 | 快速恢复，同时不会把日志和 CPU 刷爆 |
| 连接失败日志抑制 | Windows 没开机时会一直重连，不必每秒打一行 |
| 位移用"读当前坐标 + 增量"实现 | 协议只发相对增量，避免两端分辨率换算不一致导致指针跳变 |
| 睡眠快捷键用 Carbon `RegisterEventHotKey`，**不用**系统设置的「服务」快捷键 | 服务快捷键由 pbs 注册，优先级低于前台 App 的菜单快捷键：Finder 的 ⌘1 是「显示为图标」、浏览器是「第一个标签页」，事件根本轮不到服务。系统级热键在窗口服务器层就被接走，任何界面下都生效 |
| 睡眠走 `osascript → System Events`，兜底 `pmset` | 前者普通用户权限即可，后者多数系统要 root。首次触发会弹一次"想控制「系统事件」"，被拒绝时设置里显示「需要授权」 |

## 6. 已知限制（如实说明）

1. **手感是线性的**：Windows 送来的原始计数被 1:1 注入，不加加速曲线，所以比直接用 Mac 鼠标"直"。
2. **坐标被限制在主显示器内**：反复撞屏幕边缘再回来，会与 Windows 侧位置产生偏移。真正的解法（边缘切换 / 位置同步）属于后续阶段。
3. **中键与侧键**走 `otherMouseDown/Up`（button 2/3/4）。中键已实测可用；侧键在部分 App 里可能不被识别，属于 macOS 的映射问题。
4. **安全桌面**（UAC、锁屏）收不到输入，这是系统设计。
5. **键盘不转发**，由硬件切换。
6. **非当前窗口的第一次点击会被系统吞掉**——这是 macOS 的通用行为，不是本项目的问题：用 Windows 鼠标点 Traiectus Client 窗口左上角那三个红绿灯按钮时，**第一下只用来激活窗口**，要点第二下才生效（内容区按钮同样如此）。想一下点到：先点窗口任意位置激活它，或先用键盘切到该 App。

## 7. 实测记录（2026-09-24）

### 7.1 协议层（用 `tools/traiectus-test-server.py`，回环地址 127.0.0.1）

| 验证项 | 结果 |
|---|---|
| TCP 连接 + 握手（`HELLO 1 Mac test123` → `HELLO-OK 1`） | ✅ |
| 双向心跳（客户端每秒 PING、服务端 PING 也被正确回 PONG） | ✅ 往返 0.2–0.4 ms（回环） |
| `MOVE` / `DOWN` / `UP` / `WHEEL` 发送与解析 | ✅ |
| 收到 `BYE` 后进入重连 | ✅ |
| 重连退避间隔 | ✅ 实测 0.27 / 0.53 / 1.07 秒，与设计的 0.25 → 0.5 → 1 秒封顶一致 |
| 断开时补发抬起 | ✅ 日志出现 `补发抬起（防止按键卡住）：L` |
| 长时间连不上时的日志抑制 | ✅ 只在前两次和每第 10 次打印（`连接失败（第 50 次）`…） |

### 7.2 注入效果（授权后，判据是 `tools/mouse-event-probe.html` 上显示的数字）

| 验证项 | 结果 |
|---|---|
| 移动：光标画出一个 120×120 的方形并**回到原位** | ✅ 目视确认 |
| 左键 | ✅ 观察页记录 `左键 按下 button 0`（点页面上的复制按钮时产生的真实点击） |
| 右键 | ✅ 目视确认（弹出了右键菜单） |
| 中键 | ✅ 观察页记录 `中键 按下 button 1 @ (580,548)` |
| 滚轮上 | ✅ 观察页记录 `滚轮向上 deltaY=-40`（负 = 向上） |
| 滚轮下 | ✅ 观察页记录 `滚轮向下 deltaY=+40`（正 = 向下） |
| 与真实 Windows 端联调 | ⏳ 待 Windows 端编译后进行 |

> **滚轮数值的含义**：客户端把一格（协议里的 120）映射成若干个"行"（`EventInjector.linesPerDetent`），
> 浏览器再把它折算成像素（1 行 ≈ 40 px）。实测 2026-09-24：**该常量已从 1 调到 3**——
> 1 行时一格只滚 40 px 偏慢，3 行时约 120 px，与真实鼠标一格的手感接近。
> 这是纯手感参数，改这一个常量即可（想更快改 4，觉得太快改 2），不影响协议与正确性。

> **一个花了些时间才定位的坑**：最初用"从终端直接运行 `.app` 里的二进制"来验证时，程序自己报告的是"未授权"，于是以为授权没生效、反复重装授权；实际上 macOS 把权限主体算到了**启动它的那个进程**头上。改用 `open` 启动后一切正常。详见第 4 节的警告。

## 8. 我需要你回报什么（然后进入 Phase 4）

1. ~~`./build.sh` 是否成功~~ → ✅ 见第 7 节
2. ~~辅助功能权限是否给上~~ → ✅ 已授权（本地网络权限要等连真实 Windows 时才用得上）
3. ~~用 `tools/traiectus-test-server.py --demo` 自测~~ → ✅ 方形、左键、右键、中键、滚轮全部通过（见第 7.2 节）
4. **与 Windows 端联调**（还没做）：移动、左键、右键、中键、侧键、滚轮是否都正确
5. **故障场景**（还没做）：拔网线 / 关掉一端 / 强杀服务端之后，两边的鼠标是否都立刻恢复正常

> 第 4、5 项需要 Windows 端先编译出来，见 [`../../windows/phase3-tcp/README.md`](../../windows/phase3-tcp/README.md)。

## 9. 按 macOS 惯例安装（推荐）

```sh
./build.sh          # 编译出 build/Traiectus.app
./install-app.sh    # 安装到 ~/Applications + 建登录项（登录后自动启动）
./install-app.sh remove   # 卸载（移除登录项与已安装副本）
```

**为什么这样装**：这是 macOS 上"常驻菜单栏工具"的标准姿势 —— app 装在 `~/Applications`，
登录时由 `~/Library/LaunchAgents/com.minikvm.client.plist` 自动拉起，平时只从**菜单栏图标**
访问。**不需要**（也不建议）在桌面放 app 或快捷方式：桌面在 macOS 里只是普通文件夹，
而且 macOS 26+ 对桌面上的"别名"会走旧格式图标路径，容易出现"桌面灰、Dock 透明"这种
同一个 app 两副面孔的问题。

启动方式（任选）：菜单栏图标 / Dock（如果你把它拖进去）/ `⌘ + 空格` 搜 "Traiectus" /
访达 → 应用程序。

> `install-app.sh` 是**原地更新**（不整包删），保持 bundle inode 稳定，这样图标缓存、
> LaunchServices 记录和 Dock 项都不会失效。此外它用 `/usr/bin/open` 启动，
> 保证 app 的 TCC 身份（辅助功能 / 本地网络）与手动双击一致。
