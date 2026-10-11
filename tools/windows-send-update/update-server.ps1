param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$statePath = Join-Path $root 'installed-state.json'
$backup = $null
$target = $null
$launcher = $null
$stopped = $false
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TraiectusUpdateCursor {
    [DllImport("user32.dll")]
    public static extern bool ClipCursor(IntPtr rect);
}
'@
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Start-Launcher($Path) {
    Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) | Out-Null
}
try {
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    $payload = Join-Path $root 'Traiectus-Server.exe'
    if ((Hash $payload) -ne $manifest.server_sha256) { throw 'Package checksum mismatch. No change made.' }
    $processes = @(Get-CimInstance Win32_Process)
    $servers = @($processes | Where-Object {
        $_.Name -eq 'Traiectus-Server.exe' -and $_.CommandLine -notmatch '--watchdog'
    })
    if ($servers.Count -ne 1) { throw 'Start the current Traiectus tray first. Exactly one server is required.' }
    $server = $servers[0]
    $target = $server.ExecutablePath
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { throw 'Cannot locate the running server. No change made.' }
    $parents = @($processes | Where-Object {
        $_.ProcessId -eq $server.ParentProcessId -and $_.Name -eq 'Traiectus.exe'
    })
    if ($parents.Count -ne 1 -or -not $parents[0].ExecutablePath) {
        throw 'Server is not owned by the Traiectus tray. No change made.'
    }
    $tray = $parents[0]
    $launcher = $tray.ExecutablePath
    $originalHash = Hash $target
    if ($Restore) {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($saved.server_path -ne $target -or $originalHash -ne $saved.installed_sha256) {
            throw 'Installed server differs from this update. Restore stopped without changes.'
        }
        if ((Hash $saved.backup_path) -ne $saved.original_sha256) { throw 'Backup checksum mismatch.' }
        $replacement = $saved.backup_path
        $replacementHash = $saved.original_sha256
    } else {
        if ($originalHash -eq $manifest.server_sha256) { Write-Host 'Already installed and running.'; exit 0 }
        $replacement = $payload
        $replacementHash = $manifest.server_sha256
    }
    $backupDir = Join-Path (Split-Path -Parent $target) 'send-wake-backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir ('Traiectus-Server-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.exe')
    Copy-Item -LiteralPath $target -Destination $backup
    if ((Hash $backup) -ne $originalHash) { throw 'Backup verification failed. No process stopped.' }
    Write-Host 'Updating the mouse server. Shared mouse briefly disconnects; native Windows mouse remains available.'
    # Stop only the observed tray and its server. Explicitly release any cursor
    # clip: stopping the tray also closes its job and may terminate its watchdog.
    Stop-Process -Id $tray.ProcessId -ErrorAction Stop
    $stopped = $true
    # Stopping the tray normally takes its server down with it through the job
    # object, so the server can disappear between the check and the stop. Only
    # fail when it is genuinely still alive.
    if (Get-Process -Id $server.ProcessId -ErrorAction SilentlyContinue) {
        try { Stop-Process -Id $server.ProcessId -ErrorAction Stop }
        catch {
            if (Get-Process -Id $server.ProcessId -ErrorAction SilentlyContinue) { throw }
        }
    }
    [TraiectusUpdateCursor]::ClipCursor([IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 400
    Copy-Item -LiteralPath $replacement -Destination $target -Force
    if ((Hash $target) -ne $replacementHash) { throw 'Installed checksum mismatch.' }
    Start-Launcher $launcher
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        $running = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Traiectus-Server.exe' -and $_.ExecutablePath -eq $target -and $_.CommandLine -notmatch '--watchdog'
        })
    } while ($running.Count -eq 0 -and (Get-Date) -lt $deadline)
    if ($running.Count -ne 1) { throw 'Updated server failed to start.' }
    if (-not $Restore) {
        @{
            server_path=$target; launcher_path=$launcher; backup_path=$backup
            original_sha256=$originalHash; installed_sha256=$replacementHash
            installed_at=(Get-Date).ToString('o'); source_commit=$manifest.source_commit
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
    @{
        action=$(if($Restore){'restored'}else{'installed'})
        server_path=$target; sha256=$replacementHash; process_id=$running[0].ProcessId
        checked_at=(Get-Date).ToString('o'); source_commit=$manifest.source_commit
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'Windows更新回报.json') -Encoding UTF8
    Write-Host 'SUCCESS: server restarted; pairing/configuration files were preserved.'
} catch {
    Write-Host ('FAILED: ' + $_.Exception.Message)
    if ($stopped -and $backup -and $target) {
        try {
            $live = @(Get-CimInstance Win32_Process | Where-Object {
                $_.Name -eq 'Traiectus-Server.exe' -and $_.ExecutablePath -eq $target -and $_.CommandLine -notmatch '--watchdog'
            })
            foreach ($p in $live) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue }
            $trays = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'Traiectus.exe' -and $_.ExecutablePath -eq $launcher })
            foreach ($p in $trays) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue }
            [TraiectusUpdateCursor]::ClipCursor([IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 400
            Copy-Item -LiteralPath $backup -Destination $target -Force
            Start-Launcher $launcher
            Write-Host 'Previous server restored and tray restarted.'
        } catch { Write-Host ('Automatic restore failed: ' + $_.Exception.Message); Write-Host ('Backup: ' + $backup) }
    }
    exit 1
}
