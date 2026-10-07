# ============================================================================
#  K70 endpoint byte scan  (Traiectus / keyboard-switch sub-project)
# ----------------------------------------------------------------------------
#  Why: three single-shot attempts (endpoint 0x08, 0x08, then 0x09) were all
#  accepted by Windows ("bytes written 65") yet the keyboard never moved.
#  The routing byte in front of the 01 3A command is therefore still unknown.
#  The space is one byte, and the reference implementation only ever uses
#  values 0x08..0x0F for it, so a bounded scan answers the question in one run
#  instead of one guess per evening.
#
#  What it does, per candidate byte:
#      build 65 bytes = 00 <candidate> 01 3A 00 02 (+ 59 zero bytes)
#      one WriteFile() call, then a short pause
#  Mode 0x02 = Bluetooth Host 1 = the Mac, so a hit makes the keyboard appear
#  on the Mac, which is detectable from the Mac side (tools/k70-watch.py).
#
#  It does NOT loop forever, does not retry a value, and prints a timestamp for
#  every attempt so the Mac-side log can be matched against it.
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    [string]$Match = "vid_1b1c&pid_1ba6&mi_01",
    [int]$Vid = 0x1B1C,
    [string]$OutFile = "",
    [string]$Endpoints = "09,08,0A,0B,0C,0D,0E,0F,00,01,02,03,04,05,06,07",
    [int]$DelayMs = 2500
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "K70-HidLib.ps1")

if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot "K70-Sweep-Result.txt" }

$script:Lines = New-Object System.Collections.Generic.List[string]
function Emit {
    param([string]$Text = "")
    Write-Host $Text
    $script:Lines.Add($Text) | Out-Null
}

Emit "==== K70 endpoint scan (one WriteFile per candidate) ===="
Emit ("started : " + (Get-Date).ToString("HH:mm:ss"))
Emit ("match   : " + $Match)
Emit ""

$interfaces = [K70HidLib]::Enumerate([uint16]$Vid)
$target = $null
foreach ($iface in $interfaces) {
    if ($iface.Path.ToLower().Contains($Match.ToLower())) { $target = $iface; break }
}
if ($null -eq $target) {
    Emit ("[error] no interface matches " + $Match)
    $script:Lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8
    exit 3
}

Emit ("target  : " + $target.Path)
Emit ("product : " + $target.Product)
Emit ("report  : input={0} output={1}" -f $target.InputReportByteLength, $target.OutputReportByteLength)
Emit ""

$handle = [K70HidLib]::OpenForWrite($target.Path)
if ($handle.ToInt64() -eq -1) {
    Emit ("[error] CreateFile for write failed, Win32 error " + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    $script:Lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8
    exit 4
}

try {
    $list = $Endpoints -split "[,\s]+" | Where-Object { $_ -ne "" }
    Emit ("candidates: " + ($list -join " "))
    Emit ""
    Emit "time      endpoint  result            bytes"
    Emit "-------------------------------------------------"

    foreach ($item in $list) {
        $ep = [Convert]::ToByte($item, 16)
        $buffer = New-Object byte[] 65
        $buffer[0] = 0x00
        $buffer[1] = $ep
        $buffer[2] = 0x01
        $buffer[3] = 0x3A
        $buffer[4] = 0x00
        $buffer[5] = 0x02

        $written = 0
        $err = 0
        $ok = [K70HidLib]::WriteOutputReport($handle, $buffer, [ref]$written, [ref]$err)
        $stamp = (Get-Date).ToString("HH:mm:ss.fff")
        Emit ("{0}  0x{1:X2}     {2,-16} {3} (err {4})" -f $stamp, $ep, $ok, $written, $err)
        Start-Sleep -Milliseconds $DelayMs
    }

    Emit "-------------------------------------------------"
    Emit ("finished : " + (Get-Date).ToString("HH:mm:ss"))
}
finally {
    [K70HidLib]::CloseHandle($handle) | Out-Null
}

Emit ""
Emit "If the keyboard moved to the Mac during this run, the last line BEFORE you"
Emit "noticed is the winning endpoint. One WriteFile per candidate, no retries."

$script:Lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host ("result file: " + $OutFile)
