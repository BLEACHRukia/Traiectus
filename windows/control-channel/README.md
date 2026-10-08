# Traiectus 控制通道 / 防火墙

> 原文件名是 `MiniKVM ...`（2026-09-29 改名为 Traiectus）。
> 端口、口令、报文格式**一律未改**。

## 1. 现在需要放行什么

| 规则 | 端口 | 方向 | 要不要 |
|---|---|---|---|
| `Traiectus server TCP 45789` | 45789 | 入站 | **要**（Mac 客户端连过来） |
| `Traiectus discovery UDP 45791` | 45791 | 入站 | **要**（Mac 广播 `WHO 1`，服务端单播回 `HERE 1 45789`，见 `PROTOCOL.md` §7.2） |

抢跑那条 **UDP 45790 不需要入站规则**：它是服务端**发出去**的（发到 Mac 的 45790），
Mac 的回包（`PING`）回到服务端那个 socket 的**临时端口**上，Windows 防火墙按状态放行 ——
代码里写的也是 `local.sin_port = 0`（临时端口）。

历史规则名是 `MiniKVM control channel UDP 45791`，现在的名字是 `Traiectus discovery UDP 45791`。

## 2. 一键处理（Windows，管理员）

```
Traiectus-防火墙放行.bat        （内部调用 Traiectus-firewall.ps1）
```

它做三件事（重复运行也安全）：

1. 确保存在 `Traiectus server TCP 45789` 入站放行（**按端口**，以后 exe 改名也不会失效）；
2. 确保存在 `Traiectus discovery UDP 45791` 入站放行 —— 旧名字还在就改名，不在就新建；
3. 删掉**按程序路径**的旧规则（名字以 `.exe` 结尾那些：`minikvm-server.exe`、`traiectus-server-*.exe` …），
   它们放行的是"任何端口"，太宽，没必要留。

## 3. 手动等价命令（管理员 PowerShell）

```powershell
# 查看现有相关规则
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'Traiectus|MiniKVM|minikvm-server' } |
    Select-Object DisplayName,Enabled,Profile,Direction,Action | Format-Table -AutoSize

# 加服务端放行
New-NetFirewallRule -DisplayName "Traiectus server TCP 45789" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 45789 -Profile Any | Out-Null

# 地址发现的放行（按端口）：旧名还在就改名，不在就新建
if (Get-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" `
        -NewDisplayName "Traiectus discovery UDP 45791"
} else {
    New-NetFirewallRule -DisplayName "Traiectus discovery UDP 45791" -Direction Inbound -Action Allow `
        -Protocol UDP -LocalPort 45791 -Profile Any | Out-Null
}
```

## 4. 清理"历史死规则"（可选，管理员）

早期版本的 exe 已不存在（旧 `Documents\鼠标` 副本、已删除的旧 exe、Codex 容器副本等），
但它们留下的防火墙规则还挂在系统里（名字形如 `minikvm-server.exe`）。
**不影响功能**，想清干净就（**先确认都是指向已不存在路径的死规则**）：

```powershell
# 先看一眼
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'minikvm-server|MiniKVM' } |
    Select-Object DisplayName,Enabled,Direction,Action | Format-Table -AutoSize

# 确认后再删
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'minikvm-server|MiniKVM' } |
    Remove-NetFirewallRule
```

## 5. 撤销

```powershell
Remove-NetFirewallRule -DisplayName "Traiectus server TCP 45789"
Remove-NetFirewallRule -DisplayName "Traiectus discovery UDP 45791"
```
