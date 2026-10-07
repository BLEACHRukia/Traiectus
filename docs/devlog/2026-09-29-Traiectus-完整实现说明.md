# Traiectus 完整实现说明（Windows 端 + macOS 端）

> 版本：2026-09-29（产品名 Traiectus，原名 MiniKVM）
> 协议定义的权威文档是仓库根目录 `PROTOCOL.md`；本文讲的是**代码怎么实现**、每处设计**为什么这么做**。
> 组织顺序：**先讲最关键的数据来源 —— 读 Windows 端键盘状态帧**，再讲两端其余部分。

## 目录

| 章 | 内容 |
|---|---|
| 0 | 全局架构（组件与数据流） |
| **1** | **读取 Windows 端键盘状态帧（抢跑信号）—— 全过程** |
| 2 | Windows 端实现（服务端 / 桥接 / 托盘） |
| 3 | macOS 端实现（客户端 / 键盘监听 / 联动 / 打包） |
| 4 | 一次 `Fn+Caps` 的端到端时序（实测数字） |
| 5 | 关键设计取舍与踩过的坑 |
| 6 | 研究工具与历史组件（非产品，但解释"为什么是现在这个方案"） |
| 7 | 代码索引 |

---

## 0. 全局架构

```text
   Corsair K70 Pro Mini
      │  蓝牙（BT）              2.4G（SLIPSTREAM）
      │      │                        │
      │      │                        ▼
      │      │            2.4G 接收器（插在 Windows 上）
      │      │            vendor 接口 FF42/01、FF42/02
      │      │                        │
      │      │              ① 状态帧（只读）
      │      │                        ▼
      │      │           TraiectusBridge.ps1 ── UDP 45790 ──┐
      │      │             "KEY 00 00 01 36 00 02"           │
      │      │             "HB"（每 2 秒）                    │
      │      ▼                                                ▼
      └─► Traiectus.app（Mac）  ◄──── TCP 45789 ────  Traiectus-Server.exe（Win）
              kvm-keywatch（键盘归属）                    ▲  UDP 45791（控制通道）
```

| 组件 | 平台 | 源文件 | 职责 |
|---|---|---|---|
| **Traiectus Server** | Windows | `windows/phase3-tcp/src/main.cpp`（1386 行） | Raw Input 捕获鼠标 → TCP 45789 转发；控制通道 UDP 45791；光标锁定 + 看门狗 |
| **Traiectus Bridge** | Windows | `windows/kvm-bridge/TraiectusBridge.ps1`（387 行） | **读接收器状态帧** → UDP 45790 抢跑通知；心跳；把 Mac 的控制请求中继给服务端 |
| **Traiectus（托盘）** | Windows | `windows/launcher/Traiectus.cpp`（642 行） | 统一入口：按需拉起服务端 + 桥接，退出全清 |
| **Traiectus.app** | macOS | `macos/phase3-tcp/src/TraiectusClient.swift`（1048 行） | TCP 客户端 + 行协议 + CGEvent 注入 + 心跳/重连 |
| **kvm-keywatch** | macOS | `macos/kvm-link/kvm-keywatch.c`（130 行） | IOHIDManager 监听键盘归属（接入/移除事件） |
| **联动 KeyboardLink** | macOS | `macos/phase3-tcp/src/KeyboardLink.swift`（350 行） | 归属判定 → 切屏（m1ddc）+ 光标居中 + 向服务端请求鼠标控制权 |
| **菜单栏 UI** | macOS | `macos/phase3-tcp/src/ui/*.swift`（437 行） | MenuBarExtra + 320pt 面板 + 设置（SwiftUI） |

---

## 1. 读取 Windows 端键盘状态帧（抢跑信号）

> 这一章是"一次按键切换全部设备"的**前提**：没有它，就只能等键盘真的走了以后再切屏（慢 1.5 秒以上）。

### 1.1 要解决的问题：`Fn` 组合主机收不到

K70 Pro Mini 有 4 个主机位：蓝牙 Host 1/2/3 + SLIPSTREAM（2.4G 接收器）。
切换靠键盘上的 **`Fn+Caps`（去 Windows）/ `Fn+T`（回 Mac）**。

**关键事实：`Fn` 是键盘固件内部消费的，不生成任何 HID 报文，两个主机都收不到。**
（项目早期用 `hidutil` 与 Windows Raw Input 都验证过：按 `Fn+Caps` 时 Mac 侧无任何按键事件，Windows 侧也没有。）

所以软件只能从**侧面信号**推断"键盘正在往哪边切"：

| 侧面信号 | 谁能看到 | 看到什么 | 时机 |
|---|---|---|---|
| 键盘是否还在 Mac 的 HID 列表里 | Mac（`kvm-keywatch`） | 键盘 ADD / REMOVE（蓝牙连 / 断） | **键盘真的走了之后**（慢） |
| **2.4G 接收器的状态帧** | **Windows（桥接）** | 键盘与接收器握手时接收器吐的一帧 | **提前 1.5 秒以上（抢跑）** |

### 1.2 在哪儿读、什么时候能读到

