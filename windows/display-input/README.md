# 给 Windows 端：显示器输入源切换 + 联动所需的能力

**来自**：Mac 侧（Deep）　**日期**：2026-09-25
**目标**：让"按一次键盘 `Fn` 键 = 键盘 + 鼠标 + 显示器一起切换"这套联动能真正跑起来。

---

## 1. 已经确认的事实（Mac 侧实测）

| 事实 | 证据 |
|---|---|
| 显示器是 **ASUS VG249Q**，Mac 接 **HDMI**，Windows 接 **DP** | 用户环境 |
| 输入源用标准 **VCP `0x60`**：`17` = HDMI-1（Mac），`15` = DP-1（Windows） | ASUS 官方 CLI `dwc` 的 `InputSource` 属性 |
| **Mac 能把屏幕切给 Windows**：`dwc set InputSource 15`，实测成功且很快 | Mac 侧实测 |
| **Mac 切不回来**：屏幕一旦在 DP 上，macOS 就完全看不到这台显示器 | `dwc list` → `No monitors detected`；`system_profiler SPDisplaysDataType` 里一个显示器都没有 |

**结论**：DDC/CI 只对"当前正在显示的那一路输入"有效。所以

- **Mac → Windows** 由 Mac 自己做（已验证）；
- **Windows → Mac 必须由 Windows 来做** —— 也就是下面要做的事。

---

## 2. 现在就要 Windows 端做的一件事：**验证 Windows 能把屏幕交回 Mac**

### 2.0 两条路，任选（推荐先试官方那条）

**路 A：ASUS 官方 CLI（最省事）**

