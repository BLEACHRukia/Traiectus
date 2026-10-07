# MiniKVM 软件实现 · 完整技术文档

> **历史记录**：本文写于产品名为 MiniKVM 的时期（2026-09-29 正式改名为 **Traiectus**）。
> 正文保留当时的原名/路径，以免记录失真；当前名称与路径见 `README.md`。


**日期**：2026-09-26　**仓库**：`~/Documents/ChatGPT/Traiectus`　**最新提交**：`1bbd4f3`
**适用环境**：Windows 10/11（WIN-PC，192.168.1.20）＋ macOS 27（Mac mini，192.168.1.10），同一局域网

---

## 0. 一句话概述

把 Windows 上的鼠标**通过局域网转发**给 Mac（相对位移 + 按键 + 滚轮，注入为原生 CGEvent），
并在此之上做了一层**KVM 联动**：按键盘的 `Fn+Caps` / `Fn+T` 时，**键盘 + 鼠标 + 显示器**一起切到目标机器，
两端光标都归到屏幕中心。整条链路**不装驱动、不改系统设置、不拦截输入**。

---

## 1. 目标与范围

| 目标 | 状态 |
|---|---|
| Windows 鼠标转发到 Mac（移动/左右中键/侧键/滚轮） | ✅ 已实现并长期使用 |
| Mac 模式下 Windows 光标不干扰（锁定） | ✅ `ClipCursor`，带看门狗兜底 |
| 控制权切换 `Ctrl+Alt+M`（Windows 侧热键） | ✅ |
| **一次 `Fn` 按键 → 键盘 + 鼠标 + 屏幕联动** | ✅ 已实测通过 |
| 切换时两端光标归到屏幕中心 | ✅ |
| 显示器输入源切换（Mac→Windows / Windows→Mac） | ✅ 由 Mac 侧一条命令完成（实测双向可用） |
| 不做的东西 | 不装驱动/内核扩展、不 hook、不改注册表/防火墙（防火墙规则由用户自己执行脚本添加）、不碰游戏输入路径 |

---

## 2. 系统架构

```text
  ┌────────────── Windows (192.168.1.20) ──────────────┐        ┌────────── Mac (192.168.1.10) ──────────┐
  │                                                      │        │                                          │
  │  GPW2 鼠标 ──(无线接收器)──► Raw Input（只读）        │        │                                          │
  │                              │                       │        │                                          │
  │                    MiniKVM-Server.exe                │        │   MiniKVM Client.app                     │
  │                     · TCP 45789 服务端 ──────────────┼── TCP ─┼──► · 连接/心跳/协议解析                  │
  │                     · UDP 45791 控制通道 ◄───────────┼─ UDP ──┼──  · CGEvent 注入（辅助功能权限）        │
  │                     · SetControlMode（锁定/归中）     │        │   · KeyboardLink（联动，本文件 §6.3）     │
  │                                                      │        │        │                                 │
  │  K70 键盘接收器（VID 1B1C / PID 1BA6）                │        │        ├─► m1ddc set input 15/17         │
  │      └─ FF42/02 状态帧 ──► 桥接（后台静默）           │        │        ├─► 光标居中（CGWarp+Associate）  │
  │                             · UDP 45790 ─────────────┼─ UDP ──┼──►     └─► 发 MODE Mac/Win 给服务端      │
  │                             · 心跳 + 回包中继 → 127.0.0.1:45791      │   · kvm-keywatch（IOKit 事件子进程）│
  └──────────────────────────────────────────────────────┘        └──────────────────────────────────────────┘
                                                    │
                                                    └──► ASUS VG249Q 显示器（HDMI=Mac / DP=Windows，DDC/CI VCP 0x60）
```

**四个常驻部件**：