| 项 | 值 |
|---|---|
| 读的对象 | **2.4G 接收器**（不是键盘本体） |
| 接收器位置 | 插在 **Windows** 机器上 |
| 接口 | vendor HID，`usagePage = 0xFF42`；实测两个：`FF42/01`、`FF42/02` |
| 状态帧来自 | **`FF42/02`** |
| 报告长度 | `InputReportByteLength = 65` 字节（由 `HidP_GetCaps` 读出） |
| 前提 | 接收器插在 Windows 上，且键盘正在**通过 2.4G** 与它通信 |

**为什么"回 Mac"方向也能读到**：切换瞬间接收器一定会看到"键盘离开 2.4G"，同样会吐帧。
只是该方向 2.4G 掉线 ≈ 蓝牙重连，没有提前量，抢跑只对"去 Windows"方向有价值。

### 1.3 代码实现（逐段）

文件：`windows/kvm-bridge/TraiectusBridge.ps1`（PowerShell + 内嵌 C#，纯 ASCII）

**步骤 1 · 用 SetupAPI 枚举 HID 接口**

```csharp
// 只枚举"当前存在"的 HID 设备接口
IntPtr h = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero,
                               DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
for (uint i = 0; SetupDiEnumDeviceInterfaces(h, IntPtr.Zero, ref hidGuid, i, ref did); i++) {
    SetupDiGetDeviceInterfaceDetail(h, ref did, detail, need, ref need, IntPtr.Zero);
    string path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));   // \\?\hid#...
}
```

**步骤 2 · 打开 + 过滤（VID + UsagePage）**

```csharp
IntPtr dev = CreateFile(path, GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE,
                        IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);

HIDD_ATTRIBUTES at = new HIDD_ATTRIBUTES(); at.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
HidD_GetAttributes(dev, ref at);
if (at.VendorID != 0x1B1C) continue;      // 只认 Corsair（K70 家族：键盘/有线/接收器）

HidD_GetPreparsedData(dev, out pre);
HIDP_CAPS caps = new HIDP_CAPS();
HidP_GetCaps(pre, ref caps);
if (caps.UsagePage != 0xFF42) continue;   // 只要 vendor 接口，不要标准键盘/鼠标接口

Iface it = new Iface();
it.Label = "FF42/" + caps.Usage.ToString("X2");   // → "FF42/01" / "FF42/02"
it.InputLength = caps.InputReportByteLength;      // → 65
```

用 `FILE_SHARE_READ|FILE_SHARE_WRITE` 打开：既不是独占，也不动设备配置，纯粹"只读地看着"。

**步骤 3 · 每个接口一个线程，阻塞 `ReadFile` 循环**

```csharp
byte[] buf = new byte[Math.Max(it.InputLength, 64)];
while (true) {
    int got = 0;
    bool ok = ReadFile(dev, buf, buf.Length, out got, IntPtr.Zero);   // ← 阻塞，等到报告才返回
    if (!ok) { if (++fails >= 3) break; Thread.Sleep(300); continue; } // 设备没了就退出线程
    fails = 0;
    if (got <= 0) continue;

    // 只取前 8 字节转 HEX，够 Mac 判模式
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < Math.Min(got, 8); i++) {
        if (i > 0) sb.Append(' ');
        sb.Append(buf[i].ToString("X2"));
    }
    Log(it.Label + " frame: " + sb + "  -> UDP " + dest);
    Send("KEY " + sb);                                                // ← UDP 45790 发给 Mac
}
```

**这里没有任何轮询**：`ReadFile` 阻塞在驱动队列上，接收器什么时候吐帧就什么时候醒来 —— 省 CPU，延迟也是最小的。

**步骤 4 · UDP 45790：状态帧 + 心跳 + 回包中继**

桥接同时在干三件事：

| 方向 | 报文 | 作用 |
|---|---|---|
| 桥接 → Mac | `KEY 00 00 01 36 00 02 00 00` | **抢跑通知**（状态帧原文，HEX） |
| 桥接 → Mac | `HB`（每 2 秒） | ① 让 Mac 记住桥接的地址；② **维持 Windows 防火墙的 UDP 回程状态** |
| Mac → 桥接 → 本机服务端 | `MODE Mac <口令>` → 转发到 `127.0.0.1:45791`，并把服务端回执 `OK` 写日志 | 让 Mac 能请求切换鼠标控制权 |

**为什么 `HB` 是必需的**：Windows 防火墙会拦"从 Mac 主动发来的入站 UDP"（Private/Any 规则实测都拦），
但**出站→回包**是放行的。所以让桥接先发心跳，Mac 再**回到那个地址**，回包就能通过；
桥接收到后转交本机 `127.0.0.1:45791`。这是"绕开入站防火墙"的关键设计，不是可有可无的保活。

### 1.4 状态帧长什么样

```text
KEY 00 00 01 36 00 02 00 00
    │  │  │  │  │  │  └── 后面补零的字节（无意义）
    │  │  │  │  │  └───── mode：02 = 去 Windows ／ 00 = 回 Mac
    │  │  │  │  └──────── 固定 00
    │  │  │  └─────────── 命令码 0x36（连接模式 / 状态）
    │  │  └────────────── 固定 01
    │  └───────────────── 固定 00
    └──────────────────── HID Report ID = 0（该接口无 Report ID）
```

