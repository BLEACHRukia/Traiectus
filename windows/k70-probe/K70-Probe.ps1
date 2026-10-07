# ============================================================================
#  K70 HID interface probe  (MiniKVM / keyboard-switch sub-project)
# ----------------------------------------------------------------------------
#  STRICTLY READ-ONLY.
#      * enumerates HID interfaces of vendor 0x1B1C (Corsair)
#      * prints vid/pid/version, product/manufacturer/serial strings
#      * prints usagePage / usage and report lengths (HidP_GetCaps)
#      * prints the raw report descriptor
#  It never calls HidD_SetOutputReport, never writes to any device, installs
#  nothing, changes nothing. The write primitive only lives in K70-Send.ps1,
#  which refuses to do anything without -Execute.
#
#  Why this is needed (short version):
#      The keyboard itself is currently on the Mac over Bluetooth, yet Windows
#      still sees a Corsair device (PID 1BA6) with a vendor interface
#      (usagePage 0xFF42). We need to know what that interface really is and
#      what packet length it expects before anyone sends a command to it.
#
#  Usage:
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\K70-Probe.ps1
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\K70-Probe.ps1 -OutFile C:\path\out.txt
#
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    [string]$OutFile = "",
    [int]$Vid = 0x1B1C
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "K70-HidLib.ps1")

if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot "K70-Probe-Result.txt" }

$script:K70Lines = New-Object System.Collections.Generic.List[string]

function Emit {
    param([string]$Text = "")
    Write-Host $Text
    $script:K70Lines.Add($Text) | Out-Null
}

function Get-UsageText {
    param([int]$Page, [int]$Usage)
    return ("0x{0:X4} / 0x{1:X2}" -f $Page, $Usage)
}

Emit "==== K70 HID interface probe (READ ONLY) ===="
Emit ("generated : " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Emit ("host      : " + $env:COMPUTERNAME)
Emit ("user      : " + $env:USERNAME)
Emit ("filter    : HID interfaces with VID 0x{0:X4}" -f $Vid)
Emit ""
Emit "This script only enumerates interfaces and reads descriptors."
Emit "It does NOT write to any device."
Emit ""

$interfaces = [K70HidLib]::Enumerate([uint16]$Vid)

Emit ("---- interfaces found: " + $interfaces.Length + " ----")
Emit ""

$index = 0
$vendorInterfaces = New-Object System.Collections.Generic.List[object]

foreach ($iface in $interfaces) {
    $index++
    Emit ("[{0}] {1}" -f $index, $iface.Path)
    Emit ("     vid/pid/ver : {0:X4} / {1:X4} / {2:X4}" -f $iface.Vid, $iface.Pid, $iface.Version)
    Emit ("     product     : " + $iface.Product)
    Emit ("     manufacturer: " + $iface.Manufacturer)
    if ($iface.Serial) { Emit ("     serial      : " + $iface.Serial) }
    Emit ("     usagePage   : " + (Get-UsageText -Page $iface.UsagePage -Usage $iface.Usage) +
          ("   (decimal {0} / {1})" -f $iface.UsagePage, $iface.Usage))
    Emit ("     report bytes: input={0}  output={1}  feature={2}" -f `
          $iface.InputReportByteLength, $iface.OutputReportByteLength, $iface.FeatureReportByteLength)

    if ($iface.Descriptor) {
        Emit ("     descriptor  : {0} bytes" -f $iface.Descriptor.Length)
        Emit ("       HEX: " + (ConvertTo-K70Hex -Bytes $iface.Descriptor))
    } else {
        Emit ("     descriptor  : <unavailable> " + $iface.DescriptorError)
    }
    if ($iface.OpenError) { Emit ("     note        : " + $iface.OpenError) }
    Emit ""

    if ($iface.UsagePage -eq 0xFF42) { $vendorInterfaces.Add($iface) | Out-Null }
}

Emit "---- summary ----"
Emit ("HID interfaces with VID 0x{0:X4} : {1}" -f $Vid, $interfaces.Length)
Emit ("interfaces with usagePage 0xFF42 (vendor) : " + $vendorInterfaces.Count)
foreach ($v in $vendorInterfaces) {
    Emit ("   usage 0x{0:X2}  output-report-bytes={1}  input-report-bytes={2}  -> {3}" -f `
          $v.Usage, $v.OutputReportByteLength, $v.InputReportByteLength, $v.Path)
}
Emit ""
Emit "Reference (keyboard plugged into the Mac by USB cable, PID 1BB6):"
Emit "   usagePage 0xFF42 / usage 0x01, descriptor 29 bytes:"
Emit "   06 42 FF 09 01 A1 01 15 00 26 FF 00 75 08 96 00 04 09 01 81 02 96 00 04 09 01 91 02 C0"
Emit "   -> input 1024 bytes, output 1024 bytes, no report IDs, hid_write length 1025"
Emit ""
Emit "---- done ----"

$script:K70Lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host ("result file: " + $OutFile)