| 部件 | 平台 | 文件 | 作用 |
|---|---|---|---|
| MiniKVM-Server | Windows | `windows/phase3-tcp/src/main.cpp`（1376 行） | 捕获鼠标 → 转发；接受 `MODE` 请求；锁定/归中 Windows 光标 |
| KVM 桥接 | Windows | `windows/kvm-bridge/KvmBridge.ps1`（388 行） | 读接收器状态帧 → 抢跑通知 Mac；心跳/回包中继 |
| MiniKVM Client | macOS | `macos/phase3-tcp/src/MiniKVMClient.swift`（908 行）+ `KeyboardLink.swift`（294 行） | 注入鼠标事件；键盘联动（切屏/切鼠标/光标居中） |
| kvm-keywatch | macOS | `macos/kvm-link/kvm-keywatch.c`（126 行） | 订阅 IOKit 设备接入/移除事件（毫秒级），供联动检测 |

---

## 3. 硬件与网络（实测事实）

| 项 | 值 |
|---|---|
|---|---|
| 鼠标 | 罗技 GPW2，无线接收器 `VID_046D&PID_C547`（Windows），有线 `PID_C094`（Mac） |
| 键盘 | Corsair K70 Pro Mini：USB 直连 `VID_1B1C/PID_1BB6`；蓝牙 `0x1B6E`（Mac 是 BT Host 1）；接收器 `1BA6` |
| 接收器厂商接口 | `usagePage 0xFF42`：`usage 0x01`（input/output 各 65 字节）、`usage 0x02`（input 65，output 0） |
| 显示器 | ASUS VG249Q：HDMI-1 = Mac（VCP `0x60` = 17），DP-1 = Windows（= 15）；DDC/CI 可用 |
| 网络 | 同一 /24 局域网；Windows 防火墙对入站 UDP 默认拦截（本文有专门一节） |

---

## 4. 通信协议（权威定义见 `PROTOCOL.md`）

### 4.1 传输与握手

- TCP，端口 **45789**（`--port` 可改）；UTF-8；**一行一条消息**，`\n` 结尾；单行 ≤ 256 字节
- Mac 主动连接，第一句必须是 `HELLO <版本> <角色> <口令>`，服务端回 `HELLO-OK <版本>` 或 `ERR AUTH`
- 心跳：`PING <id>` / `PONG <id>`，任一端 3 秒无数据即判死

### 4.2 事件消息（服务端 → 客户端）

```text
MOVE <dx> <dy>      相对位移（原始计数，含加速前的线性手感）
DOWN <键名> / UP <键名>   L / R / M / X1 / X2
WHEEL <delta> / HWHEEL <delta>   一格 = 120；接收端累积零头
MODE <Win|Mac>      控制权在哪一端（切换时与握手后各发一次）
```

### 4.3 控制权模式

| 模式 | 服务端行为 |
|---|---|
| `Win`（默认） | 不转发、不锁定 → Windows 完全原生（打游戏就是这个状态） |
| `Mac` | 转发事件 + `SetCursorPos(主屏中心)` + `ClipCursor(中心点 1×1)` |

**双向可请求**（协议仍为版本 1，向后兼容）：

- Windows 侧热键 `Ctrl+Alt+M`（`RegisterHotKey`）
- **客户端请求**：Mac 发 `MODE Mac|Win`，服务端走与热键完全相同的 `SetControlMode()`（这是联动的基础）

### 4.4 抢跑通道（Windows → Mac，UDP 45790）

接收器在每次键盘连接模式变化时**主动吐一帧**（实测）：

```text
00 00 01 36 00 <mode>      命令 01 36；mode = 02 → 键盘去 Windows，00 → 键盘回 Mac
```

- Windows 侧实测比 macOS 的蓝牙 REMOVE 事件**早 1.56~1.82 秒**（跨机时钟差 0.43 秒已按两侧共有样本校正）
- 桥接把该帧转成 UDP 文本发给 Mac：`KEY <前 8 字节 hex>`；另有每 2 秒的 `HB` 心跳
- Mac 侧若抢跑，则提前切屏；随后到达的蓝牙事件被"过渡态"吸收，不会重复动作

### 4.5 控制通道（UDP 45791，服务端本地）

```text
MODE <Mac|Win> <口令>      → 服务端执行切换并回 OK
PING                      → 回 PONG（供自检）
```

