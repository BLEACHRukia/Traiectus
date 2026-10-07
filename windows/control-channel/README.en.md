# Traiectus control channel / firewall

> The original file name was `MiniKVM ...` (renamed to Traiectus on 2026-09-29).
> Ports, tokens and message formats **were not changed at all**.

## 1. What has to be allowed right now

| Rule | Port | Direction | Needed? |
|---|---|---|---|
| `Traiectus server TCP 45789` | 45789 | inbound | **Yes** (the Mac client connects in) |
| `Traiectus control channel UDP 45791` | 45791 | inbound | depends on the design — if control requests go through the bridge's return path (a loopback relay), **an inbound allowance is not required** |

The historical rule name was `MiniKVM control channel UDP 45791`; the rename task is "delete the old
one, create the new one".

## 2. One-click handling (Windows, administrator)

```
Traiectus-防火墙放行.bat        (calls Traiectus-firewall.ps1 under the hood)
```

It does two things:

1. makes sure an inbound allowance named `Traiectus server TCP 45789` exists;
2. renames the old `MiniKVM control channel UDP 45791` to `Traiectus control channel UDP 45791`.

## 3. Equivalent manual commands (administrator PowerShell)

```powershell
# look at the existing rules
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'Traiectus|MiniKVM|minikvm-server' } |
    Select-Object DisplayName,Enabled,Profile,Direction,Action | Format-Table -AutoSize

# add the server allowance
New-NetFirewallRule -DisplayName "Traiectus server TCP 45789" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 45789 -Profile Any | Out-Null

# rename the old name (only needed if it exists)
Get-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" -ErrorAction SilentlyContinue |
    Set-NetFirewallRule -NewDisplayName "Traiectus control channel UDP 45791"
```

## 4. Cleaning up "dead historical rules" (optional, administrator)

The executables from earlier versions no longer exist (the old `Documents\鼠标` copy, deleted old
executables, Codex container copies, …), but the firewall rules they left behind are still on the
system (names like `minikvm-server.exe`). **They do not affect anything**; if you want them gone
(**after confirming they all point at paths that no longer exist**):

```powershell
# take a look first
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'minikvm-server|MiniKVM' } |
    Select-Object DisplayName,Enabled,Direction,Action | Format-Table -AutoSize

# delete them once you are sure
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'minikvm-server|MiniKVM' } |
    Remove-NetFirewallRule
```

## 5. Undo

```powershell
Remove-NetFirewallRule -DisplayName "Traiectus server TCP 45789"
Remove-NetFirewallRule -DisplayName "Traiectus control channel UDP 45791"
```
