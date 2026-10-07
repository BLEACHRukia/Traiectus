// kbd-probe.cpp —— 只读枚举 HID 设备里的"厂商接口"
//
// 目的：验证 MinGW 能否链上 setupapi/hid，并看清键盘接收器暴露了哪些可读接口。
// 只读：只打开设备读描述符；不改任何设置、不发任何数据。
//
// 编译（与 build-mingw.bat 同一套 w64devkit）：
//   g++ -std=c++17 -O2 -Wall -o kbd-probe.exe kbd-probe.cpp -lsetupapi -lhid
//
// 用法：
//   kbd-probe.exe                       列出所有 HID 接口
//   kbd-probe.exe --vid 1B1C            只看某个厂商
//   kbd-probe.exe --vid 1B1C --read 0x0002
//        打开 usage=0x0002 那个接口，阻塞等一帧（切一下键盘就能看到）

#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>

static std::string toUtf8(const wchar_t* w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return std::string();
    std::string s(static_cast<size_t>(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

static void dump(const BYTE* data, DWORD n, DWORD maxBytes = 16) {
    for (DWORD i = 0; i < n && i < maxBytes; ++i) ::printf("%02X ", data[i]);
    if (n > maxBytes) ::printf("...");
    ::printf("\n");
}

int main(int argc, char** argv) {
    unsigned vidFilter = 0;
    unsigned usageFilter = 0;
    bool doRead = false;

    for (int i = 1; i < argc; ++i) {
        if (!::strcmp(argv[i], "--vid") && i + 1 < argc) {
            vidFilter = static_cast<unsigned>(::strtoul(argv[++i], nullptr, 16));
        } else if (!::strcmp(argv[i], "--read") && i + 1 < argc) {
            usageFilter = static_cast<unsigned>(::strtoul(argv[++i], nullptr, 0));
            doRead = true;
        }
    }

    GUID hidGuid;
    ::HidD_GetHidGuid(&hidGuid);

    HDEVINFO devInfo = ::SetupDiGetClassDevsW(&hidGuid, nullptr, nullptr,
                                             DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfo == INVALID_HANDLE_VALUE) {
        ::printf("SetupDiGetClassDevs 失败：%lu\n", ::GetLastError());
        return 1;
    }

    SP_DEVICE_INTERFACE_DATA ifData{};
    ifData.cbSize = sizeof(ifData);

    int checked = 0;
    int matched = 0;

    for (DWORD index = 0;
         ::SetupDiEnumDeviceInterfaces(devInfo, nullptr, &hidGuid, index, &ifData);
         ++index) {
        DWORD need = 0;
        ::SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, nullptr, 0, &need, nullptr);
        if (need == 0) continue;

        std::string buffer(need, '\0');
        auto* detail = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA_W>(buffer.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        if (!::SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, detail, need, nullptr, nullptr)) {
            continue;
        }
        ++checked;

        HANDLE h = ::CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                 OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;

        HIDD_ATTRIBUTES attr{};
        attr.Size = sizeof(attr);
        HIDP_CAPS caps{};
        PHIDP_PREPARSED_DATA prep = nullptr;
        const bool okAttr = ::HidD_GetAttributes(h, &attr) != FALSE;
        const bool okCaps = ::HidD_GetPreparsedData(h, &prep) != FALSE
                         && ::HidP_GetCaps(prep, &caps) == HIDP_STATUS_SUCCESS;

        if (okAttr && okCaps && (vidFilter == 0 || attr.VendorID == vidFilter)) {
            ++matched;
            ::printf("VID_%04X PID_%04X  usagePage=0x%04X usage=0x%04X  in=%u out=%u\n",
                     attr.VendorID, attr.ProductID, caps.UsagePage, caps.Usage,
                     caps.InputReportByteLength, caps.OutputReportByteLength);
            if (caps.UsagePage == 0xFF42) {
                ::printf("    ^^ 厂商接口（厂商自定义 usage page）\n");
            }
            ::printf("    %s\n", toUtf8(detail->DevicePath).c_str());

            if (doRead && caps.Usage == usageFilter) {
                ::printf("\n--read：阻塞等待一帧（现在切一下键盘；没帧会一直等，Ctrl+C 退出）--\n");
                BYTE report[256];
                DWORD got = 0;
                if (::ReadFile(h, report, sizeof(report), &got, nullptr)) {
                    ::printf("  收到 %lu 字节：", got);
                    dump(report, got);
                } else {
                    ::printf("  ReadFile 失败：%lu\n", ::GetLastError());
                }
                ::printf("--read 结束--\n");
            }
        }

        if (prep) ::HidD_FreePreparsedData(prep);
        ::CloseHandle(h);
    }

    ::SetupDiDestroyDeviceInfoList(devInfo);
    ::printf("\n共检查 %d 个 HID 接口，命中 %d 个\n", checked, matched);
    return 0;
}
