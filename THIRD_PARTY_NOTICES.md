# 第三方组件与声明

本仓库自带或依赖以下第三方组件。各自的许可文件都保留在对应目录里。

| 组件 | 用在哪 | 许可 | 许可文件 |
|---|---|---|---|
| **hidapi** | `macos/k70-hid-test/third_party/hidapi`（Vendor HID 研究工具） | BSD-3-Clause | `LICENSE.txt` / `LICENSE-bsd.txt` |
| **m1ddc** | `macos/kvm-link/m1ddc`（显示器输入源切换，Mac 端默认用它） | MIT © 2021 waydabber | `LICENSE` |
| **asus-display-control (`dwc`)** | 显示器输入源切换（可选回退） | Apache-2.0 | **不随仓库分发**，见上游 |

## dwc（asus-display-control）

`dwc` 是 ASUS 官方的显示器控制命令行工具（Apache-2.0）。
本仓库**不随附**它的二进制 —— 需要时从上游取：

<https://github.com/ASUS-Display/asus-display-control>

Mac 端默认走 `m1ddc`（MIT），只有找不到 `m1ddc` 时才回退到 `dwc`。
两者都通过 DDC/CI 的 VCP `0x60`（Input Source）切输入源；具体编号因显示器而异。

## 商标

Corsair、K70、Logitech、G Pro、ASUS、macOS、Windows 等名称与商标归各自所有者。
本项目与 Corsair / Logitech / ASUS 均无隶属关系，也不是任何厂商的官方工具。
