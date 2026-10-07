# ============================================================================
#  Traiectus cleanup helper — Windows side
# ----------------------------------------------------------------------------
#  Purpose: find (and optionally remove) leftovers of the OLD design:
#    * auto-start entries  (we deliberately do NOT auto-start: the tray is
#      started by hand — see launcher/说明.md "no autostart, no service")
#    * old shortcuts, old install folder, old firewall rule names
#
#  Default is REPORT ONLY.  Nothing is deleted unless you pass -Clean.
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
#
#  Usage:
#     powershell -NoProfile -ExecutionPolicy Bypass -File 清理旧版本残留.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File 清理旧版本残留.ps1 -Clean
#     ... -Clean -RemoveInstallDir      (only AFTER the new tray is installed)
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$RemoveInstallDir
)

$ErrorActionPreference = "Continue"
$pattern = "MiniKVM|Traiectus|KvmBridge"
$startup = [Environment]::GetFolderPath("Startup")
$desktop = [Environment]::GetFolderPath("Desktop")
$oldDir  = Join-Path $env:LOCALAPPDATA "MiniKVM"
$newDir  = Join-Path $env:LOCALAPPDATA "Traiectus"

function Head($t) { Write-Host ""; Write-Host "=== $t" -ForegroundColor Cyan }

Head "1) Startup folder (autostart) - we do NOT want any of these"
$autoFound = @()
Get-ChildItem -Path $startup -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match $pattern) {
        $autoFound += $_
        Write-Host ("   FOUND  " + $_.Name) -ForegroundColor Yellow
    }
}
if ($autoFound.Count -eq 0) { Write-Host "   none (correct)" -ForegroundColor Green }

Head "2) Scheduled tasks"
$tasksFound = @()
try {
    $tasksFound = Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskName -match $pattern -or $_.TaskPath -match $pattern }
    if ($tasksFound.Count -gt 0) {
        $tasksFound | ForEach-Object { Write-Host ("   FOUND  " + $_.TaskPath + $_.TaskName) -ForegroundColor Yellow }
    } else { Write-Host "   none (correct)" -ForegroundColor Green }
} catch { Write-Host "   (cannot enumerate scheduled tasks: $($_.Exception.Message))" }

Head "3) Registry Run entries"
$runFound = @()
foreach ($hive in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
                    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run")) {
    $props = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue
    if ($props) {
        $props.PSObject.Properties | Where-Object { $_.Name -match $pattern -or "$($_.Value)" -match $pattern } |
            ForEach-Object { $runFound += "$hive\$($_.Name)"; Write-Host ("   FOUND  $hive\$($_.Name) = $($_.Value)") -ForegroundColor Yellow }
    }
}
if ($runFound.Count -eq 0) { Write-Host "   none (correct)" -ForegroundColor Green }

Head "4) Install folders"
foreach ($d in @($oldDir, $newDir)) {
    if (Test-Path $d) {
        $size = (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        Write-Host ("   EXISTS " + $d + "   (" + [math]::Round($size/1KB,1) + " KB)")
    } else { Write-Host ("   absent " + $d) }
}
Write-Host "   note: %LOCALAPPDATA%\MiniKVM is the OLD install folder; delete it only"
Write-Host "         AFTER the new tray has been installed and verified."

Head "5) Firewall rules"
try {
    $fw = Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $pattern }
    if ($fw) { $fw | ForEach-Object { Write-Host ("   FOUND  " + $_.DisplayName + "  (" + $_.Direction + " " + $_.Action + ")") -ForegroundColor Yellow } }
    else { Write-Host "   none" -ForegroundColor Green }
} catch { Write-Host "   (needs an elevated shell to enumerate firewall rules)" }

Head "6) Desktop shortcuts"
$deskFound = @()
Get-ChildItem -Path $desktop -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match $pattern) { $deskFound += $_; Write-Host ("   FOUND  " + $_.Name) }
}
if ($deskFound.Count -eq 0) { Write-Host "   none" -ForegroundColor Green }

if (-not $Clean) {
    Write-Host ""
    Write-Host "REPORT ONLY.  Nothing was changed." -ForegroundColor Cyan
    Write-Host "To remove the obsolete AUTOSTART items (1 & 2), run again with -Clean."
    exit 0
}

Head "CLEANING (autostart only)"
foreach ($f in $autoFound) {
    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $f.FullName)) { Write-Host ("   removed " + $f.Name) -ForegroundColor Green }
    else { Write-Host ("   FAILED  " + $f.Name) -ForegroundColor Red }
}
foreach ($t in $tasksFound) {
    try {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        Write-Host ("   removed task " + $t.TaskPath + $t.TaskName) -ForegroundColor Green
    } catch { Write-Host ("   FAILED  task " + $t.TaskName + " (run as administrator?)") -ForegroundColor Red }
}

if ($RemoveInstallDir) {
    Head "REMOVING OLD INSTALL FOLDER"
    if (Test-Path $oldDir) {
        Write-Host "   stopping anything running from $oldDir ..."
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "$oldDir*" } | ForEach-Object {
                Write-Host ("   stopping " + $_.ProcessName + " (" + $_.Id + ")")
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        Start-Sleep -Milliseconds 800
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $oldDir) { Write-Host "   FAILED (still running? close the tray first)" -ForegroundColor Red }
        else { Write-Host "   removed $oldDir" -ForegroundColor Green }
    } else { Write-Host "   already absent" }
}

Write-Host ""
Write-Host "Done.  Firewall rules and desktop shortcuts are NOT touched automatically:" -ForegroundColor Cyan
Write-Host "  * firewall rule rename/removal belongs to the rename task (see Traiectus task list)"
Write-Host "  * desktop shortcut: re-create it with launcher/建桌面快捷方式.ps1 after the rename"
Write-Host ""
Write-Host "REMINDER: Traiectus does NOT auto-start. Do not add startup entries." -ForegroundColor Cyan
