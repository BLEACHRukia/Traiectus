# ============================================================================
#  DDC/CI diagnostic  (READ ONLY - it never writes any VCP code)
#  MiniKVM / display-switch sub-project
# ----------------------------------------------------------------------------
#  Why: MonInput.ps1 could enumerate one physical monitor on the Windows PC but
#  both the read and the write of VCP 0x60 failed with 0xC026258C, so the
#  machine that must hand the screen back to the Mac cannot talk to it.
#  The Mac can (its DDC goes over HDMI via IOFramebufferI2CInterface/Arm64DDC).
#  This script collects everything needed to find out which link is broken:
#
#    1) display adapters + driver versions
#    2) monitors Windows knows (EDID present or not)
#    3) per physical monitor: try to READ several VCP codes and print the error
#       (brightness 0x10 / contrast 0x12 / input 0x60 / power 0xDF)
#    4) any ASUS USB/HID device (some monitors are controllable over USB)
#    5) what Windows thinks the display topology is
#
#  Nothing here writes to the monitor or changes any setting.
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param([string]$OutFile = "")

$ErrorActionPreference = "Continue"

$lines = New-Object System.Collections.Generic.List[string]
function Emit {
    param([string]$Text = "")
    Write-Host $Text
    $lines.Add($Text) | Out-Null
}

function Hex32 {
    param([int]$Value)
    return ("0x" + ([uint32]$Value).ToString("X8"))
}

if (-not ("MonDiag" -as [type])) {
    $typeDefinition = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class MonDiag
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
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte code,
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

    public class Physical { public string Description = ""; public IntPtr Handle; }

    // Same lifetime rule as MonInput.ps1: the handles are invalidated by
    // DestroyPhysicalMonitors(), so keep the arrays until the very end.
    static readonly List<PHYSICAL_MONITOR[]> Held = new List<PHYSICAL_MONITOR[]>();

    public static Physical[] PhysicalMonitors(out string error)
    {
        error = "";
        List<Physical> result = new List<Physical>();
        foreach (IntPtr hm in Monitors())
        {
            uint count = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out count))
            {
                error += "GetNumberOfPhysicalMonitors failed err=" + Marshal.GetLastWin32Error() + "; ";
                continue;
            }
            if (count == 0) continue;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, count, arr))
            {
                error += "GetPhysicalMonitors failed err=" + Marshal.GetLastWin32Error() + "; ";
                continue;
            }
            foreach (PHYSICAL_MONITOR pm in arr)
            {
                Physical p = new Physical();
                p.Handle = pm.hPhysicalMonitor;
                p.Description = pm.szPhysicalMonitorDescription;
                result.Add(p);
            }
            Held.Add(arr);
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

    public static string ReadVcp(IntPtr handle, byte code, out int error)
    {
        uint type = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(handle, code, out type, out cur, out max);
        error = Marshal.GetLastWin32Error();
        if (!ok) return null;
        return "value=" + cur + " max=" + max + " type=" + type;
    }
}
'@
    Add-Type -TypeDefinition $typeDefinition -Language CSharp | Out-Null
}

Emit "==== DDC/CI diagnostic (read only) ===="
Emit ("host : " + $env:COMPUTERNAME + "   time: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Emit ""

Emit "---- 1) display adapters ----"
try {
    Get-CimInstance Win32_VideoController |
        Select-Object Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate |
        Format-Table -AutoSize | Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() -split "`r?`n" } | ForEach-Object { Emit $_ }
} catch { Emit ("  <failed: " + $_.Exception.Message + ">") }
Emit ""

Emit "---- 2) monitors Windows knows (EDID/WMI) ----"
try {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
        $name = (($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join "")
        $mfg  = (($_.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join "")
        $sn   = (($_.SerialNumberID  | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join "")
        Emit ("  " + $mfg + " / " + $name + " / serial=" + $sn + "  active=" + $_.Active)
    }
} catch { Emit ("  <WmiMonitorID failed: " + $_.Exception.Message + ">") }
Emit ""

Emit "---- 3) per physical monitor: try to READ several VCP codes ----"
$enumerateError = ""
$monitors = [MonDiag]::PhysicalMonitors([ref]$enumerateError)
if ($enumerateError) { Emit ("  enumerate note: " + $enumerateError) }
Emit ("  physical monitors: " + $monitors.Length)
$codes = @(
    @{ Code = 0x10; Name = "brightness" },
    @{ Code = 0x12; Name = "contrast" },
    @{ Code = 0x60; Name = "input source" },
    @{ Code = 0xDF; Name = "power mode" }
)
$i = 0
foreach ($m in $monitors) {
    $i++
    Emit ("  [" + $i + "] " + $m.Description)
    foreach ($c in $codes) {
        $err = 0
        $res = [MonDiag]::ReadVcp($m.Handle, [byte]$c.Code, [ref]$err)
        if ($null -eq $res) {
            Emit ("      0x{0:X2} {1,-13} -> FAILED  Win32 error {2}" -f $c.Code, $c.Name, (Hex32 $err))
        } else {
            Emit ("      0x{0:X2} {1,-13} -> {2}" -f $c.Code, $c.Name, $res)
        }
    }
}
Emit ""

Emit "---- 4) ASUS USB / HID devices (some monitors are controllable over USB) ----"
try {
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*VID_0B05*" } |
        Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap |
        Out-String -Width 220 | ForEach-Object { $_.TrimEnd() -split "`r?`n" } | ForEach-Object { Emit $_ }
} catch { Emit ("  <failed: " + $_.Exception.Message + ">") }
Emit ""

Emit "---- 5) display topology seen by Windows ----"
try {
    Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop |
        Select-Object Name, DeviceID, ScreenWidth, ScreenHeight, Availability |
        Format-Table -AutoSize | Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() -split "`r?`n" } | ForEach-Object { Emit $_ }
} catch { Emit ("  <Win32_DesktopMonitor failed: " + $_.Exception.Message + ">") }
Emit ""

Emit "---- done ----"

try { [MonDiag]::ReleaseAll() } catch { }

if ($OutFile) { $lines -join "`r`n" | Set-Content -Path $OutFile -Encoding UTF8 }
