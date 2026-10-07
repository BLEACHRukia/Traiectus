# Traiectus

**One keyboard, two computers. Press one key — keyboard, mouse and monitor all follow.**

[中文说明 →](README.zh-CN.md)

## Download (if you'd rather not build it yourself)

Grab the zip for your platform from **[Releases](https://github.com/BLEACHRukia/Traiectus/releases)**:

| Platform | File | What's inside |
|---|---|---|
| Windows | `Traiectus-Windows.zip` | `Traiectus.exe` (tray launcher) + `Traiectus-Server.exe` + config template + notes |
| macOS | `Traiectus-macOS.zip` | `Traiectus.app` + first-launch notes |

Both are **unsigned**: Windows shows a SmartScreen prompt (More info → Run anyway);
on macOS you must **right-click → Open** the first time (the notes inside the zip explain it).

To build from source instead, jump to Quick start below.

Traiectus is a small, self-hosted KVM for people who keep a Mac and a Windows PC on the same desk
and share **one keyboard, one mouse and one monitor** between them — without buying a hardware KVM switch.

It is not a virtual machine and not remote desktop. Both computers run normally and natively;
Traiectus just moves your *input devices* and *the monitor's input source* between them over your LAN.

```text
                  ┌──────────────── 显示器 ─────────────────┐
                  │                                        │
           HDMI   │                                        │   DP
      ┌───────────┘                                        └───────────┐
      │                                                                │
 ┌────┴─────┐         局域网 (TCP 45789)              ┌───────────────┴──┐
 │ Mac mini │◄───────────────────────────────────────►│   Windows PC     │
 │Traiectus │                                        │ Traiectus Server │
 │  Client  │                                        │  + 读帧（抢跑）   │
 └────▲─────┘                                        └───▲──────────┬───┘
      │ 蓝牙 / USB                                       │ 2.4G 接收器│ USB
      └──────────────── Corsair K70 Pro Mini ───────────┘   GPW2 鼠标 ─┘
```

## What it does

| 能力 | 说明 |
|---|---|
| **鼠标跨机** | 鼠标插在 Windows 上，事件经局域网转发到 Mac，用 CGEvent 注入。Windows 本地鼠标照常可用。 |
| **一次按键全切** | 按键盘上"切到 Windows"的快捷键换主机时，Traiectus 把**显示器输入源**和**鼠标控制权**一起跟着切。 |
| **预先切屏（抢跑）** | Windows 侧只读监听接收器的状态帧，比 Mac 侧自己发现键盘离开**早约 1.7 秒**切屏（**只对"去 Windows"方向**；"回 Mac"方向两个信号几乎同时，本来就没有提前量）。 |
| **睡眠一键交接** | 在 Mac 上按一个组合键（默认 ⌘1）让 Mac 睡眠，同时把屏幕和鼠标交给 Windows；唤醒后自动切回。 |
| **鼠标切换热键** | 单独切鼠标：按一下 `⌃⌥M`（Windows 侧是同一个键 `Ctrl+Alt+M`）在 Mac / Windows 之间换鼠标控制权，键盘不动。可在「设置 → 通用」里改。 |
| **不用查任何 ID** | 鼠标是哪只由服务端自动识别；键盘是哪把在「设置 → 键盘 → 我的键盘」点一下就能选；显示器输入源编号是"学"出来的。 |
| **不装驱动、不 hook** | Windows 侧**只读捕获** Raw Input：不拦截、不改系统设置、不装驱动、不用内核扩展。 |

## Requirements（先说清楚，这套东西有前提）

- **键盘必须能在两台机器之间换主机** —— 也就是内置 `Fn` 组合键在"蓝牙主机"和"2.4G / 有线主机"
  之间切换的键盘。本项目实测的是 **Corsair K70 Pro Mini**（Mac = 蓝牙 BT1，Windows = SLIPSTREAM 2.4G 接收器）。
  Traiectus **不能命令键盘换主机** —— 那是键盘固件的事；它只是"看见"键盘走了，然后让屏幕和鼠标跟着走。
  换一把不支持换主机的键盘，"一次按键全切"就不成立。
- **显示器支持 DDC/CI**（绝大多数现代显示器都支持），且两台机器接在不同输入口上。
- **两台机器在同一个局域网**里，能互相访问。
- 实测环境 macOS 14+ / Windows 10-11。Windows 侧 C++（MinGW），Mac 侧 Swift
  （SwiftUI + CGEvent + Network.framework）。
- **抢跑（提前切屏）需要键盘有厂商状态帧接口**（实测的 Corsair K70 Pro Mini 有）。
  换一把没有这个接口的键盘，其它功能照常，只是"去 Windows"方向没有提前量、慢约 1.7 秒。

## Typical usage (verified on real hardware)

```text
1. Both machines on → Windows server + bridge running → the Mac connects itself
2. On the Mac press the sleep hot key (default ⌘1)
       → the Mac sleeps, and in the same instant the monitor goes to DP and the mouse
         is handed to Windows (measured: 0.19 s)
3. The keyboard stays on the Mac's Bluetooth — deliberately: that's what wakes the Mac
4. To use Windows: press your keyboard's "switch to Windows" combo → screen and mouse follow
5. Back to the Mac: press the "back to Mac" combo → screen back to HDMI, mouse back to the Mac
6. Wake the Mac: press any key → it wakes, reconnects, and pulls screen + mouse back
```

Three things that are easy to get wrong (all measured):

| Observation | Who actually does it |
|---|---|
| Mac sleeps → screen goes to Windows | **Both**: the app switches on the "about to sleep" notification, **and** the monitor has its own input auto-detect |
| Mac sleeps → mouse usable on Windows | **The app** (sends `MODE Win` immediately). Without it you wait 4–5 s for the server to notice the client is gone |
| Keyboard switches host → screen follows | **The app.** The Fn combo doesn't change the HDMI signal, so the monitor can't know |
| Wake → screen returns to the Mac | **The app.** The monitor won't hop back from DP to HDMI by itself |

## Quick start

### 1. Windows 侧

```bat
:: windows\phase3-tcp\
build-mingw.bat                  :: 编译服务端 Traiectus-Server.exe
start-server.bat                 :: 启动服务端（窗口别关）

:: That's all — nothing to fill in:
::   · no password: the first time a Mac connects, a confirm box appears on Windows — click Allow
::   · no mouse device id either: the server auto-detects the mouse you are actually using
::     (watch for a "DEVICE PICK ..." line in its log)
::   · the head-start (reading the keyboard receiver's status frames) is built into the server;
::     the old PowerShell bridge is no longer needed
```

For everyday use the tray launcher（`windows/launcher/`）is handier — it starts the server and
puts everything behind one tray icon（设置鼠标切换快捷键 / 检测鼠标 / 重新配对 / 退出）：

```bat
cd windows\launcher
build-launcher.bat
copy config.example.ini config.ini    :: 不用改内容，直接复制就行
Traiectus.exe
```

### 2. Mac 侧

```bash
cd macos/kvm-link && ./build.sh         # 1) kvm-keywatch（键盘归属监听）
cd m1ddc && make                        # 2) m1ddc（显示器输入源切换，MIT）
cd ../../phase3-tcp && ./build.sh       # 3) Traiectus Client（会把上面两个打进 .app）
./install-app.sh                        # 4) 装到 ~/Applications 并设为登录启动
```

首次运行要在 **系统设置 → 隐私与安全性 → 辅助功能** 里给 Traiectus 打勾（注入事件需要它）；
连内网地址时 macOS 还会问一次"允许访问本地网络"。

**No address to type**: the Mac is the connecting side and finds Windows on the LAN by itself.
**No password either**: on the first connection a confirm box appears on Windows — click Allow,
and the password is generated and remembered on both sides. (Lost it / changed machine?
Tray →「重新配对」.)

### 3. 显示器输入源编号

DDC/CI 的输入源编号因显示器而异（本机实测：`17` = HDMI-1，`15` = DP-1）—— **不用翻说明书**：
设置 → **显示** → 点「开始学习」，按提示用显示器上的按钮切一次，程序自己读、自己记。
手动也行：`m1ddc get input` 读当前值，再写进 Mac 侧的配置文件。

## Configuration

Mac 侧所有跟"你的硬件"有关的参数都在配置文件里，不用改代码重编：

| 文件 | 内容 |
|---|---|
| [`config.example.json`](config.example.json) | 模板：显示器输入源号、键盘厂商 ID、外部工具路径、默认地址 |
| `windows/launcher/config.example.ini` | Windows 托盘模板：服务端参数、热键、端口（`--device` 留空 = 自动识别鼠标） |
| `windows/phase3-tcp/paired.json` | 配对生成的口令，两端各自保存（**不要提交**，已在 `.gitignore` 里） |

## Documentation

| 文档 | 内容 |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | 两端通信协议（端口、握手、报文格式）—— 权威定义 |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | 已知坑与排查顺序（**连不上先看这个**） |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 架构与各机制的设计理由 |
| [`docs/TESTING.md`](docs/TESTING.md) | 验证方案：三层测试怎么跑 |
| [`docs/design/`](docs/design) | 设计方案（例如"键盘状态帧检测与验证"） |
| [`docs/devlog/`](docs/devlog) | 开发过程记录：K70 键盘逆向、状态帧分析、实测数据 |
| [`macos/phase3-tcp/README.md`](macos/phase3-tcp/README.md) | Mac 客户端工程细节 |
| [`windows/phase3-tcp/`](windows/phase3-tcp) | Windows 服务端工程细节 |

## Status

个人项目：**在一台具体的机器组合上做到能用，并长期实际使用**（过程与实测数据都在 `docs/devlog/`）。
它不是通用软件 ——

- "一次按键全切"依赖特定键盘固件（见上面 Requirements）
- 显示器输入源编号要按你自己的显示器"学"一次（键盘是哪把、鼠标是哪只已经能自动认）
- 只在 macOS + Windows 这一种组合上验证过

如果你正好是"Mac + Windows 共用一个键鼠和一台显示器"的场景，这套东西能直接省掉一个硬件 KVM。

## License

MIT，见 [`LICENSE`](LICENSE)。第三方组件与商标声明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