**为什么走这个通道**：Mac 的 `MODE` 可以直接走 TCP 那条连接（联动就绪后采用）；
但独立 UDP 通道便于脚本化测试与自检。**入站 UDP 默认被 Windows 防火墙拦**，
因此另做了"桥接回包"兜底：桥接每 2 秒给 Mac 发心跳，Mac **回到该地址**（命中防火墙 UDP 状态记忆），
桥接再转发到 `127.0.0.1:45791`（回环不经防火墙）。这条兜底在 app 版联动之后已非必需。

---

## 5. Windows 侧实现

### 5.1 鼠标捕获（只读）

- `RegisterRawInputDevices(usagePage 0x01, usage 0x02, RIDEV_INPUTSINK | RIDEV_DEVNOTIFY)`：
  **只读取**，不 hook、不拦截；别的程序（含游戏）照常拿到输入
- `--device` 过滤（如 `VID_046D&PID_C547&MI_00`），避免把 Corsair 键盘的鼠标类 collection 混进来
- 相对位移直接用 `RAWMOUSE.lLastX/lLastY`（未经系统加速）

### 5.2 发送路径

- 事件行进队列，网络线程 `select` 超时 **1 ms**（历史缺陷：曾固定 200 ms，用户主观感受"明显流畅很多"是修掉它之后）
- 打开 `TCP_NODELAY`，队列上限 8192 行（防对端消费不过来时无限增长）

### 5.3 控制权切换（`SetControlMode`）

```cpp
进 Mac 模式：SetCursorPos(主屏中心) → ClipCursor(中心 1×1) → 广播 MODE Mac → 开始转发
回 Win 模式：补发所有按下的抬起 → 广播 MODE Win → ClipCursor(nullptr) → SetCursorPos(主屏中心)
```

- **顺序不可反**：先移动/锁定再开始转发，否则切换瞬间 Windows 光标会乱跳
- **看门狗**：`ClipCursor` 在进程被强杀时不会自动解除 → 启动一个子进程监视主进程句柄，
  主进程消失即 `ClipCursor(nullptr)`（200 ms 内解除）

### 5.4 控制通道线程

`ControlThread()`：`bind(0.0.0.0:45791)` → `select` 200 ms 轮询 → 解析 `MODE/PING` →
口令校验（与 `--token` 一致）→ 调 `SetControlMode()` → 回 `OK`。

### 5.5 桥接（KvmBridge.ps1）

| 功能 | 实现 |
|---|---|
| 读接收器状态帧 | SetupAPI 枚举 `VID 0x1B1C` + `usagePage 0xFF42` 的接口，对每个接口起一个**阻塞 `ReadFile`** 线程（65 字节报告） |
| 抢跑通知 | 收到帧 → UDP 发 `KEY <hex>` 到 Mac:45790 |
| 心跳 | 每 2 秒发 `HB`（维持防火墙回包状态 + 让 Mac 记住桥接地址） |
| 回包中继 | 收到 Mac 的 `MODE ... ` → 转发到 `127.0.0.1:45791` 并把服务端回执写日志 |
| 后台化 | `安装桥接后台自启.bat`：复制到 `%LOCALAPPDATA%\MiniKVM\`、写隐藏启动的 VBS（窗口样式 0）、在"启动"文件夹建快捷方式 |

---

## 6. Mac 侧实现

### 6.1 连接与协议

`NWConnection` 连接、`LineFramer` 分帧、1 秒心跳、3 秒判死、≤1 秒退避重连、`BYE` 礼貌退出。
收到 `MODE Win` 会先补发所有按下的键抬起（防止切换瞬间卡键），再忽略后续事件行。

### 6.2 鼠标注入（`EventInjector`）

- 相对位移 → 读当前光标位置 + 增量 → **注入绝对坐标**（macOS 不对注入坐标做加速，手感 1:1）
- **按住键移动必须发 `*MouseDragged` 事件类型**（否则拖不动文件/选中文字 —— 已修）
- 滚轮一格 = 120 → 3 行（手感调整，常量 `linesPerDetent`）
- 依赖**辅助功能权限**（`AXIsProcessTrusted()`）；未授权时事件会静默丢弃（日志里能看到"注入 0.0"）

### 6.3 键盘联动（`KeyboardLink.swift`，本次新增）

```text
输入：  kvm-keywatch 的子进程输出（ADD/REMOVE <transport>）+ UDP 45790 的抢跑帧
状态：  "bt"（蓝牙挂在 Mac）/ "usb"（有线插在 Mac）/ nil（不在 Mac 上）
去抖：  0.35 秒；抢跑命中后进入"等蓝牙跟上"的过渡态（8 秒兜底）
动作：  ① m1ddc set input 15|17（切屏）  ② CGWarp 光标到主屏中心 + 重新关联
        ③ 发 `MODE Win|Mac` 给服务端（经自己那条 TCP 连接，协议 §4.3）
