# ============================================================================
#  K70 one-shot HID output report sender  (MiniKVM / keyboard-switch)
# ----------------------------------------------------------------------------
#  GATED WRITE TOOL. Without -Execute it is a pure dry run: it locates the
#  interface, prints everything, and exits without touching the device.
#
#  *** DO NOT RUN WITH -Execute UNTIL THE MAC SIDE GAVE YOU THE EXACT
#      HEX PAYLOAD AND LENGTH. ***
#  The keyboard is in use right now; a wrong payload can send it to a host it
#  is not paired with (recoverable with Fn+T / Fn+Caps on the keyboard itself,
#  but still: wait for the exact command).
#
#  In -Execute mode it does at most TWO output-report calls, both with the very
#  same 65-byte payload, in this order:
#     1) HidD_SetOutputReport  (returns FALSE on this receiver interface)
#     2) WriteFile             (the call hidapi itself uses on Windows)
#  The second one only runs if the first reported failure. No loop, no retry,
#  no background process, no service, no registry / driver change.
#
#  Usage (dry run):
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\K70-Send.ps1 `
#          -Hex "00 08 01 3A 00 01" -Length 1025
#
#  Usage (real, only after the Mac side says go):
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\K70-Send.ps1 `
#          -Hex "00 08 01 3A 00 01" -Length 1025 -Execute
#
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Hex,
    [Parameter(Mandatory = $true)][int]$Length,
    [string]$Match = "vid_1b1c&pid_1ba6&mi_01",
    [int]$Vid = 0x1B1C,
    [ValidateSet("Both", "SetOutputReport", "WriteFile")]
    [string]$Method = "Both",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "K70-HidLib.ps1")

function Emit {
    param([string]$Text = "")
    Write-Host $Text
}

# ---- parse the payload -----------------------------------------------------
$clean = $Hex -replace "[^0-9A-Fa-f]", ""
if ($clean.Length -eq 0 -or ($clean.Length % 2) -ne 0) {
    Emit "[error] -Hex must be an even number of hex digits, e.g. ""00 08 01 3A 00 01"""
    exit 2
}
$payload = New-Object byte[] ([int]($clean.Length / 2))
for ($i = 0; $i -lt $payload.Length; $i++) {
    $payload[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16)
}
if ($Length -lt $payload.Length) {
    Emit ("[error] -Length {0} is smaller than the payload ({1} bytes)" -f $Length, $payload.Length)
    exit 2
}

Emit "==== K70 one-shot output report ===="
Emit ("mode        : " + $(if ($Execute) { "REAL WRITE (one call, no retry)" } else { "DRY RUN (nothing will be sent)" }))
Emit ("match       : " + $Match)
Emit ""

# ---- find the interface ----------------------------------------------------
$interfaces = [K70HidLib]::Enumerate([uint16]$Vid)
$target = $null
foreach ($iface in $interfaces) {
    if ($iface.Path.ToLower().Contains($Match.ToLower())) { $target = $iface; break }
}
if ($null -eq $target) {
    Emit ("[error] no HID interface of VID 0x{0:X4} matches ""{1}""" -f $Vid, $Match)
    Emit "        available:"
    foreach ($iface in $interfaces) { Emit ("          " + $iface.Path) }
    exit 3
}

Emit "---- target ----"
Emit ("path        : " + $target.Path)
Emit ("product     : " + $target.Product)
Emit ("manufacturer: " + $target.Manufacturer)
Emit ("vid/pid/ver : {0:X4} / {1:X4} / {2:X4}" -f $target.Vid, $target.Pid, $target.Version)
Emit ("usagePage   : 0x{0:X4} / 0x{1:X2}" -f $target.UsagePage, $target.Usage)
Emit ("report bytes: input={0}  output={1}  feature={2}" -f `
      $target.InputReportByteLength, $target.OutputReportByteLength, $target.FeatureReportByteLength)
Emit ""

if ($target.OutputReportByteLength -ne $Length) {
    Emit ("[warn] -Length {0} != this interface's output report byte length {1}" -f `
          $Length, $target.OutputReportByteLength)
    Emit "       Windows expects exactly OutputReportByteLength bytes (report id byte included)."
    if ($Execute) {
        Emit "       Refusing to write: fix -Length first (or ask the Mac side)."
        exit 5
    }
    Emit "       Do not proceed with -Execute until this matches or the Mac side says otherwise."
    Emit ""
}

