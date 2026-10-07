# K70 键盘切换 · 第二轮：只读探测（先搞清楚 Windows 上那个 `1BA6` 到底是什么）

> **Historical probe worksheet / 历史探测作业单**（2026-09-25）。The read-only probe was completed;
> its conclusions are part of the shipped implementation (`windows/phase3-tcp/`, see
> `PROTOCOL.md` §3 and `docs/ARCHITECTURE.en.md` §3). Kept as a record of how it was verified —
> do not run it as part of installing Traiectus.

**来自**：Mac 侧（Deep）　**日期**：2026-09-25
**目标**：确认 Windows 上那个厂商接口的真实身份与它期望的数据包长度，为"纯软件双向切换键盘"做最后一步准备。

---

## 0. 上一轮结果说明了什么（Mac 侧已分析完）

第一轮 `K70检查.bat` 的结果已经读到，有三个关键信息：

| 现象 | 含义 |
|---|---|
| Windows 看到的 Corsair 设备 PID 是 **`1BA6`**，不是 Mac 侧的 `1BB6` | `1BA6` 与 `1BB6` 是**不同的硬件身份**：`1BB6` = 键盘本体（USB 直连），`1BA6` = **SLIPSTREAM 接收器** |
| 该设备还带着 `usagePage=0xFF42` 的厂商接口：`MI_01`（usage 0x01）和 `MI_02`（usage 0x02） | **接收器自己就暴露了厂商接口**，与键盘在不在它手上无关 |
| 有键盘类（`MI_03`/`MI_05`）与鼠标类（`MI_00`/`MI_04`）接口 | 接收器对外始终"伪装"成键盘+鼠标（这是这类接收器的常态，插上就枚举，不管对端在不在） |

**Mac 侧同时确认了键盘此刻的归属**（只读命令 `hidutil list`）：

```text
0x1b1c  0x1b6e  ...  Bluetooth Low Energy  ...  CORSAIR K70 MINI     ← 键盘现在在 Mac 的蓝牙上
0x46d   0xc094  ...  USB                    ...  PRO X Wireless       ← 鼠标用有线接在 Mac 上（你的切换方案）
```

也就是说：键盘此刻**既不在 Mac 的 USB 上，也不在 Windows 的 USB 上**（否则它会以 `1BB6` 出现，而且 USB 优先会把它锁在那台机器上）。**在这种前提下 Windows 仍能看到 Corsair 的厂商接口 → 那个设备只能是插在 Windows 上的 SLIPSTREAM 接收器。**

这一条很重要，它推翻了我们之前"键盘不在接收器手上时谁都发不了命令"的判断：
**Windows 侧很可能永远有一个可以发命令的通道**（只要接收器插着）。

还没验证的是最后一环：**接收器能不能把命令真的送到"正在用蓝牙"的键盘上**。

---

## 1. 这一轮只做一件事：只读探测

三个问题：

1. `1BA6` 那个设备的**产品名**是什么（接收器 or 键盘本体）？
2. 它的厂商接口（`0xFF42/0x01`）**期望多少个字节**（`OutputReportByteLength`）？
   - `1025` → 与键盘直连同一套结构（1024 字节报告 + 1 字节 Report ID）
   - `65` → 接收器是另一套结构（64 字节报告 + 1 字节 Report ID，对应 OpenLinkHub 的 `k70pmW` 那条路径）
3. 它的 **Report Descriptor** 是不是与键盘直连时一模一样
   （键盘直连是 29 字节：`06 42 FF 09 01 A1 01 ... 91 02 C0`，脚本会把这段参考值一起打出来做对照）

**这一步不发送任何命令、不打开设备写入、不改任何设置。**

---

## 2. 怎么运行（不用键盘，只用鼠标）

把这三个文件放在同一个文件夹里（已在共享文件夹里），**双击 `K70-Probe.bat`** 即可：

```text
K70-Probe.bat          ← 双击这个
K70-Probe.ps1          ← 它调用的只读脚本
K70-HidLib.ps1         ← 只读/写入的公共库（本步骤只会用到读取部分）
```

结果会自动写到同目录的 **`K70-Probe-Result.txt`**，同时也会显示在窗口里。

> 前提与上一轮一样：**键盘保持在 Mac 的蓝牙上**，键盘的 USB 线不要插。

---

## 3. 请回报什么

把 **`K70-Probe-Result.txt` 整份**回传即可（它就是为"整份回传"设计的，不需要你提炼）。

如果你只想先看一眼，重点在这两行：

```text
---- summary ----
interfaces with usagePage 0xFF42 (vendor) : 2
   usage 0x01  output-report-bytes=???  input-report-bytes=???
```

---

## 4. 安全边界（重要）

- **只读**：本步骤不调用 `HidD_SetOutputReport`，不给任何设备发数据
- 不拔插接收器、不改键盘任何配置、不装驱动、不改注册表
- 键盘此刻正被 Mac 使用；**任何真正的切换命令都必须等 Mac 侧给出确切字节后再发**

同目录里的 **`K70-Send.ps1`** 是下一阶段要用的"单次发送"工具，**现在不要加 `-Execute` 运行它**。
它默认是 dry run（只打印将要发送的内容，不发送）；没有 `-Execute` 时它绝不会写设备。

---

## 5. 下一步（等这次结果回来后再定，先别做）

拿到 `OutputReportByteLength` 之后，Mac 侧会给出**确切的一条命令**，由 Windows 侧做一次单次写入测试。
预期的两条候选命令（**仅供预览，别现在发**）：

| 目标 | 6 个有效字节 | 说明 |
|---|---|---|
| 键盘 → Mac 蓝牙（Host 1） | `00 08 01 3A 00 02` | 回到 Mac |
| 键盘 → Windows 的 SLIPSTREAM | `00 08 01 3A 00 01` | 抢到 Windows |

发送方式（`-Length` 用探测结果填）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\K70-Send.ps1 -Hex "00 08 01 3A 00 01" -Length 1025
```

先不带 `-Execute` 跑一次，把输出发回 Mac 侧核对，再决定是否真发。

**回退手段**（万一键盘跑掉）：键盘上 `Fn+T` = 蓝牙 Host 1、`Fn+Caps` = SLIPSTREAM；或者插上 USB 线。

---

## 6. 如果是 Windows 侧的 Deep 在接手

本目录的脚本已经自包含：`K70-HidLib.ps1` 用 SetupAPI + hid.dll 的 P/Invoke 枚举 HID 接口、
读属性/字符串/`HidP_GetCaps`/Report Descriptor；`K70-Send.ps1` 是唯一包含写入的入口且被 `-Execute` 门控。
如果运行报错，把完整报错回传，Mac 侧改脚本。
