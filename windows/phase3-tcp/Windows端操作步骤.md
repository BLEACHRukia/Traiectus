# Traiectus Phase 3 —— Windows 端操作步骤

> 本文件由 Mac 侧生成，是 Windows 端**当前唯一权威**的操作步骤。
> 如果它和别的旧文档冲突，以本文件 + 仓库根目录的 [`PROTOCOL.md`](../../PROTOCOL.md) 为准。
> 文件名不叫 README.md，是因为当初用一个"会隐藏所有 README.md"的文件服务器传文件，换个名字才看得见。

---

## 0. 怎么读这份文档

从一台干净的 Windows 开始，到 Mac 能被这只鼠标驱动为止，每一步都写在这里。
按顺序做，每步都写了"怎么做"和"应该看到什么"。

只想最快跑起来：

```bat
cd phase3-tcp
build-mingw.bat
build\Traiectus-Server.exe
```

设计/实现上的说明在 [`README.md`](README.md)，协议在 [`../../PROTOCOL.md`](../../PROTOCOL.md)。

## 1. 背景（30 秒读懂）

Traiectus 是个人的轻量级 KVM：把 Windows 上的鼠标，通过局域网“复制”给 Mac mini 使用。

```text
鼠标 ──► Windows PC ──────────────► Mac mini
          Traiectus Server（监听端）   Traiectus Client（连接端）
          只读捕获 + TCP 转发         CGEvent 注入本机
```

- **Windows 是监听端**，Mac 主动连过来。默认端口 **45789**。
- 协议：行文本（`HELLO` / `MOVE` / `DOWN` / `UP` / `WHEEL` / `PING` / `BYE`），见 `PROTOCOL.md`。
- 已经验证过的部分：Phase 1（Raw Input 只读捕获，真机测过）、Phase 2（Mac 端 CGEvent 注入，真机测过）、Phase 3 的 **Mac 客户端**（协议层 + 移动／左键／右键／中键／滚轮全部实测通过）。
- **没验证过的部分：就是这个 Windows 服务端**——写它的那台 Mac 上没有 Windows 编译器，所以它一次都没编译过。

## 2. 安全红线（一条都不能违反）

这是本项目的硬约束，不是口号：

1. 不影响 Windows 正常鼠标输入
2. 不影响 Windows 键盘
3. 不修改 Windows 系统文件、注册表、系统设置
4. 不安装驱动、不使用内核驱动、不用 `SetWindowsHookEx`
5. 不修改鼠标厂商软件（G HUB 之类）的配置、不改鼠标 DPI、不改固件
6. **不修改防火墙规则**（要改必须由用户明确同意）
7. 程序退出／崩溃后，本机鼠标必须完全正常
8. **位移只发相对增量，绝不发绝对坐标**
9. 不注入、不拦截、不阻断本机输入（唯一允许的注入发生在 Mac 侧）

如果任何一步需要突破上面任何一条，**停下来报告**，不要自行决定。

## 3. 需要哪些文件

如果这台 Windows 上还没有这些文件，先同步：

```text
Traiectus/
├─ PROTOCOL.md                        # 协议定义（两端共用的唯一事实来源）
└─ windows/phase3-tcp/
   ├─ README.md                       # 设计说明与测试清单（更详细）
   ├─ Windows端操作步骤.md              # 本文件
   ├─ CMakeLists.txt                  # 方式 B 用
   ├─ build.bat                       # 方式 A（MSVC）用
   └─ src/main.cpp                    # 全部服务端代码（单文件）
```

## 4. 编译

### 方式 A：w64devkit（本机已知装过，免安装、免管理员）——推荐

直接运行现成的脚本。**不要手抄多行命令**——`^` 续行从文档复制粘贴到 cmd 里很容易抄坏：

```bat
cd /d <你放 Traiectus 的路径>\windows\phase3-tcp
build-mingw.bat
```

脚本会自己找 `g++.exe`（依次尝试 `%USERPROFILE%\tools\w64devkit`、`%USERPROFILE%\tools\w64devkit`、`C:\w64devkit`，最后回落到 PATH），编译失败时打印完整输出与错误码。

> 非要手敲的话，等价命令是：
>
> ```bat
> cd /d <路径>\windows\phase3-tcp
> mkdir build 2>nul
>
> "%USERPROFILE%\tools\w64devkit\bin\g++.exe" -std=c++17 -O2 -Wall -Wextra -municode -mconsole ^
>    -DUNICODE -D_UNICODE -D__USE_MINGW_ANSI_STDIO=1 -static -static-libgcc -static-libstdc++ ^
>    -o build\Traiectus-Server.exe src\main.cpp -luser32 -lgdi32 -lws2_32
> ```