实测：**每次连接模式切换时接收器吐一帧**，正文固定为 `00 00 01 36 00 <mode>`。

> ⚠️ **别和"给键盘发命令"的那串搞混**：直接给键盘本体（`1B1C:1BB6`）写切换命令时用的是
> `00 08 01 3A 00 <mode>` —— 那里的第 2 字节 `0x08` 是 K70 Pro Mini 的 **endpoint/channel**，
> 命令码是 `0x3A`。而这里讲的是**接收器只读吐出的状态帧**：第 2 字节固定 `00`、命令码 `0x36`。
> 两者字节含义完全不同（详见 §7 的"研究工具"一节）。

### 1.5 Mac 侧怎么用它（`KeyboardLink.readUDP`）

```swift
if text.uppercased() == "HB" { return }          // 心跳：只用来维持回程，不参与判定
let tokens = text.split(separator: " ").map { $0.lowercased() }
guard tokens.count >= 7, tokens[0] == "key",
      Array(tokens[1..<6]) == ["00", "00", "01", "36", "00"] else { return }  // ← 严格前缀匹配
let mode = tokens[6]
if mode == "02" { handleHint(.windows) }         // 抢跑：立刻切到 Windows / DP
else if mode == "00" { handleHint(.mac) }        // 抢跑：立刻切回 Mac / HDMI
```

设计要点：

1. **严格前缀匹配**：前 5 个 token 必须完全一致，否则丢弃 —— UDP 不可靠，严格匹配能挡住任何脏数据/串包；
2. **hint 有 8 秒有效期**：收到 hint 立刻动作，同时在 8 秒窗口内等 `kvm-keywatch` 的真实归属事件确认；
   超时则放弃（避免"抢跑了但键盘没过来"留下错状态）；
3. **离线不消费信号**：若此刻判定 Windows 端离线（TCP 断/心跳超时），hint 直接丢弃并记日志，
   不推进"已切"状态 —— 恢复后仍能从真实归属重新推导。

### 1.6 它值多少（实测）

| 信号 | 相对 macOS 蓝牙 ADD/REMOVE 事件 |
|---|---|
| 接收器状态帧（`FF42/02`） | **早 1.56 ~ 1.82 秒** |
| 跨机时钟差 | 0.43 s（按两侧共有样本校正后） |

所以"去 Windows"方向：**按键一按屏幕就开始切**（`m1ddc` 实测 60–106 ms），键盘真的过来时屏幕早已就位。
"回 Mac"方向没有提前量，剩余 ~1 秒是键盘固件切换 + 显示器 HDMI 重新同步，属于硬件时间。

### 1.7 边界与限制（如实记录）

1. 键盘完全不走 2.4G（纯蓝牙/有线）→ 读不到，退回"等蓝牙事件"，慢但结果正确；
2. 接收器必须插在 Windows 上；拔掉/换机器就没有这个通道；
3. **只读**：桥接从不写设备、不改键盘/接收器任何设置；
4. 只按 VID（`0x1B1C`）匹配：同品牌其它设备也会被枚举到，但只有 `FF42/02` 会吐状态帧；
5. 依赖 PowerShell 5.1 自带 .NET + 系统 HID API，**不需要管理员权限**。

---

## 2. Windows 端实现

### 2.1 服务端 `Traiectus-Server.exe`（`windows/phase3-tcp/src/main.cpp`）

**① 鼠标捕获：Raw Input，只读**

```cpp
// 注册 Raw Input；RIDEV_INPUTSINK 让窗口不聚焦也能收到
RAWINPUTDEVICE rid = {};
rid.usUsagePage = 0x01; rid.usUsage = 0x02;   // Generic Desktop / Mouse
rid.dwFlags = RIDEV_INPUTSINK;
::RegisterRawInputDevices(&rid, 1, sizeof(rid));
```

- **不 hook、不拦截、不注入、不用驱动、不需要管理员权限**（项目红线）；
- 收到 `WM_INPUT` 后按设备过滤（`--device "VID_046D&PID_C547&MI_00"`，即 GPW2 的 2.4G 接收器），
  避免把其它鼠标也转发过去；
- 绝对坐标设备（`MOUSE_MOVE_ABSOLUTE`，例如数位板/远程桌面）会被识别并换算；普通鼠标走相对位移。

**② 事件编码与发送**

