# ============================================================================
#  Traiectus - read-only diagnostic helper
# ----------------------------------------------------------------------------
#  Lists every Raw Input device that Windows currently reports, together with
#  the exact device path that
#      Traiectus-RawInputTest.exe --device "<text>"
#  matches against.
#
#  This script is strictly read-only: it calls GetRawInputDeviceList and
#  GetRawInputDeviceInfo and nothing else. It installs nothing, changes
#  nothing, and can be closed at any time.
#
#  Usage:
#      powershell -ExecutionPolicy Bypass -File .\list-rawinput-devices.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'

$typeDefinition = @'
using System;
using System.Runtime.InteropServices;

public static class RawInputDiag
{
    public const uint RIDI_DEVICENAME = 0x20000007;
    public const uint RIDI_DEVICEINFO = 0x2000000B;

    public const uint RIM_TYPEMOUSE    = 0;
    public const uint RIM_TYPEKEYBOARD = 1;
    public const uint RIM_TYPEHID      = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct RAWINPUTDEVICELIST
    {
        public IntPtr hDevice;
        public uint   dwType;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RID_DEVICE_INFO_MOUSE
    {
        public uint dwId;
        public uint dwNumberOfButtons;
        public uint dwSampleRate;
        public int  fHasHorizontalWheel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RID_DEVICE_INFO_KEYBOARD
    {
        public uint dwType;
        public uint dwSubType;
        public uint dwKeyboardMode;
        public uint dwNumberOfFunctionKeys;
        public uint dwNumberOfIndicators;
        public uint dwNumberOfKeysTotal;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RID_DEVICE_INFO_HID
    {
        public uint   dwVendorId;
        public uint   dwProductId;
        public uint   dwVersionNumber;
        public ushort usUsagePage;
        public ushort usUsage;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct RID_DEVICE_INFO_UNION
    {
        [FieldOffset(0)] public RID_DEVICE_INFO_MOUSE    mouse;
        [FieldOffset(0)] public RID_DEVICE_INFO_KEYBOARD keyboard;
        [FieldOffset(0)] public RID_DEVICE_INFO_HID      hid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RID_DEVICE_INFO
    {
        public uint cbSize;
        public uint dwType;
        public RID_DEVICE_INFO_UNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetRawInputDeviceList(
        [In, Out] RAWINPUTDEVICELIST[] pRawInputDeviceList,
        ref uint puiNumDevices,
        uint cbSize);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetRawInputDeviceInfoW(
        IntPtr hDevice, uint uiCommand, IntPtr pData, ref uint pcbSize);
}
'@

Add-Type -TypeDefinition $typeDefinition -Language CSharp

function Get-RawDeviceName {
    param([IntPtr]$hDevice)

    $chars = [uint32]0
    [void][RawInputDiag]::GetRawInputDeviceInfoW(
        $hDevice, [RawInputDiag]::RIDI_DEVICENAME, [IntPtr]::Zero, [ref]$chars)
    if ($chars -eq 0) { return '' }

    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]($chars * 2))
    try {
        $size = $chars
        $written = [RawInputDiag]::GetRawInputDeviceInfoW(
            $hDevice, [RawInputDiag]::RIDI_DEVICENAME, $buffer, [ref]$size)
        if ($written -eq [uint32]::MaxValue) { return '' }
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buffer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

function Get-RawDeviceInfo {
    param([IntPtr]$hDevice)

    # Marshal.SizeOf(Object) is used on purpose: SizeOf(Type) cannot be
    # disambiguated reliably from PowerShell.
    $info = New-Object RawInputDiag+RID_DEVICE_INFO
    $size = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($info)
    $info.cbSize = $size

    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$size)
    try {
        [System.Runtime.InteropServices.Marshal]::StructureToPtr($info, $buffer, $false)
        $sizeRef = $size
        $written = [RawInputDiag]::GetRawInputDeviceInfoW(
            $hDevice, [RawInputDiag]::RIDI_DEVICEINFO, $buffer, [ref]$sizeRef)
        if ($written -eq [uint32]::MaxValue) { return $null }
        return [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $buffer, [type][RawInputDiag+RID_DEVICE_INFO])
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

$listProbe = New-Object RawInputDiag+RAWINPUTDEVICELIST
$listStructSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($listProbe)

$count = [uint32]0
[void][RawInputDiag]::GetRawInputDeviceList($null, [ref]$count, $listStructSize)

if ($count -eq 0) {
    Write-Host 'Windows reported no Raw Input devices.'
    return
}

$deviceList = New-Object 'RawInputDiag+RAWINPUTDEVICELIST[]' $count
$returned = [RawInputDiag]::GetRawInputDeviceList($deviceList, [ref]$count, $listStructSize)

if ($returned -eq [uint32]::MaxValue) {
    Write-Host ('GetRawInputDeviceList failed, Win32 error {0}' -f `
                [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
    return
}

Write-Host ''
Write-Host ('Raw Input devices reported by Windows: {0}' -f $returned)
Write-Host ''

$typeNames = @{ 0 = 'Mouse   '; 1 = 'Keyboard'; 2 = 'HID     ' }
$mousePaths = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $returned; $i++) {
    $entry = $deviceList[$i]
    $typeName = 'Unknown '
    if ($typeNames.ContainsKey([int]$entry.dwType)) { $typeName = $typeNames[[int]$entry.dwType] }

    $path = Get-RawDeviceName -hDevice $entry.hDevice
    $info = Get-RawDeviceInfo -hDevice $entry.hDevice

    Write-Host ('[{0,2}] {1}  {2}' -f $i, $typeName, $path)

    if ($null -ne $info) {
        if ($info.dwType -eq 0) {
            Write-Host ('       mouse : id={0} buttons={1} reportedSampleRate={2} Hz horizontalWheel={3}' -f `
                        $info.u.mouse.dwId, $info.u.mouse.dwNumberOfButtons, `
                        $info.u.mouse.dwSampleRate, `
                        ($(if ($info.u.mouse.fHasHorizontalWheel -ne 0) { 'yes' } else { 'no' })))
        }
        elseif ($info.dwType -eq 2) {
            Write-Host ('       hid   : VID={0:X4} PID={1:X4} version={2} usagePage=0x{3:X2} usage=0x{4:X2}' -f `
                        $info.u.hid.dwVendorId, $info.u.hid.dwProductId, `
                        $info.u.hid.dwVersionNumber, `
                        $info.u.hid.usUsagePage, $info.u.hid.usUsage)
        }
    }

    if ([int]$entry.dwType -eq 0) {
        $mousePaths.Add($path)
    }
}

Write-Host ''
Write-Host '--------------------------------------------------------------------------------'
Write-Host 'Mouse-class devices (these are the ones Traiectus can read mouse events from):'
foreach ($p in $mousePaths) {
    Write-Host ('   {0}' -f $p)
}

Write-Host ''
Write-Host 'To watch only one of them (note the quotes - "&" is special in cmd.exe):'
Write-Host '   Traiectus-RawInputTest.exe --device "VID_046D&PID_C547"'
Write-Host ''
Write-Host 'Tip: a short filter also works, e.g. --device "PID_C547" or --device "046D".'
Write-Host ''