### 方式 B：MSVC

打开「x64 Native Tools Command Prompt for VS 2022」，然后：

```bat
cd /d <路径>\windows\phase3-tcp
build.bat
```

### 产物

`build\Traiectus-Server.exe` —— **静态链接**，拷到别的机器上也能直接跑，不用带 DLL。

### 编译失败怎么办

**第一处报错才是原因**，后面的多半是被它带出来的连锁反应。最常见的原因是编译器太老
（需要 C++17）。

**不要为了让它编过而改设计**（把相对位移改成绝对坐标、加 hook、加防火墙规则之类）——
那些都是刻意的选择，见第 13 节。

## 5. 先做不需要 Mac 的自检

```bat
rem 1) 列出鼠标类设备，确认你的鼠标还在
build\Traiectus-Server.exe --list
rem    预期能看到：VID_xxxx&PID_xxxx&MI_00  (鼠标无线接收器)

rem 2) 只看帮助
build\Traiectus-Server.exe --help

rem 3) 启动（先不带设备过滤也可以，只为确认能起来）
build\Traiectus-Server.exe --port 45789
rem    预期：打印监听地址 + 一行鉴权状态（"尚未配对"或"已配对"），之后每秒钟一行统计
```

**同时确认**：整个过程中 Windows 自己的鼠标、键盘完全正常；按 Ctrl+C 退出后也完全正常。

```bat
rem 4) 协议层自检：服务端保持运行，另开一个 cmd 窗口跑这个
powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\tools\test-client.ps1 -Token test123
rem    预期四项全通过：HELLO-OK / 收到服务端 PING / 回 PONG / 服务端回应脚本的 PING
rem    这一步不需要 Mac，能先把"服务端协议层是否正常"单独摘出来判断。
rem    注意：不要用这个脚本发 MOVE/DOWN/UP/WHEEL——那是反方向的命令。
```

## 6. 防火墙（需要用户确认，不要擅自改）

首次运行时 Windows 会弹窗：「Windows Defender 防火墙已阻止此应用的部分功能」。

- **勾选「专用网络」，点允许**。不要勾「公用网络」——那会让这个端口在所有网络（包括以后连的公共 WiFi）上开放。
- 如果弹窗没出现或没放行，可以请用户在**管理员**命令行里加一条最小范围的规则（**由用户执行**）：

```bat
netsh advfirewall firewall add rule name="Traiectus Server" dir=in action=allow ^
  program="<完整路径>\build\Traiectus-Server.exe" protocol=TCP localport=45789 ^
  profile=private enable=yes
```

**不要**用“临时关掉防火墙”之类的办法绕过。

## 7. 和 Mac 联调

1. 在 Windows 上查自己的内网 IP：

   ```bat
   ipconfig
   ```

2. 启动服务端（**不用设口令**）：

   ```bat
   build\Traiectus-Server.exe --device "VID_xxxx&PID_xxxx&MI_00"
   ```

   启动横幅会有一行鉴权状态：全新机器显示「**尚未配对**」（这是正常的，不是警告）；
   已经配过对显示「**已配对（口令来自 …\paired.json）**」。

   > `&` 在 cmd 里是命令分隔符，设备串的引号不能省。

3. Mac 侧（由 Mac 侧的人／AI 负责）：Traiectus Client 里**地址可以留空**——
   它会先试记住的地址，再向网段广播 `WHO 1`（UDP 45791），
   服务端会单播回 `HERE 1 45789`，Mac 就自动填好地址和端口了。点连接即可。
   首次会弹「允许访问本地网络」，选允许。这台 Windows 还没配对过时，
   **Windows 屏幕上会弹一个确认框**（两行字 + 「允许 / 拒绝」），点「允许」即完成配对；
   Mac 那边不用填任何口令。

4. 握手成功时，Windows 控制台会出现类似这样的行：

   ```text
   [..] 客户端 已连接（握手完成）| 发送   0 行/秒 | 队列   0 | 往返 0 ms | 本机捕获   0 pkt/s
   ```

   同时 Mac 侧日志会出现 `握手成功（协议版本 1）`。

## 8. 测试清单（按顺序做，逐项记结果）