```cpp
if (m.usFlags & MOUSE_MOVE_ABSOLUTE) { /* 换算成增量 */ }
else { EmitMove(m.lLastX, m.lLastY); }

if (f & RI_MOUSE_LEFT_BUTTON_DOWN)   EmitButton("L",  true);
if (f & RI_MOUSE_LEFT_BUTTON_UP)     EmitButton("L",  false);
if (f & RI_MOUSE_RIGHT_BUTTON_DOWN)  EmitButton("R",  true);
if (f & RI_MOUSE_RIGHT_BUTTON_UP)    EmitButton("R",  false);
if (f & RI_MOUSE_MIDDLE_BUTTON_DOWN) EmitButton("M",  true);
if (f & RI_MOUSE_MIDDLE_BUTTON_UP)   EmitButton("M",  false);
if (f & RI_MOUSE_BUTTON_4_DOWN)      EmitButton("X1", true);   // 侧键 1
if (f & RI_MOUSE_BUTTON_4_UP)        EmitButton("X1", false);
if (f & RI_MOUSE_BUTTON_5_DOWN)      EmitButton("X2", true);   // 侧键 2
if (f & RI_MOUSE_BUTTON_5_UP)        EmitButton("X2", false);
if (f & RI_MOUSE_WHEEL)              EmitWheel((long)(short)m.usButtonData, false);
if (f & RI_MOUSE_HWHEEL)             EmitWheel((long)(short)m.usButtonData, true);
```

输出就是协议里的文本行：`MOVE 12 -7` / `DOWN L` / `UP L` / `WHEEL 120` / `HWHEEL -120`。
**位移只发相对增量**（协议硬约束）：绝对坐标需要两端换算分辨率与缩放，任何一处算错就"指针跳变"；
相对增量与设备原始计数一一对应，天然没有这个问题。

**③ 控制权模式（`MODE`）与光标锁定**

| 模式 | 服务端行为 |
|---|---|
| Windows 模式（默认） | **不转发任何事件**、不加光标锁定 → Windows 完全原生（打游戏就是这个状态） |
| Mac 模式 | 转发事件 + 用 `ClipCursor` 把 Windows 光标钉在**主屏中心 1×1**（相对位移照常转发，光标不会跑也不会乱点） |

```cpp
// → Mac 模式：先移动、再锁定（顺序不可反）
::SetCursorPos(cx, cy);
::ClipCursor(&r);                  // r = 主屏中心 1×1

// → Windows 模式：补发抬起 → 发 MODE Win → 解锁 → 回中心
::ClipCursor(nullptr);
::SetCursorPos(cx, cy);
```

**钉在中心而不是原位**的原因：Mac 侧光标由相对位移驱动，两端位置对称后，切换完开始用时
不会出现"光标从角落起飞"的观感。Mac 侧在每次切换时同样把光标移到主屏中心。

**④ 控制通道（UDP 45791）**

```text
MODE <Win|Mac> <口令>     ← Mac 侧请求切换（等价于在 Windows 上按 Ctrl+Alt+M）
PING / PONG               ← 连通性探测
OK                        ← 服务端回执
```

同一段 `SetControlMode()` 同时服务三个入口：**热键 `Ctrl+Alt+M`**、**控制通道请求**、
**启动参数 `--start-in-mac-mode`** —— 所以三者在两端行为完全一致。
口令由 `--token` 指定，明文校验（内网自用的强度，见协议 §2 的说明）。

**⑤ 看门狗（防"进程被强杀后光标还锁着"）**

实测确认：**`ClipCursor` 的锁定在进程被强杀后不会自动解除** —— 光标会被永久钉在 1×1 里，
只能重启系统才恢复。所以：

```text
服务端启动时用 --watchdog 再起一个自己的副进程：
  · 副进程与主进程绑在同一个 Job Object（JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE）
  · 主进程消失 → 副进程立刻 ClipCursor(nullptr) 解锁
  · 副进程也退出了？→ 下次启动时先无条件 ClipCursor(nullptr) 兜底
```

**⑥ TCP 监听：同一时刻只接受一个客户端**

```cpp
listen(s, SOMAXCONN);
while (running) {
    SOCKET c = accept(s, …);          // 阻塞等待
    if (g_client != INVALID_SOCKET) {  // 已经有客户端 → 顶掉旧的
        closesocket(g_client);         // 旧连接直接被断开（它会自己重连）
    }
    g_client = c;
    ResetHandshake();                  // 新连接必须先 HELLO，否则事件一律丢弃
}
```

**为什么只允许一个**：协议的事件是"相对位移"，两个客户端同时接收只会互相打架；
而且实践中"多开"往往是误操作。**"新连接顶掉旧连接"** 这条也解释了一个易混现象：
如果你在 Mac 上不小心启动了第二个客户端实例，第一个会被服务端踢下线 —— 表现为
"日志里连接莫名断开"（本项目真遇到过，排查时先确认只有一个实例）。

**⑦ 握手与口令校验**

```text
客户端：HELLO 1 Mac <口令>
服务端：版本 + 口令都对 → "HELLO-OK 1"
        版本不符或口令错 → "ERR AUTH"（随后立即关闭连接）
```

- 服务端**在收到 `HELLO` 之前不转发任何事件**（防止半途接入的脏数据被注入）；
- 客户端**在收到 `HELLO-OK` 之前丢弃任何事件行**；
- 口令是明文比较（内网自用强度）；启动时若没给 `--token`，控制台会打印警告。

### 2.2 桥接 `TraiectusBridge.ps1`

见第 1 章（状态帧读取）。此外它还负责：

