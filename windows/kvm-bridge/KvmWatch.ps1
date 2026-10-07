# ============================================================================
#  Receiver status watch (Windows side, READ ONLY)
#  Traiectus / "keyboard arrival" early-detection sub-project
# ----------------------------------------------------------------------------
#  Goal: find out whether Windows notices the keyboard arriving at / leaving
#  the 2.4G receiver, and how fast - compared with the macOS Bluetooth events.
#  The Mac side already reacts in about 50 ms; everything else is Bluetooth
#  stack latency, so an early signal from Windows is the only way to go faster.
#
#  What it does: subscribes to the receiver's vendor interfaces (usagePage
#  0xFF42) and prints every input report it receives, with a millisecond
#  timestamp in hex.
#
#  READ ONLY: only ReadFile on input reports. No writes, no settings changed.
#
#  Usage:
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\KvmWatch.ps1 -Seconds 90
#
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    [int]$Seconds = 90,
    [int]$Vid = 0x1B1C,
    [int]$UsagePage = 0xFF42,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

if (-not ("KvmWatch" -as [type])) {
    $src = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class KvmWatch
{
    static StreamWriter log;

    public static void Init(string path)
    {
        if (path != null && path.Length > 0)
            log = new StreamWriter(path, true, new UTF8Encoding(false)) { AutoFlush = true };
    }

    public static void Log(string line)
    {
        string stamped = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + line;
        Console.WriteLine(stamped);
        Console.Out.Flush();
        if (log != null) log.WriteLine(stamped);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr p, int f);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr h, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr h, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, ref int required, IntPtr devInfo);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buffer, int toRead, out int read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("hid.dll")]
    static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")]
    static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pre);
    [DllImport("hid.dll")]
    static extern bool HidD_FreePreparsedData(IntPtr pre);
    [DllImport("hid.dll")]
    static extern int HidP_GetCaps(IntPtr pre, ref HIDP_CAPS caps);

    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const int DIGCF_PRESENT = 0x02;
    const int DIGCF_DEVICEINTERFACE = 0x10;
    const int HIDP_STATUS_SUCCESS = 0x00110000;
    static readonly IntPtr INVALID = new IntPtr(-1);

    public class Iface
    {
        public string Path = "";
        public ushort Usage;
        public int InputLength;
        public string Label = "";
    }

    public static List<Iface> Find(ushort vid, ushort usagePage)
    {
        List<Iface> list = new List<Iface>();
        Guid hidGuid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        IntPtr h = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (h == INVALID) return list;
        try
        {
            int idx = 0;
            while (true)
            {
                SP_DEVICE_INTERFACE_DATA did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(h, IntPtr.Zero, ref hidGuid, idx, ref did)) break;
                idx++;
                int need = 0;
                SetupDiGetDeviceInterfaceDetail(h, ref did, IntPtr.Zero, 0, ref need, IntPtr.Zero);
                if (need <= 0) continue;
                IntPtr detail = Marshal.AllocHGlobal(need);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(h, ref did, detail, need, ref need, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));
                    if (string.IsNullOrEmpty(path)) continue;

                    IntPtr dev = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (dev == INVALID) continue;
                    try
                    {
                        HIDD_ATTRIBUTES at = new HIDD_ATTRIBUTES();
                        at.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                        if (!HidD_GetAttributes(dev, ref at) || at.VendorID != vid) continue;
                        IntPtr pre;
                        if (!HidD_GetPreparsedData(dev, out pre) || pre == IntPtr.Zero) continue;
                        try
                        {
                            HIDP_CAPS caps = new HIDP_CAPS();
                            if (HidP_GetCaps(pre, ref caps) != HIDP_STATUS_SUCCESS) continue;
                            if (caps.UsagePage != usagePage) continue;
                            Iface it = new Iface();
                            it.Path = path;
                            it.Usage = caps.Usage;
                            it.InputLength = caps.InputReportByteLength;
                            it.Label = "FF42/" + caps.Usage.ToString("X2");
                            list.Add(it);
                        }
                        finally { HidD_FreePreparsedData(pre); }
                    }
                    finally { CloseHandle(dev); }
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(h); }
        return list;
    }

    public static void StartReader(Iface it)
    {
        Thread t = new Thread(delegate()
        {
            IntPtr dev = CreateFile(it.Path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (dev == INVALID)
            {
                Log(it.Label + " open failed err=" + Marshal.GetLastWin32Error());
                return;
            }
            Log(it.Label + " listening for input reports (blocking read)");
            byte[] buf = new byte[Math.Max(it.InputLength, 64)];
            int fails = 0;
            while (true)
            {
                int got = 0;
                bool ok = ReadFile(dev, buf, buf.Length, out got, IntPtr.Zero);
                if (!ok)
                {
                    int err = Marshal.GetLastWin32Error();
                    Log(it.Label + " ReadFile failed err=" + err);
                    if (++fails >= 3) break;
                    Thread.Sleep(300);
                    continue;
                }
                fails = 0;
                if (got <= 0) continue;
                StringBuilder sb = new StringBuilder();
                int n = Math.Min(got, 24);
                for (int i = 0; i < n; i++) sb.Append(buf[i].ToString("X2")).Append(' ');
                Log(it.Label + " got " + got + " bytes: " + sb.ToString().Trim() + (got > n ? " ..." : ""));
            }
            CloseHandle(dev);
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@
    Add-Type -TypeDefinition $src -Language CSharp | Out-Null
}

[KvmWatch]::Init($OutFile)

[KvmWatch]::Log("==== receiver status watch (READ ONLY) ====")
[KvmWatch]::Log("host=$env:COMPUTERNAME  will run for $Seconds seconds")

$ifaces = [KvmWatch]::Find([uint16]$Vid, [uint16]$UsagePage)
[KvmWatch]::Log("vendor interfaces found: $($ifaces.Count)")
foreach ($i in $ifaces) {
    [KvmWatch]::Log("  $($i.Label)  input=$($i.InputLength)")
}
[KvmWatch]::Log("")

foreach ($i in $ifaces) { [KvmWatch]::StartReader($i) }

[KvmWatch]::Log("")
[KvmWatch]::Log("Now: Fn+Caps (keyboard to Windows), wait 10s, Fn+T (back to Mac), repeat once.")
[KvmWatch]::Log("")

$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
}

[KvmWatch]::Log("")
[KvmWatch]::Log("==== done ($Seconds s) ====")
