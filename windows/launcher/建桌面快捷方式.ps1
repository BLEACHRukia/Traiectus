# ============================================================================
#  Create / repair the Traiectus desktop shortcut for the current user
# ----------------------------------------------------------------------------
#  It points at Traiectus.exe in this folder (the tray entry point you
#  double-click to start).
#
#  Why this script exists on its own:
#    * A shortcut pointing at %LOCALAPPDATA%\Traiectus\ can break in some
#      setups (for example when the path is affected by a container or by
#      folder redirection). Pointing at the exe inside the project folder is
#      the most reliable option.
#    * After copying the project somewhere else, run this script once and the
#      shortcut is repaired.
#
#  It does exactly one thing: write one .lnk to the desktop.
#  It does not touch the registry and does not install a service.
# ============================================================================

$ErrorActionPreference = 'Stop'

$exe = Join-Path $PSScriptRoot 'Traiectus.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host ("[error] not found: " + $exe)
    Write-Host "        run build-launcher.bat first."
    exit 1
}

$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
$lnk = Join-Path $desk 'Traiectus.lnk'

if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

$sh = New-Object -ComObject WScript.Shell
$s  = $sh.CreateShortcut($lnk)
$s.TargetPath       = $exe
$s.WorkingDirectory = $PSScriptRoot
$s.Description      = 'Traiectus'
$s.IconLocation     = ($exe + ',0')
$s.Save()

$v = $sh.CreateShortcut($lnk)
Write-Host ""
Write-Host ("Shortcut ready: " + $lnk)
Write-Host ("  target    : " + $v.TargetPath)
Write-Host ("  working   : " + $v.WorkingDirectory)
Write-Host ""
Write-Host "Double-click the desktop Traiectus shortcut to start."
