# ============================================================================
#  Monitor input-source control (DDC/CI, VCP code 0x60)
#  MiniKVM / display-switch sub-project
# ----------------------------------------------------------------------------
#  Why this exists: the monitor can be switched FROM the Mac (verified: the Mac
#  runs the ASUS "dwc" CLI, 15 = DP-1 = Windows, 17 = HDMI-1 = Mac), but NOT
#  back to the Mac: as soon as the monitor shows the Windows input, macOS no
#  longer sees the display at all and loses its DDC/CI channel. The machine
#  that currently owns the screen is the only one that can hand it over, so
#  "back to the Mac" has to be done from Windows.
#
#  This is a plain PowerShell + P/Invoke script (dxva2.dll), no compiler needed.
#
#  Usage:
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\MonInput.ps1 -Action get
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\MonInput.ps1 -Action set -Value 17
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\MonInput.ps1 -Action set -Value 15
#
#      -Value 17 = HDMI-1 (the Mac)
#      -Value 15 = DP-1   (this Windows PC)
#
#  It only touches VCP code 0x60 (input source). No other monitor setting, no
#  system setting, no driver, no registry.
#
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    [ValidateSet("get", "set", "list")]
    [string]$Action = "get",
    [int]$Value = -1,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

if (-not ("MonCtl" -as [type])) {
    $typeDefinition = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class MonCtl
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint arraySize,
        [Out] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool DestroyPhysicalMonitors(uint arraySize, [In] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr hPhysicalMonitor, byte code, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hPhysicalMonitor, byte code,
        out uint type, out uint current, out uint maximum);

    public static IntPtr[] Monitors()
    {
        List<IntPtr> found = new List<IntPtr>();
        MonitorEnumProc cb = delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d)
        {
            found.Add(h);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return found.ToArray();
    }

    public class Physical
    {
        public string Description = "";
        public IntPtr Handle;
        public bool Get(byte code, out uint current, out uint maximum, out int error)
        {
            uint type = 0, cur = 0, max = 0;
            bool ok = GetVCPFeatureAndVCPFeatureReply(Handle, code, out type, out cur, out max);
            error = Marshal.GetLastWin32Error();
            current = cur; maximum = max;
            return ok;
        }
        public bool Set(byte code, uint value, out int error)
        {
            bool ok = SetVCPFeature(Handle, code, value);
            error = Marshal.GetLastWin32Error();
            return ok;
        }
    }

    // IMPORTANT: the PHYSICAL_MONITOR handles stay valid only until
    // DestroyPhysicalMonitors() is called for that array. An earlier version of
    // this script destroyed them right after enumerating, then used the stale
    // handles for Get/SetVCPFeature - which fails with 0xC026258C
    // ("monitor no longer exists"). So the arrays are held here and released
    // only when the caller is done.
    static readonly List<PHYSICAL_MONITOR[]> Held = new List<PHYSICAL_MONITOR[]>();

    public static Physical[] PhysicalMonitors()
    {
        List<Physical> result = new List<Physical>();
        foreach (IntPtr hm in Monitors())
        {
            uint count = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out count) || count == 0) continue;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, count, arr)) continue;
            Held.Add(arr);
            foreach (PHYSICAL_MONITOR pm in arr)
            {
                Physical p = new Physical();
                p.Handle = pm.hPhysicalMonitor;
                p.Description = pm.szPhysicalMonitorDescription;
                result.Add(p);
            }
        }
        return result.ToArray();
    }

    public static void ReleaseAll()
    {
        foreach (PHYSICAL_MONITOR[] arr in Held)
        {
            DestroyPhysicalMonitors((uint)arr.Length, arr);
        }
        Held.Clear();
    }
}
'@
    Add-Type -TypeDefinition $typeDefinition -Language CSharp | Out-Null
}

$lines = New-Object System.Collections.Generic.List[string]
function Emit {
    param([string]$Text = "")
    Write-Host $Text
    $lines.Add($Text) | Out-Null
}

function Get-SourceName {
    param([int]$V)
    switch ($V) {
        1  { return "VGA / analog" }
        3  { return "DVI" }
        15 { return "DP-1   (this Windows PC)" }
        16 { return "DP-2" }
        17 { return "HDMI-1 (the Mac)" }
        18 { return "HDMI-2" }
        default { return "(unknown)" }
    }
}

$monitors = [MonCtl]::PhysicalMonitors()

Emit "==== Monitor input source (VCP 0x60) ===="
Emit ("host      : " + $env:COMPUTERNAME + "   time: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Emit ("monitors  : " + $monitors.Length + " physical monitor(s) visible to this PC")
Emit ""

if ($monitors.Length -eq 0) {
    Emit "No physical monitor is visible from this PC."
    Emit "That is normal when the monitor is currently showing the OTHER computer's"
    Emit "input: this PC has lost its DDC/CI channel."
    Emit ""
    Emit "---- done ----"
    if ($OutFile) { $lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8 }
    exit 0
}

$index = 0
foreach ($m in $monitors) {
    $index++
    Emit ("[" + $index + "] " + $m.Description)
    $current = 0; $maximum = 0; $err = 0
    if ($m.Get(0x60, [ref]$current, [ref]$maximum, [ref]$err)) {
        Emit ("     current input : " + $current + "  = " + (Get-SourceName -V $current))
        Emit ("     max value     : " + $maximum)
    } else {
        Emit ("     current input : <read failed, Win32 error " + $err + ">")
        Emit "     (some monitors do not answer DDC/CI on the inactive input)"
    }
    Emit ""
}

if ($Action -eq "set") {
    if ($Value -lt 0) {
        Emit "[error] -Action set needs -Value (15 = DP-1 Windows, 17 = HDMI-1 Mac)"
        if ($OutFile) { $lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8 }
        exit 2
    }
    Emit ("---- set input source to " + $Value + " = " + (Get-SourceName -V $Value) + " ----")
    foreach ($m in $monitors) {
        $err = 0
        $ok = $m.Set(0x60, [uint32]$Value, [ref]$err)
        Emit ("  " + $m.Description + " -> " + $ok + " (Win32 error " + $err + ")")
    }
    Emit ""
    Emit "If it returned True, the monitor should switch within about a second."
    Emit "If it returned False, this PC does not currently own the screen."
    Emit ""
}

Emit "---- done ----"

try { [MonCtl]::ReleaseAll() } catch { }

if ($OutFile) { $lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8 }