- 心跳 `HB`（每 2 秒）维持防火墙回程（原因见 §1.3 步骤 4）；
- 把 Mac 的 `MODE …` 中继到本机 `127.0.0.1:45791`，并把服务端回执 `OK` 写进日志；
- 两个日志文件刻意分开：`TraiectusBridge.log`（脚本自己写）与 `TraiectusBridge-console.log`
  （入口进程重定向标准输出/错误）—— 否则两个写入者会抢同一个文件、内容互相覆盖。

**可配置参数**（脚本头部 `param()`，托盘通过 `config.ini` 传）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-MacIp` | `192.168.1.10` | 抢跑通知发到哪台 Mac |
| `-UdpPort` | `45790` | 抢跑/心跳 UDP 端口 |
| `-Vid` / `-UsagePage` | `0x1B1C` / `0xFF42` | 设备过滤条件（换键盘只需改这两项） |
| `-OutFile` | `TraiectusBridge.log` | 桥接自己的日志 |

### 2.3 托盘 `Traiectus.exe`（`windows/launcher/Traiectus.cpp`）

**设计目标**：把 Windows 端从"服务端 + 桥接各自为政"改成一个**手动入口**：

```text
打开托盘 → 服务端 + 桥接 一起拉起     （1 入口 / 1 服务端 / 1 桥接）
点退出   → 服务端、桥接、看门狗、端口、光标锁定 一次性全清
```

实现要点：

1. **单实例**：命名互斥体 `Traiectus_Launcher_SingleInstance`，防止开两个入口互相抢设备；
2. **Job Object**：`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` —— 入口进程一消失，内核把 Job 里所有进程
   （含它们的子进程，例如服务端拉起的看门狗）一起杀掉，比逐个 `TerminateProcess` 可靠得多；
3. **先挂 Job 再放行**：子进程以 `CREATE_SUSPENDED` 创建，挂进 Job 后再 `ResumeThread`，
   否则它可能在挂进去之前就先起了"孙子进程"，那些就漏在 Job 外面了；
4. **刻意不做**：不加开机自启、不注册服务、不改注册表（"按需启停"是设计的一部分）；
5. 日志：`Traiectus-Server.log` / `TraiectusBridge.log` / `TraiectusBridge-console.log`（都在入口目录旁）。

**`config.ini` 里能改什么**（托盘读它来决定怎么启动两个子进程）：

```ini
[server]
exe=Traiectus-Server.exe
args=--device "VID_046D&PID_C547&MI_00" --token <你的口令>
log=Traiectus-Server.log
[bridge]
cmd=powershell -NoProfile -ExecutionPolicy Bypass -File "%SYS%" -MacIp 192.168.1.10 -OutFile TraiectusBridge.log
log=TraiectusBridge-console.log
[app]
port=45789
waitMs=15000          ; 等多久算"服务端启动超时"
```

换鼠标（接收器）、换 Mac 地址、换口令，都只需要改这个文件 —— 不用重编 exe。

---

## 3. macOS 端实现

### 3.1 客户端 `Traiectus.app`（`macos/phase3-tcp/src/TraiectusClient.swift`）

**① 网络：`NWConnection` + 文本行分帧**

```swift
static let maxLineBytes = 256          // 单行上限（协议 §1）
static let maxBufferedBytes = 1024     // 未出现换行的缓冲上限
static let heartbeatInterval: TimeInterval = 1
static let maxReconnectDelay: TimeInterval = 1
```

- 连接参数（地址 / 端口 / 口令）存在 `traiectus.*` 偏好里，启动即自动连接；
- **IP 直连**：地址是 IP 时直接构造 `IPv4Address` 端点，不进解析器 —— 本机代理（v2rayN）
  会劫持 DNS，早期的 `NoSuchRecord` 就是它造成的；
- `LineFramer` 按 `\n` 切行、忽略 `\r`，超限即判定无效并断开。

**② 握手 / 心跳 / 判死**

```text
HELLO 1 Mac <口令>   →   HELLO-OK 1     （3 秒内没回 = 失败）
PING <id> / PONG <id>                   （双方各每 1 秒一次）
任一方 3 秒没收到任何数据 → 判死，关闭连接
```

**③ 重连：三档**

| 触发 | 行为 |
|---|---|
| 普通断线 | 指数退避、**上限 1 秒**（0.25→0.5→1→1…）；离线超过 30 秒后改成**每 10 秒**一次 |
| **网络路径变化** | `NWPathMonitor` 一旦发现路径变化（唤醒 / 换 Wi-Fi / 代理起停）→ **立即重连**并重置退避 |
| 认证失败（`ERR AUTH`） | **不自动重连**，避免用错误口令空转刷日志 |

实测：被杀掉后重开 **44 ms** 完成握手；进程被冻结 30 秒、恢复后 **276 ms** 完成重连。

**④ 事件注入（`EventInjector`）**

```swift
// 移动：按住键时必须发对应的 Dragged 类型，否则拖不动文件/文字
if heldButtons.contains("L")          { type = .leftMouseDragged }
else if heldButtons.contains("R")     { type = .rightMouseDragged }
else if let other = heldButtons.first { type = .otherMouseDragged }
else                                  { type = .mouseMoved }