| # | 做什么 | 预期 |
|---|---|---|
| 1 | Windows 上移动鼠标 | Mac 光标跟着动，方向一致（右→右、下→下），不跳变 |
| 2 | Mac 上点左键 / 右键 | 产生真实点击；同时 Windows 本机鼠标一切照常 |
| 3 | 中键、侧键 | Mac 侧用 `tools/mouse-event-probe.html` 看，应显示 button 1 / 3 / 4 |
| 4 | 滚轮上下 | Mac 上方向与 Windows 一致（Mac 侧判据：页面 deltaY 负=上、正=下） |
| 5 | 在 Windows 上打字、正常操作 | 完全不受影响；键盘事件根本不会进入这个程序 |
| 6 | 关掉 Mac 客户端 | Windows 端 3 秒内打印「超过 3 秒没收到对端任何数据」，回到等待状态，鼠标照常 |
| 7 | 重新打开 Mac 客户端 | 1 秒内自动重连上 |
| 8 | 拔网线 / 关 Wi-Fi | 两边都判定断线；两台机器的鼠标都完全正常 |
| 9 | 任务管理器强杀 Traiectus-Server.exe | Windows 鼠标**立刻完全正常** |
| 10 | 关闭控制台窗口 | 程序退出，鼠标正常 |

**要求**：第 1–10 项每一步都记录「实际发生了什么」，不要写“应该没问题”。

## 9. 出问题时怎么定位

| 症状 | 先查这里 |
|---|---|
| Mac 连不上 | Mac 上 `nc -vz <windows-ip> 45789`；Windows 上 `netstat -ano \| findstr 45789` 看是否在监听；确认防火墙放行的是**专用网络** |
| 连上但不动 | Windows 控制台的「本机捕获 pkt/s」是否为 0 → 是设备过滤串不对，用 `--list` 重查；加 `--verbose` 看事件有没有往外发 |
| 事件发了但 Mac 没反应 | Mac 侧权限问题（辅助功能未授权），由 Mac 侧处理 |
| 日志出现「收到不认识的命令」 | 两端协议版本不一致，对照 `PROTOCOL.md` |
| 报握手失败 | 口令不一致（区分大小写），或协议版本不是 1 |

## 10. 停止与清理

**从托盘启动的**：右键点托盘圆点 →「退出」。服务端、看门狗、端口、光标锁定会一次性清干净
（Job Object，见 [`launcher/说明.md`](../launcher/说明.md) 第五节）。

**手动启动的**：在控制台里按 Ctrl+C，或者直接关掉窗口。

两种方式都不会留下服务、开机自启项、注册表键或驱动。

如果装到了 `%LOCALAPPDATA%\Traiectus\`，双击 `launcher\卸载 Traiectus.bat` 卸载。

---

## 11. 回报模板（可选：照这个填，方便别人帮你排查）

```text
1. 编译
   - 结果：成功 / 失败
   - 编译器与版本：
   - 报错全文（若失败）：
   - 若修过代码：附 git diff

2. --list 里你那行鼠标设备的输出：

3. 防火墙
   - 弹窗选了：专用网络 / 公用网络 / 未放行
   - 或手动加了规则（贴命令）

4. 联调
   - 握手：成功 / 失败（贴两边日志各一行）
   - 移动：
   - 左键 / 右键：
   - 中键 / 侧键：
   - 滚轮：
   - Windows 本机鼠标键盘是否完全正常：

5. 故障场景
   - 关掉 Mac 客户端后，Windows 端 3 秒内是否打印断线：
   - 重开 Mac 客户端后是否 1 秒内重连：
   - 强杀 Traiectus-Server.exe 后 Windows 鼠标是否正常：

6. 其他异常／疑问：
```

## 12. 不要做的事（避免两边不一致）

- 不要改协议（命令名、字段含义、端口默认值）——要改先和 Mac 侧说，`PROTOCOL.md` 是两端共用的
- 不要改成绝对坐标、不要加 hook／驱动／`SendInput`、不要顺手加防火墙规则
- 不要把 Raw Input 换成别的输入读取方式（Phase 1 已经验证过这条路可行且只读）
- 不要为了“让它更好用”而扩大范围：本阶段的唯一目标是**能编译、能联调、能验证第 8 节那 10 项**

## 13. 附录：这些行为是刻意的，不要"修"它们

- 位移只发相对增量。绝对坐标在两台机器分辨率或缩放不同时会跳。
- 新连接会顶掉旧连接，所以重启过的 Mac 不会卡在一条僵死的旧连接上。
- `ClipCursor` 被有权限的窗口清掉是**好事** —— 那是系统级的逃生口。
- 安全桌面（UAC 弹窗、锁屏）上什么都收不到，这是 Windows 的设计，任何用户态程序都一样。
- TCP 分帧靠行缓冲：代码从不假设一次 `recv()` 正好返回一条消息。
