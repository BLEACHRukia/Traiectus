# ============================================================================
#  K70 HID helper library  (MiniKVM / keyboard-switch sub-project)
# ----------------------------------------------------------------------------
#  What it provides
#    K70HidLib.Enumerate(vid)   -> list HID interfaces of one vendor, with
#                                  vid/pid/version, product/manufacturer/serial
#                                  strings, usagePage/usage, report lengths
#                                  (HidP_GetCaps) and the raw report descriptor
#    K70HidLib.OpenPath(path)   -> open a HID interface (read+write, then read)
#    K70HidLib.HidD_SetOutputReport(...)  -> the single write primitive used by
#                                            K70-Send.ps1 (never called here)
#
#  This file only DECLARES things. Nothing in it is executed on dot-source
#  except Add-Type, which just compiles the P/Invoke wrapper in memory.
#
#  ASCII-only on purpose: Windows PowerShell 5.1 treats a .ps1 without a BOM
#  as ANSI (local OEM code page), which would mangle non-ASCII text.
# ============================================================================

if (-not ("K70HidLib" -as [type])) {

    $k70HidTypeDefinition = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class K70HidLib
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
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

    public class HidInterface
    {
        public string Path = "";
        public string OpenError;
        public string Product = "";
        public string Manufacturer = "";
        public string Serial = "";
        public ushort Vid;
        public ushort Pid;
        public ushort Version;
        public ushort UsagePage;
        public ushort Usage;
        public int InputReportByteLength;
        public int OutputReportByteLength;
        public int FeatureReportByteLength;
        public byte[] Descriptor;
        public string DescriptorError;
    }

    const int DIGCF_PRESENT = 0x02;
    const int DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x1;
    const uint FILE_SHARE_WRITE = 0x2;
    const uint OPEN_EXISTING = 3;
    const uint IOCTL_HID_GET_REPORT_DESCRIPTOR = 0x000B0192;
    const int HIDP_STATUS_SUCCESS = 0x00110000;
    static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, int Flags);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr hDevInfo, IntPtr devInfo, ref Guid interfaceClassGuid,
        int memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr hDevInfo, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData,
        IntPtr deviceInterfaceDetailData, int deviceInterfaceDetailDataSize, ref int requiredSize, IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr hDevInfo);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, int nInBufferSize,
        byte[] lpOutBuffer, int nOutBufferSize, ref int lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("hid.dll")]
    static extern bool HidD_GetAttributes(IntPtr HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);

    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetProductString(IntPtr HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetManufacturerString(IntPtr HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetSerialNumberString(IntPtr HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll")]
    static extern bool HidD_GetPreparsedData(IntPtr HidDeviceObject, out IntPtr PreparsedData);

    [DllImport("hid.dll")]
    static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);

    [DllImport("hid.dll")]
    static extern int HidP_GetCaps(IntPtr PreparsedData, ref HIDP_CAPS Capabilities);

    // NOTE: HidD_* return a 1-byte BOOLEAN. Marshalling it as a default
    // 4-byte bool reads garbage in the upper bytes, which is why the first run
    // reported "False" and the second "True" for the same call. U1 forces a
    // single-byte read, so the value below can be trusted.
    [DllImport("hid.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool HidD_SetOutputReport(IntPtr HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, int nNumberOfBytesToWrite,
        out int lpNumberOfBytesWritten, IntPtr lpOverlapped);

    // Two ways to push an output report into a HID interface.
    //  - hidapi on Windows uses WriteFile()  (that is the reference implementation
    //    OpenLinkHub-style code relies on)
    //  - HidD_SetOutputReport() is the other documented API; some drivers accept
    //    one and refuse the other, so both are offered with the real error code.
    public static bool SetOutputReport(IntPtr handle, byte[] buffer, out int error)
    {
        bool ok = HidD_SetOutputReport(handle, buffer, buffer.Length);
        error = Marshal.GetLastWin32Error();
        return ok;
    }

    public static bool WriteOutputReport(IntPtr handle, byte[] buffer, out int bytesWritten, out int error)
    {
        int written = 0;
        bool ok = WriteFile(handle, buffer, buffer.Length, out written, IntPtr.Zero);
        bytesWritten = written;
        error = Marshal.GetLastWin32Error();
        return ok;
    }

    static string WideToString(byte[] bytes)
    {
        string s = Encoding.Unicode.GetString(bytes);
        int nul = s.IndexOf('\0');
        if (nul >= 0) s = s.Substring(0, nul);
        return s.Trim();
    }

    public static IntPtr OpenPath(string path)
    {
        IntPtr h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == INVALID_HANDLE)
            h = CreateFile(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        return h;
    }

    public static IntPtr OpenForWrite(string path)
    {
        return CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }

    public static HidInterface Probe(string path)
    {
        HidInterface info = new HidInterface();
        info.Path = path;
        IntPtr handle = OpenPath(path);
        if (handle == INVALID_HANDLE)
        {
            info.OpenError = "CreateFile failed, Win32 error " + Marshal.GetLastWin32Error();
            return info;
        }
        try
        {
            HIDD_ATTRIBUTES attrs = new HIDD_ATTRIBUTES();
            attrs.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
            if (HidD_GetAttributes(handle, ref attrs))
            {
                info.Vid = attrs.VendorID;
                info.Pid = attrs.ProductID;
                info.Version = attrs.VersionNumber;
            }

            byte[] buf = new byte[512];
            if (HidD_GetProductString(handle, buf, buf.Length)) info.Product = WideToString(buf);
            buf = new byte[512];
            if (HidD_GetManufacturerString(handle, buf, buf.Length)) info.Manufacturer = WideToString(buf);
            buf = new byte[512];
            if (HidD_GetSerialNumberString(handle, buf, buf.Length)) info.Serial = WideToString(buf);

            IntPtr preparsed;
            if (HidD_GetPreparsedData(handle, out preparsed) && preparsed != IntPtr.Zero)
            {
                try
                {
                    HIDP_CAPS caps = new HIDP_CAPS();
                    if (HidP_GetCaps(preparsed, ref caps) == HIDP_STATUS_SUCCESS)
                    {
                        info.UsagePage = caps.UsagePage;
                        info.Usage = caps.Usage;
                        info.InputReportByteLength = caps.InputReportByteLength;
                        info.OutputReportByteLength = caps.OutputReportByteLength;
                        info.FeatureReportByteLength = caps.FeatureReportByteLength;
                    }
                }
                finally { HidD_FreePreparsedData(preparsed); }
            }

            byte[] desc = new byte[4096];
            int got = 0;
            if (DeviceIoControl(handle, IOCTL_HID_GET_REPORT_DESCRIPTOR, IntPtr.Zero, 0, desc, desc.Length, ref got, IntPtr.Zero))
            {
                byte[] real = new byte[got];
                Array.Copy(desc, real, got);
                info.Descriptor = real;
            }
            else
            {
                info.DescriptorError = "IOCTL_HID_GET_REPORT_DESCRIPTOR failed, Win32 error " + Marshal.GetLastWin32Error();
            }
        }
        catch (Exception ex)
        {
            info.OpenError = ex.Message;
        }
        finally { CloseHandle(handle); }
        return info;
    }

    public static HidInterface[] Enumerate(ushort wantedVid)
    {
        List<HidInterface> found = new List<HidInterface>();
        Guid hidGuid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        IntPtr h = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (h == INVALID_HANDLE) return found.ToArray();
        try
        {
            int index = 0;
            while (true)
            {
                SP_DEVICE_INTERFACE_DATA did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(h, IntPtr.Zero, ref hidGuid, index, ref did)) break;
                index++;

                int required = 0;
                SetupDiGetDeviceInterfaceDetail(h, ref did, IntPtr.Zero, 0, ref required, IntPtr.Zero);
                if (required <= 0) continue;

                IntPtr detail = Marshal.AllocHGlobal(required);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(h, ref did, detail, required, ref required, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));
                    if (string.IsNullOrEmpty(path)) continue;

                    HidInterface info = Probe(path);
                    if (info == null) continue;
                    if (wantedVid != 0 && info.Vid != wantedVid) continue;
                    found.Add(info);
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(h); }
        return found.ToArray();
    }
}
'@

    Add-Type -TypeDefinition $k70HidTypeDefinition -Language CSharp | Out-Null
}

function ConvertTo-K70Hex {
    param([byte[]]$Bytes, [int]$Max = 0)
    if ($null -eq $Bytes) { return "" }
    $n = $Bytes.Length
    if ($Max -gt 0 -and $n -gt $Max) { $n = $Max }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) { $parts.Add($Bytes[$i].ToString("X2")) }
    $text = ($parts -join " ")
    if ($Max -gt 0 -and $Bytes.Length -gt $Max) { $text = $text + " ... (" + $Bytes.Length + " bytes total)" }
    return $text
}