CGEvent(mouseEventSource: eventSource,
        mouseType: type,
        mouseCursorPosition: clampToMainDisplay(target),
        mouseButton: button)?.post(tap: .cghidEventTap)
```

要点：

- **注入到 `.cghidEventTap`**（HID 层），与真实鼠标事件等价；
- **1:1 线性注入**（不加指针加速）：送来的就是设备原始计数，手感"直"一点但完全可预测；
- **限制在主显示器内**：相对增量在屏幕边缘会被截断（协议 §7 已如实记录该限制）；
- **滚轮累积**：`linesPerDetent = 3`，即累积满一格（120）就滚 3 行；高分辨率滚轮（±1 的小值）
  会累积到 120 才执行，零头留到下次；
- **断开 / 收到 `BYE` / 收到 `MODE Win`** 时必须**补发所有仍按下键的抬起**
  （否则会出现"左键卡住 → 所有点击都变成拖拽"），并用
  `CGAssociateMouseAndMouseCursorPosition(1)` 兜底。

**⑤ 菜单栏 UI（SwiftUI）**

```swift
MenuBarExtra { PanelView(state: client.linkState) } label: {
    Image(systemName: client.linkState.menuBarSymbol)   // 四种状态四个 SF Symbol
}
.menuBarExtraStyle(.window)                              // 下拉面板（不是菜单）
Settings { SettingsView().environmentObject(client) }    // ⌘, 打开
```

- `LSUIElement = true`：没有 Dock 图标、没有窗口（常驻菜单栏工具的正确形态）；
- 面板只有三样：名字 + `●—○` 连接可视化 + 齿轮。**连线只表示"通不通"，圆点颜色表示"控制权在谁"**；
- 设置：状态行（键盘联动 / 自动连接）、连接参数、打开日志目录、**退出**；
- 图标是 macOS 26/27 官方格式：`AppIcon.icon`（Icon Composer 文档）经 `actool` 编译成 `Assets.car`
  （六种外观：默认 / 深色 / 透明 / 着色），同时打一份扁平 `.icns` 给老系统。

**⑥ 处理 `MODE` 与状态派生（面板/菜单栏图标怎么来的）**

```swift
case "MODE":                                  // 服务端告知控制权在谁手里
    if side == "Win" {
        injector.releaseAllHeldButtons()      // 先补发抬起，避免"卡住的键"
        suppressEvents = true                 // 防御性：忽略切换瞬间的竞态事件
        mouseOnMac = false
    } else {
        suppressEvents = false
        mouseOnMac = true
    }
```

拿到几个原始状态后，派生出面板与菜单栏用的四态：

```swift
public var linkState: LinkState {
    if authFailed        { return .error }            // 口令/版本不对
    if !winOnline        { return .windowsOffline }   // Windows 端没在线
    if !isConnected      { return .connecting }       // 正在连接/重连
    return .connected(side: mouseOnMac ? .mac : .win) // 正常，控制权在谁
}
```

每个状态对应一个 SF Symbol（菜单栏图标）与面板上的圆点/连线样式 ——
**连线只表示"通不通"，圆点颜色表示"控制权在谁"**。

### 3.2 键盘归属监听 `kvm-keywatch`（C，130 行）

```c
IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
// 匹配字典只有一项：kIOHIDVendorIDKey = 0x1B1C
IOHIDManagerSetDeviceMatching(mgr, matching);
IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_add, NULL);     // 接入
IOHIDManagerRegisterDeviceRemovalCallback(mgr, on_remove, NULL);   // 移除
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);                      // 非独占
```

- **只订阅设备接入/移除通知**：不打开 `IOHIDDevice`、不读输入报告、不发送任何数据
  （`IOHIDDeviceGetProperty` 只用来打印 transport / product）；
- 输出一行一条：`<epoch> ADD|REMOVE <transport> | <product>`，transport 是 `USB` 或 `Bluetooth Low Energy`；
- 事件驱动、延迟**毫秒级**。早期版本是"每 0.5 秒跑一次 `hidutil list`"，最慢要 0.5 秒才发现变化，
  这个工具就是为了替掉它。

### 3.3 联动 `KeyboardLink.swift`（350 行）

```text
① 归属判定：transports 集合含 bluetooth → "bt"；含 usb → "usb"；都没有 → nil（不在 Mac 上）
② 去抖 0.35 秒：避免蓝牙重连瞬间的 ADD/REMOVE 抖动被当成两次切换
③ 0.2 秒 tick：归属变化 → perform(side)
④ perform(side)：切屏（m1ddc）→ 光标移到主屏中心 → 发 MODE <side> 给服务端
```

- **切屏用 m1ddc**（`m1ddc set input 15` = DP / Windows，`17` = HDMI / Mac）：单文件 C、启动 ~5 ms；
  早期的 `dwc` 每次 300–400 ms，因此被替掉；
- 光标居中后**必须**补 `CGAssociateMouseAndMouseCursorPosition(1)`：
  `CGWarpMouseCursorPosition` 会把"光标"和"鼠标"解绑（macOS 已知行为），不补这一句光标会卡住/像消失；
- **抢跑路径**：收到桥接的 `KEY …` → 立即 `perform()`，并设 8 秒 hint 等真实归属确认；
- Windows 端离线时**只挡输出动作**（切屏 / MODE / 居中），本地键盘归属照常更新；
  **不清本地键盘归属** —— 那是物理事实，恢复后要靠它重新推导；
- Windows 端恢复在线时做一次同步（`syncAfterRecovery`），把鼠标控制权对上。

### 3.4 打包与安装

```sh
./build.sh          # swiftc 编译 → build/Traiectus.app
                    #  + actool 编译 AppIcon.icon → Assets.car（并打 AppIcon.icns 给老系统）
                    #  + 把 kvm-keywatch / m1ddc 拷进 Contents/Resources（app 自给自足）