ASUS 官方开源项目 **[ASUS-Display/asus-display-control](https://github.com/ASUS-Display/asus-display-control)**（Apache 2.0）
同时提供 Windows 与 macOS 版 CLI，命令完全一样；官方文档 `cli/docs/CLI_REFERENCE.md` 明确列出：

```text
InputSource: 1:VGA, 15:DP-1, 16:DP-2, 17:HDMI-1, 18:HDMI-2, ...
```

共享文件夹里已经放好官方 Windows 包 **`dwc_win.zip`**（来源：仓库 `cli/windows/dwc_win.zip`）。用法：

```bat
:: 解压 dwc_win.zip → 进入 dwc 目录
dwc.exe list                      :: 列出显示器
dwc.exe get InputSource           :: 读当前输入源（屏幕在 Windows 上时应当返回 15）
dwc.exe set InputSource 17        :: 切到 HDMI-1 = Mac
dwc.exe set InputSource 15        :: 切回 DP-1 = 本机
```

需要 VC++ 运行库（包内自带 `msvcp140.dll` / `vcruntime140.dll`，放在一起即可）。

**路 B：本目录的 PowerShell 脚本**（不需要编译器，见 2.1）

> 注意：本目录脚本的**第一版有个 bug** —— 枚举完物理显示器后立刻调用了 `DestroyPhysicalMonitors`，
> 之后再用那些句柄读/写就是"已失效句柄"，于是返回 `0xC026258C`。现已修正（句柄保持到用完为止）。
> 所以之前那次 `-1071241844` 的失败**不能说明 Windows 不能切**，需要用修正版或官方 CLI 重测。

### 2.1 本目录脚本的用法

工具已经写好了（纯 PowerShell + P/Invoke `dxva2.dll`，**不需要编译器**），在共享文件夹
`windows/display-input/` 里：

```text
显示器-读当前输入.bat        只读：打印当前 VCP 0x60 的值
显示器-切到Mac的HDMI.bat     set 17  → 屏幕交给 Mac
显示器-切到Windows的DP.bat   set 15  → 屏幕交回 Windows PC
MonInput.ps1                三个 bat 调用的脚本本体
```

### 测试步骤

1. 确认屏幕**现在显示的是 Windows**（也就是 Windows 的 DP 是活动输入）
2. 双击 **`显示器-读当前输入.bat`** → 应当看到 `current input : 15 = DP-1`
3. 双击 **`显示器-切到Mac的HDMI.bat`** → **屏幕应当切到 Mac 的 HDMI**（约 1 秒内）
4. 回报结果（结果同时写在同目录的 `Monitor-SetMac-Result.txt`）

**第 3 步成功 = 整套联动成立**：Mac 负责"切出去"，Windows 负责"切回来"。

如果第 2 步读不到值、或第 3 步返回 `False`，把输出原文发回来即可（可能是该显示器在非活动输入上不响应 DDC/CI，那就得换思路）。

> 安全边界：这个脚本只写 `VCP 0x60`（输入源），不碰亮度/对比度等任何其它设置，不改系统、不装驱动、不写注册表、不需要管理员权限。
> 备用方案：如果 PowerShell 版本有兼容问题，也可以用 NirSoft 的 ControlMyMonitor 手工验证
> （`ControlMyMonitor.exe /SetValue Primary 60 17`），或我给你一份等价的 C 程序（`SetVCPFeature`）。

---

## 3. 下一步（等第 2 节通过后再做）：让"切回来"自动化

现在这套联动的目标是：**用户只按一次键盘上的 `Fn` 键，键盘 + 鼠标 + 显示器全部跟着走**。

```text
按 Fn+Caps（键盘去 Windows）
   → Mac 检测到"键盘离开 Mac"（蓝牙设备消失）
   → Mac 执行：显示器切到 DP(15)  +  鼠标模式 = Win

按 Fn+T（键盘回 Mac）
   → Mac 检测到"键盘回到 Mac"（蓝牙设备出现）
   → Mac 通过 Traiectus 那条 TCP 连接告诉 Windows："把屏幕交给我，鼠标模式也切回 Mac"
   → Windows 执行：显示器切到 HDMI(17)  +  鼠标模式 = Mac
```

为此需要在 Windows 端加两样东西（都建议做进现有的 `Traiectus-Server.exe`，它本来就常驻、本来就连着 Mac）：

### 3.1 显示器切换能力

把 `MonInput.ps1` 里的 `SetVCPFeature(hMonitor, 0x60, value)` 直接用 C++ 实现即可
（`dxva2.dll`，链接 `-ldxva2`）：

```cpp
// 伪代码：取主显示器的物理句柄，然后写 VCP 0x60
HMONITOR hm = MonitorFromWindow(GetDesktopWindow(), MONITOR_DEFAULTTOPRIMARY);
DWORD n = 0;
GetNumberOfPhysicalMonitorsFromHMONITOR(hm, &n);
std::vector<PHYSICAL_MONITOR> pm(n);
GetPhysicalMonitorsFromHMONITOR(hm, n, pm.data());
for (auto& m : pm) SetVCPFeature(m.hPhysicalMonitor, 0x60, value);   // 17 = Mac, 15 = Windows
```

注意：**只有在 Windows 自己是活动输入（屏幕显示 DP）时才能成功**；屏幕在 Mac 上时这 PC 看不到显示器，
但那种情况下也不需要它切（Mac 会自己切）。

### 3.2 接受 Mac 指令的协议扩展（协议 v1.2 草案，待确认）

现在的协议规定 **Mac → Windows 只能发握手与心跳**（`PROTOCOL.md` §0），模式切换只能由 Windows 侧的
`Ctrl+Alt+M` 触发。要让 Mac 联动鼠标，需要加一条客户端 → 服务端的控制行：

```text
# Mac → Windows（新增，客户端在 HELLO-OK 之后可发）
MODE Mac            ; 请求把鼠标控制权交给 Mac（等价于 Ctrl+Alt+M 切到 Mac）
MODE Win            ; 请求把鼠标控制权交回 Windows
DISPLAY Mac         ; 请求 Windows 把显示器切到 HDMI-1（17）
DISPLAY Win         ; 请求 Windows 把显示器切到 DP-1（15）

# Windows → Mac（沿用现有风格，作为确认/广播）
MODE Mac | MODE Win
DISPLAY-OK Mac | DISPLAY-ERR Mac
```

- 服务端收到 `MODE` 就执行现有的模式切换逻辑（与 `Ctrl+Alt+M` 完全相同），并像现在一样广播 `MODE <值>`；
- 服务端收到 `DISPLAY` 就调用 3.1 的 DDC 切换，然后回一行 `DISPLAY-OK <值>` 或 `DISPLAY-ERR <值>`；
- `Ctrl+Alt+M` 保留为手动兜底，行为不变。

> 这部分要不要做、什么时候做，等第 2 节验证通过后再定（GPT 那边建议先不要动 Traiectus，我同意先验证显示器这条路）。

---

## 4. 请回报的内容

```text
1. `显示器-读当前输入.bat` 的输出（原文）
2. `显示器-切到Mac的HDMI.bat` 的输出（原文）
3. 屏幕有没有真的切到 Mac 的 HDMI：有 / 没有
4. 切过去之后，Mac 那边（用户）能不能正常看见画面并操作
5. 其它异常
```

---

## 5. 安全边界

- 只写显示器 VCP `0x60`（输入源），不碰其它任何设置
- 不装驱动、不需要管理员、不改注册表、不改系统设置
- 不拔插任何线；不改变显示器分辨率/刷新率
- 兜底手段永远在：显示器机身自带的输入源按键