```

为什么必须靠"键盘归属"推断：`Fn` 是键盘固件内部的修饰键，**主机收不到** `Fn+T` 这个事件。

### 6.4 光标居中与一个必须记住的坑

`CGWarpMouseCursorPosition()` 会**把光标与鼠标解绑**（macOS 已知行为）：
之后即使事件注入正常，指针也会卡住，甚至几秒后"看不见"（系统把无鼠标输入当空闲，自动隐藏指针）。
**必须补一句 `CGAssociateMouseAndMouseCursorPosition(1)`** —— 这个坑当天造成过一段"注入正常但鼠标不动"的排查。

### 6.5 显示器切换工具选择

| 工具 | 启动耗时 | 说明 |
|---|---|---|
| **m1ddc**（[waydabber/m1ddc](https://github.com/waydabber/m1ddc)，MIT，单文件 C） | **~5 ms** | 采用（已 vendored 到 `macos/kvm-link/m1ddc/`） |
| dwc（ASUS 官方 Display Control CLI） | 300~400 ms | 回退方案（内部要跑 system_profiler 枚举显示器） |

`m1ddc set input 15|17`，与显示器 VCP `0x60` 语义一致。

### 6.6 kvm-keywatch

`IOHIDManager` 订阅 `VID 0x1b1c` 的接入/移除 + `CGDisplayRegisterReconfigurationCallback` 显示器事件；
输出带 **epoch 毫秒时间戳** 的行；另有 `--center` 子命令（切屏后居中光标）。
实测：键盘一动，事件在 **~22~30 ms** 内到达，软件总反应 ≤ 50 ms。

---

## 7. 关键时序与性能实测（2026-09-26）

### 7.1 一次 `Fn+Caps`（键盘去 Windows）

```text
用户按键
  └─ Windows 接收器状态帧（02）          08:48:15.901   ← 最早的可用信号
  └─ 桥接 → UDP → Mac 抢跑切屏             +几 ms（m1ddc 68~88 ms）
  └─ Mac 发 MODE Win → 服务端生效          +10~25 ms
  └─ macOS 蓝牙 REMOVE（迟到）            08:48:17.172   ← 比 Windows 信号晚 1.27~1.82 秒（被过渡态吸收）
```

### 7.2 一次 `Fn+T`（键盘回 Mac）

```text
用户按键
  └─ 接收器状态帧（00）/ 蓝牙 ADD         几乎同时（Windows 仅早 0.13~0.28 秒）
  └─ Mac 切屏（HDMI）+ 光标居中 + MODE Mac  +30~90 ms（软件侧）
  └─ 显示器 HDMI 重新同步                  ~0.5~0.7 秒 ← 硬件；主观"约 1 秒"
```

### 7.3 分项实测数字

| 环节 | 实测 |
|---|---|
| kvm-keywatch 检测延迟 | 22~30 ms |
| 抢跑（Windows 领先量） | **1.56~1.82 秒**（去 Windows 方向） |
| 切屏工具耗时 | m1ddc 53~88 ms（dwc 300~400 ms） |
| MODE 请求 → 服务端生效 | 10~25 ms |
| 转发注入率 | 45~142 事件/秒（随鼠标移动速度） |
| TCP 往返 | 4~30 ms（局域网） |
| 显示器切换事件（CoreGraphics） | 全程未触发 → 说明 Mac 侧在该方向没有额外软件环节 |

---

## 8. 部署与运行手册

### 8.1 Windows（两件东西）

```
1) MiniKVM-Server.exe（带控制通道的新版）
   共享目录 phase3-tcp → 双击 build-mingw.bat → 双击 start-server.bat
   启动横幅必须出现：控制通道：UDP 45791