./install-app.sh    # 装到 ~/Applications + 写登录项（~/Library/LaunchAgents/com.traiectus.client.plist）
```

- **原地更新**（不整包 `rm -rf`）：保持 bundle inode 稳定，图标缓存 / LaunchServices 记录 / Dock 项都不会失效；
- 用 `/usr/bin/open` 启动：保证 app 的 TCC 身份（辅助功能 / 本地网络）与手动双击一致；
- **自签证书** `MiniKVM Dev Code Signing`（名字保留历史名）：重编不丢辅助功能授权；
- 依赖工具随包分发，装到哪里都不依赖仓库路径。

---

## 4. 一次 `Fn+Caps` 的端到端时序（实测）

```text
t0          用户在键盘上按 Fn+Caps（键盘固件开始切到 2.4G）
            │
t0 + ~0     接收器 vendor 接口 FF42/02 吐出状态帧 00 00 01 36 00 02
            │   桥接（阻塞 ReadFile 被唤醒）→ 转 HEX → UDP 45790 发 "KEY 00 00 01 36 00 02"
            ▼
t0 + ~1ms   Mac 收到 KEY 帧 → handleHint(.windows)
            ├─ 切显示器输入源：m1ddc set input 15    实测 60–106 ms
            ├─ 光标移到主屏中心（CGWarp + 重新关联鼠标）
            └─ 发 MODE Win → 服务端进入 Mac 模式（开始转发事件 + 把 Windows 光标钉在中心）
            ▼
t0 + ~1.5s  键盘真正枚举到 Windows（Mac 侧同时出现蓝牙 REMOVE）
            → 被 8 秒 hint 吸收，不重复动作
```

反向（`Fn+T`，回 Mac）：

```text
键盘固件切回蓝牙 → Mac 侧蓝牙 ADD（毫秒级事件）
  ├─ 切回 HDMI：m1ddc set input 17    实测 60–85 ms
  ├─ 光标居中
  └─ 发 MODE Mac（停止转发、解除光标锁定）
