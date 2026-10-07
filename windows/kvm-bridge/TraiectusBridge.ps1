# ============================================================================
#  KVM bridge (Windows side, READ ONLY on the device)
# ----------------------------------------------------------------------------
#  Measured 2026-09-26 08:48 (see KvmWatch-Result.txt vs the Mac's live log):
#      Windows saw the receiver's status frame  08:48:15.901
#      macOS saw the Bluetooth REMOVE event     08:48:17.172   -> Windows was
#      1.27 s EARLIER. That is what this bridge exploits.
#
#  What it does: listens to the receiver's vendor interfaces (usagePage 0xFF42,
#  here FF42/02), and every time a frame arrives it forwards it to the Mac as a
#  tiny UDP datagram:
#
#        KEY 00 00 01 36 00 02        (hex of the first bytes)
#
#  The Mac side (kvm-link.py, --udp-port) then switches the monitor input
#  immediately instead of waiting for the Bluetooth event.
#
#  READ ONLY: reads input reports, sends UDP packets. It never writes to the
#  keyboard, the receiver or the monitor, and changes no settings.
#
#  Usage (keep the window open while you work):
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\TraiectusBridge.ps1 -MacIp 192.168.1.10
#
#  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
# ============================================================================

[CmdletBinding()]
param(
    # 必填：Mac 的局域网地址（这台机器要往它发状态帧）。不给会直接报错退出。
    [string]$MacIp = "",
    [int]$UdpPort = 45790,
    [int]$Vid = 0x1B1C,
    [int]$UsagePage = 0xFF42,
    [int]$Seconds = 0,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

if (-not $MacIp) {
    Write-Host "需要 -MacIp <Mac 的地址>，例如：-MacIp 192.168.1.10"
    exit 1
}

if (-not ("TraiectusBridge" -as [type])) {
    $src = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TraiectusBridge
{
    static StreamWriter log;
    static UdpClient udp;
    static IPEndPoint dest;

    public static void Init(string path, string macIp, int port)
    {
        if (path != null && path.Length > 0)
        {
            try
            {
                log = new StreamWriter(path, true, new UTF8Encoding(false)) { AutoFlush = true };
            }
            catch (Exception ex)
            {
                // If the log file cannot be written (share not mounted etc.),
                // the bridge must still work - so just continue without it.
                Console.WriteLine("log file unavailable (" + ex.Message + "), continuing without it");
                log = null;
            }
        }
        udp = new UdpClient();
        // Bind right away: the reply listener must be able to Receive() even before
        // the first heartbeat goes out (otherwise: "call the Bind method first").
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
        dest = new IPEndPoint(IPAddress.Parse(macIp), port);
    }

    const int ControlPort = 45791;   // Traiectus-Server's local control channel (UDP)

    // Heartbeat: send a tiny packet to the Mac every 2 s. Two purposes:
    //   1) Windows Firewall creates a state entry for this UDP flow, so the
    //      Mac's REPLY is allowed through (a fresh inbound UDP packet from the
    //      Mac is blocked, but a reply to our own packet is not).
    //   2) The Mac learns our address and can send its control request back here.
    public static void StartHeartbeat(int seconds)
    {
        Thread t = new Thread(delegate()
        {
            Send("HB");                 // send one immediately so the Mac learns our address
            while (true)
            {
                Thread.Sleep(seconds * 1000);
                Send("HB");
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    // Receive the Mac's reply (MODE Mac|Win <token>) and relay it to
    // 127.0.0.1:45791 (loopback, never firewalled).
    public static void StartRelay()
    {
        Thread t = new Thread(delegate()
        {
            IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
            while (true)
            {
                try
                {
                    byte[] data = udp.Receive(ref from);
                    string text = Encoding.ASCII.GetString(data).Trim();
                    if (text.Length == 0) continue;
                    if (text == "HB") continue;
                    Log("Mac -> bridge: " + text);
                    if (text.StartsWith("MODE", StringComparison.OrdinalIgnoreCase))
                    {
                        try
                        {
                            using (UdpClient relay = new UdpClient())
                            {
                                relay.Send(data, data.Length, new IPEndPoint(IPAddress.Loopback, ControlPort));
                                relay.Client.ReceiveTimeout = 800;
                                try
                                {
                                    IPEndPoint serverFrom = new IPEndPoint(IPAddress.Any, 0);
                                    byte[] ack = relay.Receive(ref serverFrom);
                                    Log("server -> " + Encoding.ASCII.GetString(ack).Trim()
                                        + "  (relayed, control port " + ControlPort + ")");
                                }
                                catch (Exception exAck)
                                {
                                    // Important on Windows: if nothing listens on the target port,
                                    // the local stack returns ICMP port-unreachable and the next
                                    // Receive throws ConnectionReset -> the server has no control
                                    // channel (usually an old build / old exe).
                                    Log("NO ACK from 127.0.0.1:" + ControlPort + " -> "
                                        + exAck.GetType().Name + ": " + exAck.Message);
                                    Log("   hint: ConnectionReset / TimedOut usually means"
                                        + " Traiectus-Server is not the new build (or is not running)");
                                }
                            }
                        }
                        catch (Exception ex2)
                        {
                            Log("relay failed: " + ex2.Message);
                        }
                    }
                }
                catch (Exception ex)
                {
                    Log("reply listener: " + ex.Message);
                    Thread.Sleep(500);
                }
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    public static void Log(string line)
    {
        string stamped = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + line;
        Console.WriteLine(stamped);
        Console.Out.Flush();
        if (log != null) log.WriteLine(stamped);
    }

    static void Send(string text)
    {
        try
        {
            byte[] data = Encoding.ASCII.GetBytes(text);
            udp.Send(data, data.Length, dest);
        }
        catch (Exception ex)
        {
            Log("UDP send failed: " + ex.Message);
        }
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
            Log(it.Label + " listening (blocking read)");
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

                int n = Math.Min(got, 8);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < n; i++) { if (i > 0) sb.Append(' '); sb.Append(buf[i].ToString("X2")); }
                string hex = sb.ToString();
                Log(it.Label + " frame: " + hex + "  -> UDP " + dest.Address + ":" + dest.Port);
                Send("KEY " + hex);
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

[TraiectusBridge]::Init($OutFile, $MacIp, $UdpPort)

[TraiectusBridge]::Log("==== KVM bridge (Windows side) ====")
[TraiectusBridge]::Log("forwarding receiver frames to Mac $MacIp`:$UdpPort")

$ifaces = [TraiectusBridge]::Find([uint16]$Vid, [uint16]$UsagePage)
[TraiectusBridge]::Log("vendor interfaces found: $($ifaces.Count)")
foreach ($i in $ifaces) { [TraiectusBridge]::Log("  $($i.Label)  input=$($i.InputLength)") }
foreach ($i in $ifaces) { [TraiectusBridge]::StartReader($i) }

[TraiectusBridge]::Log("")
[TraiectusBridge]::Log("Keep this window open. Close it to stop the bridge.")
[TraiectusBridge]::StartHeartbeat(2)
[TraiectusBridge]::StartRelay()
[TraiectusBridge]::Log("heartbeat every 2 s (keeps the return path open) + relay to 127.0.0.1:45791 ready")

if ($Seconds -le 0) {
    while ($true) { Start-Sleep -Seconds 3600 }
} else {
    Start-Sleep -Seconds $Seconds
}