2) 桥接（后台静默，无需窗口）
   共享目录 → 双击 安装桥接后台自启.bat   （安装到 %LOCALAPPDATA%\MiniKVM 并加入"启动"）
   日志：\\192.168.1.20\SHARED\KvmBridge.log（共享不可用时写本地）
   （想恢复可见窗口版：卸载桥接后台自启.bat，再双击 桥接-启动.bat）
```

### 8.2 macOS（一个 app）

```
1) 双击桌面 MiniKVM Client（或 build/MiniKVM-Client.app）
2) 授权：系统设置 → 隐私与安全性 → 辅助功能 → 打开 MiniKVM Client
   （签名已改为稳定的自签证书，重编 app 不会再让授权失效）
   （"输入监控"不需要；"本地网络"首次会弹窗，选允许）
3) 勾选「启动时自动连接」+「键盘联动」
4) 鼠标保持无线（线插在 Mac 上会变成有线模式 → Windows 收不到 → 转发无数据）
```

### 8.3 使用

```text
Fn + Caps Lock   →  键盘 + 鼠标 + 屏幕 一起去 Windows（屏幕提前约 1.5 秒切）
Fn + T           →  三样一起回 Mac（屏幕约 1 秒，显示器 HDMI 同步）
（手动兜底：Ctrl+Alt+M 在键盘连着 Windows 时切换鼠标控制权）
```

---

## 9. 构建与签名（macOS 侧）

| 主题 | 要点 |
|---|---|
| 编译 | `macos/phase3-tcp/build.sh`（swiftc，arm64，`-parse-as-library`） |
| **CLT 的 SDK 与编译器版本不匹配** | 报 `this SDK is not supported by the compiler`；`make-shadow-sdk.sh` 生成"影子 SDK"（软链系统 SDK，只把 Swift 核心模块接口的 swiftlang/clang 版本号改成当前编译器版本），`build.sh` 自动回退使用；同时加 `-module-cache-path`（沙箱/权限导致模块缓存写不进去也会失败） |
| 签名 | 自签证书 `MiniKVM Dev Code Signing`（`make-signing-identity.sh` 生成：openssl 产带 Code Signing EKU 的证书 → 导入登录钥匙串 → 标记为代码签名受信任）。钥匙串里存在同名旧证书会导致 `ambiguous`，故 `build.sh` **按证书哈希签名**（`SIGN_HASH=E34CB080…`） |
| 为什么重要 | ad-hoc 签名每次重编都会让「辅助功能」授权失效；固定证书后授权长期有效 |

Windows 侧：`build-mingw.bat`（w64devkit g++，无需管理员）或 `build.bat`（MSVC）。

---

## 10. 已知限制 / 未解问题

1. **"回 Mac"方向约 1 秒** —— 键盘固件切换 + 显示器 HDMI 重新同步，属硬件；Mac 只有 HDMI 口，无法用"换口对比"优化
2. **`Ctrl+Alt+M` 只在键盘连着 Windows 时有效**（热键由 Windows 侧注册）
3. **鼠标必须无线**才能被转发（线插 Mac → 有线模式 → Windows 无数据）
4. **U 盘/开机自启**：Mac app 目前需手动打开一次（可再加登录项）；Windows 桥接已自启
5. **安全桌面**（UAC、锁屏）下用户态收不到 Raw Input，属系统设计
6. **接收器的连接模式命令**（`01 3A`）不被该接收器执行（16 个路由字节都试过）→ 键盘切换只能靠 `Fn` 键（物理），
   软件只负责"跟着切换"（这也是整套联动设计的出发点）

---

## 11. 排错手册（症状 → 原因 → 处置）

| 症状 | 可能原因 | 处置 |
|---|---|---|
| Mac 光标不动、日志 `注入 0.0` | 模式还在 Win | 确认联动已勾选；或手动在键盘连着 Windows 时按 `Ctrl+Alt+M` |
| Mac 光标不动、日志 `注入 > 0` | 辅助功能未授权 / 光标被 warp 解绑 | 授权后重启 app；或跑 `kvm-keywatch --center`（会补上重新关联） |
| 桥接日志 `NO ACK ... ConnectionReset` | 服务端不是带控制通道的新版 | 用共享目录的 `重编并启动服务端.bat` |
| 桥接日志 `NO ACK ... TimedOut` | 服务端在跑但控制通道无响应 | 检查服务端启动横幅有没有 `UDP 45791` |
| 桥接日志一条 `Mac -> bridge` 都没有 | 桥接没在跑 | 双击 `安装桥接后台自启.bat`（或临时用 `桥接-启动.bat`） |
| Mac app 日志没有 `⚡ Windows 抢跑` | 后台桥接没起来 / UDP 45790 被占 | 同上；确认 app 里「键盘联动」已勾 |
| 屏幕不切 | m1ddc/dwc 路径找不到 | 看 app 日志的 `[联动] ⚠ 找不到 ...`；检查 `macos/kvm-link/m1ddc/m1ddc` 是否存在 |
| 键盘跑掉、Mac 完全没键盘 | —— | 键盘上 `Fn+T`（回 Mac 蓝牙）/ `Fn+Caps`（去 Windows）；或按显示器机身按键切输入源 |

---

## 12. 附录

### 12.1 端口表

| 端口 | 协议 | 方向 | 用途 |
|---|---|---|---|
| 45789 | TCP | Mac → Windows | 事件/心跳/握手/MODE 请求 |
| 45791 | UDP | Mac → Windows（或本机回环） | 服务端控制通道（`MODE`/`PING`） |
| 45790 | UDP | Windows → Mac | 抢跑帧（`KEY ...`）与心跳（`HB`） |

### 12.2 关键文件清单

```text
windows/phase3-tcp/src/main.cpp            服务端（1376 行）：Raw Input、TCP、控制通道、光标锁定
windows/kvm-bridge/KvmBridge.ps1           桥接（388 行）：状态帧→抢跑、心跳/回包中继
windows/control-channel/*.bat              防火墙放行 / 一键重编并启动服务端
windows/kvm-bridge/安装桥接后台自启.bat     桥接后台静默 + 开机自启
macos/phase3-tcp/src/MiniKVMClient.swift   客户端（908 行）：连接、注入、UI
macos/phase3-tcp/src/KeyboardLink.swift    联动（294 行）
macos/kvm-link/kvm-keywatch.c              IOKit 事件订阅 + --center（126 行）
macos/kvm-link/m1ddc/                      DDC 工具（MIT，vendored）
macos/phase3-tcp/build.sh                  编译 + 影子 SDK 回退 + 证书签名
macos/phase3-tcp/make-shadow-sdk.sh        影子 SDK 生成
macos/phase3-tcp/make-signing-identity.sh  自签代码签名证书
PROTOCOL.md / 联调记录.md / README.md       协议、全部实测记录、项目总览
```

### 12.3 日志位置

| 日志 | 路径 |
|---|---|
| Mac 客户端 | `~/Library/Logs/MiniKVMClient.log`（含注入率、往返、联动动作） |
| Windows 服务端 | 控制台窗口 |
| 桥接（后台） | `\\192.168.1.20\SHARED\KvmBridge.log` |
| 联动（Python 版，备用） | `~/Desktop/kvm-link-live.log` |

### 12.4 本次相关提交（节选）

```text
1bbd4f3  稳定签名证书 + 桥接后台静默自启
99c8d72  把键盘联动做进 Mac app
568c847  记录：完整联动验证通过（连续三次）
1c20b52  修复 Mac app 编译（影子 SDK）
62a3d43  切换时两端光标归中 + 协议增加客户端 MODE 请求
13e9ae9  鼠标联动改走"桥接回包"通道（绕过防火墙）
ce96e19  切屏改用 m1ddc（省掉 300~400 ms）
efaf247  KVM 桥接（抢跑 → Mac 切屏）
```