※ 该方向 2.4G 掉线 ≈ 蓝牙重连，没有提前量；剩余 ~1 秒是键盘固件 + 显示器 HDMI 重新同步
```

---

## 5. 关键设计取舍与踩过的坑

| # | 取舍 / 坑 | 结论 |
|---|---|---|
| 1 | **文本行协议** vs 二进制 | 选文本：`nc` 就能手动复现排错；在 ~145 条/秒、每行十几字节的量级下开销可忽略 |
| 2 | **只发相对位移** | 绝对坐标要换算分辨率/缩放，易"指针跳变"；相对增量与设备原始计数一一对应 |
| 3 | **3 秒判死** | 没有它，拔网线/睡眠时 TCP 会安静挂着，两边都以为对方还在 |
| 4 | **断开必须补发抬起** | 否则"左键卡住 = 所有点击变拖拽"，很难联想到是 KVM 造成的 |
| 5 | **Windows 模式不转发事件** | 打游戏时 Windows 必须完全原生；顺带让老客户端不改也功能正确 |
| 6 | **`ClipCursor` 需要看门狗** | 进程被强杀后锁定不会自动解除 → 副进程 + Job Object 兜底 |
| 7 | **注入要发 `Dragged` 类型** | 只发 `.mouseMoved` 时拖不动文件/文字（Finder 与文本编辑都会拒绝） |
| 8 | **`CGWarp` 会解绑鼠标** | 必须补 `CGAssociateMouseAndMouseCursorPosition(1)`，否则光标卡住/看不见 |
| 9 | **代理会劫持 DNS** | 连接时对 IP 直接构造端点，不进解析器 |
| 10 | **不要用 `rm -rf` 重编 app** | 换 inode 会让图标缓存 / 别名 / Dock 项失效 → 改成原地更新 |
| 11 | **换 bundle id 要重新授权** | TCC 按"bundle id + 证书身份"给权限；改名后需在辅助功能里重新添加 |
| 12 | **旧格式图标会被系统套托盘** | 要 `Assets.car`（Icon Composer 文档编译）才是原生渲染；`.icns` 只留给老系统 |
| 13 | **多实例会互相踢连接** | 服务端同一时刻只接受一个客户端；app 退出要显式收掉 `kvm-keywatch` 子进程 |
| 14 | **换仓库目录后首次编译报 `SwiftShims`** | 模块缓存记着旧路径 → 删 `build/module-cache` 与 `.build/` 重编 |

---

## 6. 研究工具与历史组件（不是产品，但解释了"为什么是现在这个方案"）

| 组件 | 位置 | 干什么 | 结论 / 现状 |
|---|---|---|---|
| **K70 HID 测试工具** | `macos/k70-hid-test/`（C++ + vendored hidapi） | `K70HIDTest info / dump / test-*`：打开键盘本体 `1B1C:1BB6`、读 Report Descriptor（`usagePage 0xFF42`、`usage 1`、**无 Report ID**、Input/Output 各 1024 字节 → `hid_write()` 需 **1025** 字节）；`test-bt1 / test-slipstream` 真实写入 `00 08 01 3A 00 <mode>` 切主机位（BT1=`02`、BT2=`03`、BT3=`08`、SLIPSTREAM=`01`） | **能写、也能真的切**。但键盘一旦离开某台机器（走到 2.4G 或蓝牙给另一台），那台机器就**看不到 vendor 接口** → 回程发不出命令。这就是"纯软件双向切换走不通"的根因，也是产品最终选"硬件 `Fn` 键 + 状态帧推断"的原因 |
| **KvmWatch.ps1** | `windows/kvm-bridge/` | 只读探针：订阅接收器 `FF42` 接口，把每帧带毫秒时间戳打印出来 | **当初就是它发现了状态帧**（对比后确认比 macOS 蓝牙事件早 1.5 秒以上）；现在保留作诊断 |
| **K70-Probe / K70-Send 等** | `windows/k70-probe/` | Windows 侧对 K70 vendor 接口的探测与一次性发送脚本 | 与 Mac 侧 `k70-hid-test` 同源、结论一致；已不在产品路径上 |
| **phase1-rawinput** | `windows/phase1-rawinput/` | Raw Input 诊断：列设备、测上报率（`hidrate` / `cursorrate` / `inject`） | 用来**选设备**（确认 GPW2 的 2.4G 接收器 `VID_046D&PID_C547`）并验证高上报率；保留作诊断 |
| **display-input（Windows 侧）** | `windows/display-input/` | DDC/CI 切显示器输入源（`MonInput.ps1` 等） | 已被 **Mac 侧 m1ddc** 取代（Mac 一次调用 ~5 ms，且不牵扯 Windows 正在玩的游戏） |
| **phase2-cgevent** | `macos/phase2-cgevent/` | Phase 2 客户端（更早的 CGEvent 注入版本） | 已被 `phase3-tcp` 的 Traiectus.app 取代，仅作历史 |
| **kvm-link.py** | 已删除（git 历史可查） | 早期 Python 联动脚本：`hidutil list` 轮询 + `dwc` 切屏 | 已被"app 内置联动 + `kvm-keywatch`（事件驱动）"取代 |

**一句话总结这条探索路径**：先试"软件直接给键盘写命令"（能切，但**回程不通**）→ 再试
"Windows 侧只读抓接收器状态帧"（**成了，抢跑 1.5 秒**）→ 最后把联动做进 app
（一个菜单栏程序 + 一个托盘程序）。

---

## 7. 代码索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `windows/phase3-tcp/src/main.cpp` | 1386 | 服务端：Raw Input 捕获、事件编码、控制权模式、控制通道、看门狗 |
| `windows/kvm-bridge/TraiectusBridge.ps1` | 387 | 桥接：**状态帧读取**、UDP 抢跑、心跳、回包中继 |
| `windows/kvm-bridge/KvmWatch.ps1` | 265 | 只读探针（当初发现状态帧用的工具，保留作诊断） |
| `windows/launcher/Traiectus.cpp` | 642 | 托盘统一入口：按需启停 + Job Object 全清 |
| `windows/control-channel/Traiectus-firewall.ps1` | 75 | 防火墙：45789 放行 + 旧规则改名 + 历史死规则清理 |
| `macos/phase3-tcp/src/TraiectusClient.swift` | 1048 | 客户端：网络、协议、注入、重连、状态 |
| `macos/phase3-tcp/src/KeyboardLink.swift` | 350 | 联动：归属判定、抢跑、切屏、光标居中 |
| `macos/kvm-link/kvm-keywatch.c` | 130 | 键盘归属监听（IOHIDManager，只订阅通知） |
| `macos/phase3-tcp/src/ui/TraiectusApp.swift` | 30 | `@main`：MenuBarExtra + Settings |
| `macos/phase3-tcp/src/ui/PanelView.swift` | 65 | 320pt 下拉面板 |
| `macos/phase3-tcp/src/ui/ConnectionDiagram.swift` | 163 | `●—○` 连接可视化（呼吸点、虚线/实线） |
| `macos/phase3-tcp/src/ui/SettingsView.swift` | 107 | 设置窗口（状态 / 连接 / 高级 / 退出） |
| `macos/phase3-tcp/src/ui/LinkState.swift` | 72 | 状态模型（含菜单栏图标映射） |
| `macos/phase3-tcp/build.sh` / `install-app.sh` | — | 编译打包 / 安装到 `~/Applications` + 登录项 |
| `PROTOCOL.md` | — | **协议权威定义**（握手、事件、心跳、清理规则、已知限制） |
