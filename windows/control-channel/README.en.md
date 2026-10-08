# Traiectus control channel / firewall

> The original file name was `MiniKVM ...` (renamed to Traiectus on 2026-09-29).
> Ports, tokens and message formats **were not changed at all**.

## 1. What has to be allowed right now

| Rule | Port | Direction | Needed? |
|---|---|---|---|
| `Traiectus server TCP 45789` | 45789 | inbound | **Yes** (the Mac client connects in) |
| `Traiectus discovery UDP 45791` | 45791 | inbound | **Yes** (the Mac broadcasts `WHO 1` and the server unicasts `HERE 1 45789` back — `PROTOCOL.md` §7.2) |

The head-start channel **UDP 45790 needs no inbound rule**: the server *sends* to the Mac's 45790,
and the Mac's replies (`PING`) come back to the **ephemeral port** of that same socket, which the
Windows firewall allows by state — the code literally binds `local.sin_port = 0`.

The historical rule name was `MiniKVM control channel UDP 45791`; it is now `Traiectus discovery UDP 45791`.

## 2. One-click handling (Windows, administrator)

```
Traiectus-防火墙放行.bat        (calls Traiectus-firewall.ps1 under the hood)
```

It does three things (safe to re-run):

1. makes sure an inbound allowance named `Traiectus server TCP 45789` exists (**port-scoped**, so it
   survives renaming the exe later);
2. makes sure `Traiectus discovery UDP 45791` exists — renaming the old rule if present, otherwise
   creating it;
3. removes **program-path-scoped** leftovers (names ending in `.exe`: `minikvm-server.exe`,
   `traiectus-server-*.exe`, …), which allow *any* port and are needlessly broad.

## 3. Equivalent manual commands (administrator PowerShell)

```powershell
# look at the existing rules
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'Traiectus|MiniKVM|minikvm-server' } |
    Select-Object DisplayName,Enabled,Profile,Direction,Action | Format-Table -AutoSize

# add the server allowance
New-NetFirewallRule -DisplayName "Traiectus server TCP 45789" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 45789 -Profile Any | Out-Null

# the discovery allowance (port-scoped): rename the old name if present, else create it
if (Get-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -DisplayName "MiniKVM control channel UDP 45791" `
        -NewDisplayName "Traiectus discovery UDP 45791"
} else {
    New-NetFirewallRule -DisplayName "Traiectus discovery UDP 45791" -Direction Inbound -Action Allow `
        -Protocol UDP -LocalPort 45791 -Profile Any | Out-Null
}
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
Remove-NetFirewallRule -DisplayName "Traiectus discovery UDP 45791"
```
