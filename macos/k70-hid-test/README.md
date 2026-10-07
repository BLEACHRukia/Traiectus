# K70HIDTest

> **Historical development tool / 历史开发工具**（2026-09）。Not needed to build or use Traiectus —
> kept for reference. The keyboard handling that actually shipped lives in
> `macos/phase3-tcp/src/KeyboardDetect.swift` and `KeyboardFrameRules.swift`.

用于验证 **Mac → USB HID Vendor Interface → CORSAIR K70 RGB PRO MINI → Connection Mode** 这条链路的最小测试工具。

> 本目录目前只完成 **阶段⑤（ReportBuilder）+ 阶段⑥（离线单元测试）**。
> **尚未实现**设备枚举、`info`、`dump`、以及任何真机写入（阶段⑦ 之后才做）。

## 已确认的事实（阶段 A 通过）

```text
USB VID / PID         = 0x1B1C / 0x1BB6
目标 Usage Page/Usage = 0xFF42 / 0x0001
Report ID             = 0（descriptor 中没有 Report ID 项）
Output Report         = 8 bit × 1024 = 1024 字节
Input  Report         = 1024 字节
Feature Report        = 无
hid_write() 长度       = 1025（1024 字节报告 + 1 字节 Report ID）
```

包结构（来自 OpenLinkHub `k70pmWU`，已与真机 descriptor 交叉验证）：

```text
[0]       0x00      Report ID
[1]       0x08      端点 / 通道
[2..3]    01 3A     Connection Mode 命令
[4]       0x00      固定参数
[5]       mode      0x01=SLIPSTREAM  0x02=BT1  0x03=BT2  0x08=BT3
[6..1024] 0x00      填充
总长 1025 字节
```

## 构建并运行离线测试

```bash
./scripts/build.sh
```

脚本优先使用 cmake；本机没有 cmake，会退回直接用 `c++`（Apple clang）编译 —— 两条路都只构建
`ReportBuilder` 与它的测试，**不包含任何设备写入功能**。

也可以用 CMake 手动构建（需要自行安装 cmake）：

```bash
cmake -S . -B build && cmake --build build --target ReportBuilderTest
./build/ReportBuilderTest
```

## 运行前需要授权（macOS 10.15 起）

| 命令 | 需要权限吗 |
|---|---|
| `K70HIDTest list` | **不需要**（只枚举，不打开设备） |
| `K70HIDTest info` | **需要「输入监控」权限**（要打开设备读 descriptor） |

**为什么**：该 USB 设备被 macOS 识别为**键盘类 HID**，打开它的**任何** HID 集合都会受 TCC 检查；
缺少「输入监控」时 `IOHIDDeviceOpen()` 直接返回 `kIOReturnNotPermitted (0xE00002E2)`，
**并且系统不会弹窗提示**（实测：该键盘 6 个接口全部被拒，与 usage page 是否为 0xFF42 无关）。

**怎么做**：系统设置 → 隐私与安全性 → **输入监控** → 添加**实际执行本工具的那个 App**
（自己用终端跑就加「终端」；由 Codex 代跑就加「ChatGPT/Codex」）→ 打开开关 →
**完全退出那个 App 再重开**（权限在进程启动时读取）。

> 注意：这是与"鼠标注入所需的「辅助功能」权限"**不同**的另一项权限。

## 真机写入（`test-*`，唯一允许写入的入口）

```bash
./build/K70HIDTest test-bt1                   # 目标 = 蓝牙 Host 1（风险最低）
./build/K70HIDTest test-slipstream --confirm  # 目标 = SLIPSTREAM（会把键盘交给 Windows）
./build/K70HIDTest test-bt2 --confirm         # 目标 = 蓝牙 Host 2
./build/K70HIDTest test-bt3 --confirm         # 目标 = 蓝牙 Host 3
```

约束与判定方式：

- 每次进程**只发送一次**：不重试、不循环、不轮询、不后台、不加定时器（只有一次 1500 ms 的固定等待用于观察）
- 非 `bt1` 的模式**必须显式加 `--confirm`**——那些模式有让键盘离开本机的风险，不加就直接拒绝、且不打开设备
- **必须在有「输入监控」权限的终端里运行**；没有权限时工具会在"打开设备"这一步停下，**不会写入**
- **成功判定分三层**，不把"写入成功"当成"切换成功"：
  1. `hid_write()` 返回值是否等于 1025
  2. 厂商接口是否仍可访问（是否重新枚举/消失）
  3. 连接模式是否**真的**改变——工具会检查是否出现蓝牙设备（PID `0x1B6E`）；无法确认时会明确写"无法独立确认"
- **恢复手段**：拔插 USB 线；或在键盘上按 Fn 组合键（`Fn+T` = 蓝牙 Host 1、`Fn+Caps` = SLIPSTREAM）

## 目录结构

```text
macos/k70-hid-test/
├─ README.md
├─ CMakeLists.txt
├─ src/
│  ├─ ReportBuilder.h      # 常量 + 构造接口（纯数据）
│  └─ ReportBuilder.cpp
├─ tests/
│  └─ ReportBuilderTest.cpp  # 离线单元测试（不碰设备）
└─ scripts/
   └─ build.sh
```

规范里规划的 `main.cpp` / `K70Device.*` / `HidTransport.*` 属于阶段⑦ 之后的设备访问层，
本阶段**刻意不创建**，以免出现"能编译但还没验证过"的设备写入路径。

## 安全边界（当前阶段）

- 不打开任何 HID 设备
- 不调用 `hid_write()`
- 不发送任何 Output Report
- 不执行 BT1 / BT2 / BT3 / SLIPSTREAM 切换
