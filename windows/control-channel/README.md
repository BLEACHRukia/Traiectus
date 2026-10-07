# Traiectus 控制通道 / 防火墙

> 原文件名是 `MiniKVM ...`（2026-09-29 改名为 Traiectus）。
> 端口、口令、报文格式**一律未改**。

## 1. 现在需要放行什么

| 规则 | 端口 | 方向 | 要不要 |
|---|---|---|---|
| `Traiectus server TCP 45789` | 45789 | 入站 | **要**（Mac 客户端连过来） |
| `Traiectus control channel UDP 45791` | 45791 | 入站 | 视方案而定 —— 若控制请求走桥接回包（loopback 中继），**入站放行不是必需的** |

历史规则名是 `MiniKVM control channel UDP 45791`；改名任务里**删旧建新**即可。

## 2. 一键处理（Windows，管理员）

```
Traiectus-防火墙放行.bat        （内部调用 Traiectus-firewall.ps1）
```

它做两件事：

1. 确保存在 `Traiectus server TCP 45789` 入站放行；
2. 把旧的 `MiniKVM control channel UDP 45791` 重命名为 `Traiectus control channel UDP 45791`。

## 3. 手动等价命令（管理员 PowerShell）

```powershell
# 查看现有相关规则
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'Traiectus|MiniKVM|minikvm-server' } |
    Select-Object DisplayName,Enabled,Profile,Direction,Action | Format-Table -AutoSize

# 加服务端放行
New-NetFirewallRule -DisplayName "Traiectus server TCP 45789" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 45789 -Profile Any | Out-Null

# 旧名重命名（存在才需要）
Get-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" -ErrorAction SilentlyContinue |
    Set-NetFirewallRule -NewDisplayName "Traiectus control channel UDP 45791"
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
Remove-NetFirewallRule -DisplayName "Traiectus control channel UDP 45791"
```