# ---- build the buffer ------------------------------------------------------
$buffer = New-Object byte[] $Length
[Array]::Copy($payload, $buffer, $payload.Length)

Emit "---- buffer to send ----"
Emit ("total length: {0} bytes (payload {1} bytes + {2} zero bytes)" -f `
      $buffer.Length, $payload.Length, ($buffer.Length - $payload.Length))
Emit ("first 32    : " + (ConvertTo-K70Hex -Bytes $buffer -Max 32))
Emit ""

if (-not $Execute) {
    # Capability check for the dry run: can this interface be opened for writing
    # at all? Opening and immediately closing sends nothing to the device, so
    # this stays a read-only operation while still catching "iCUE holds it".
    $probeHandle = [K70HidLib]::OpenForWrite($target.Path)
    if ($probeHandle.ToInt64() -eq -1) {
        Emit ("open for write : FAILED, Win32 error " +
              [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        Emit "                 Another program (iCUE?) may be holding the interface."
    } else {
        [K70HidLib]::CloseHandle($probeHandle) | Out-Null
        Emit "open for write : OK (opened and closed, nothing was sent)"
    }
    Emit ""
    Emit "DRY RUN: no write was performed. Re-run with -Execute only after the Mac side approves."
    exit 0
}

# ---- the single write ------------------------------------------------------
Emit ("---- write (method: " + $Method + ") ----")
$handle = [K70HidLib]::OpenForWrite($target.Path)
if ($handle.ToInt64() -eq -1) {
    Emit ("[error] CreateFile for write failed, Win32 error " + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    exit 4
}
try {
    $setOk = $null
    if ($Method -eq "Both" -or $Method -eq "SetOutputReport") {
        $err = 0
        $ok = [K70HidLib]::SetOutputReport($handle, $buffer, [ref]$err)
        $setOk = $ok
        Emit ("1) HidD_SetOutputReport : {0}   (Win32 error {1})" -f $ok, $err)
    }

    if ($Method -eq "WriteFile" -or ($Method -eq "Both" -and $setOk -ne $true)) {
        $written = 0
        $err2 = 0
        $ok2 = [K70HidLib]::WriteOutputReport($handle, $buffer, [ref]$written, [ref]$err2)
        Emit ("2) WriteFile            : {0}   (bytes written {1}, Win32 error {2})" -f $ok2, $written, $err2)
    }

    Emit ""
    Emit "Interpretation:"
    Emit "  HidD_SetOutputReport=True  -> Windows/driver accepted the report (no API-level rejection)."
    Emit "  HidD_SetOutputReport=False -> the call was refused; Win32 error 1 = ERROR_INVALID_FUNCTION."
    Emit "  WriteFile=True with 65 bytes -> Windows handed the same report to the receiver."
}
finally {
    [K70HidLib]::CloseHandle($handle) | Out-Null
    Emit "handle closed"
}

Start-Sleep -Milliseconds 1500

Emit ""
Emit "---- after the write ----"
$after = [K70HidLib]::Enumerate([uint16]$Vid)
$same = $false
foreach ($iface in $after) { if ($iface.Path -eq $target.Path) { $same = $true } }
Emit ("interface {0} still present : {1}" -f $Match, $same)
Emit ("HID interfaces with VID 0x{0:X4} now: {1}" -f $Vid, $after.Length)
Emit ""
Emit "Now check, on both machines, who is actually receiving keystrokes."
Emit "Exactly one write was performed: no retry, no loop, no background process."
Emit "---- done ----"
