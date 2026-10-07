// ============================================================================
//  K70HIDTest —— 设备访问层实现（阶段⑦）
//  只做枚举/打开/关闭/读 descriptor/单次写；无循环、无重试、无后台。
// ============================================================================

#include "HidTransport.h"

#include <hidapi.h>

#if defined(__APPLE__)
#include <hidapi_darwin.h>
#endif

namespace k70 {

namespace {

std::string wideToUtf8(const wchar_t* w) {
    if (w == nullptr) return std::string();
    std::string out;
    for (const wchar_t* p = w; *p != 0; ++p) {
        const unsigned int c = static_cast<unsigned int>(*p);
        if (c < 0x80) {
            out += static_cast<char>(c);
        } else if (c < 0x800) {
            out += static_cast<char>(0xC0 | (c >> 6));
            out += static_cast<char>(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out += static_cast<char>(0xE0 | (c >> 12));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (c >> 18));
            out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        }
    }
    return out;
}

hid_device* asDevice(void* p) { return static_cast<hid_device*>(p); }

}  // namespace

std::vector<HidInterfaceInfo> enumerateInterfaces(uint16_t vendor_id, uint16_t product_id) {
    std::vector<HidInterfaceInfo> result;

    hid_device_info* head = hid_enumerate(vendor_id, product_id);
    for (hid_device_info* it = head; it != nullptr; it = it->next) {
        HidInterfaceInfo info;
        info.vendor_id        = it->vendor_id;
        info.product_id       = it->product_id;
        info.usage_page       = it->usage_page;
        info.usage            = it->usage;
        info.interface_number = it->interface_number;
        info.path             = (it->path != nullptr) ? it->path : "";
        info.serial           = wideToUtf8(it->serial_number);
        info.manufacturer     = wideToUtf8(it->manufacturer_string);
        info.product          = wideToUtf8(it->product_string);
        result.push_back(info);
    }
    if (head != nullptr) hid_free_enumeration(head);

    return result;
}

HidTransport::~HidTransport() {
    close();
}

bool HidTransport::open(const std::string& path, std::string& error) {
    error.clear();
    close();

    if (hid_init() != 0) {
        error = "hid_init() failed";
        return false;
    }

#if defined(__APPLE__)
    // ---------------------------------------------------------------------
    //  最小权限：hidapi 出于"向后兼容"默认以**独占**方式打开设备
    //  （mac/hid.c 中 hid_darwin_set_open_exclusive(1) / kIOHIDOptionsTypeSeizeDevice）。
    //  那会把设备控制权从别的程序手里抢走，既没必要也不礼貌。
    //  这里显式改成非独占，并留有 getter 供工具自检输出。
    // ---------------------------------------------------------------------
    hid_darwin_set_open_exclusive(0);
#endif

    device_ = hid_open_path(path.c_str());
    if (device_ == nullptr) {
        // hidapi 的全局错误（传 NULL）能说明真正原因：
        //   - device mach entry not found  → 路径已失效（设备被拔/重新枚举）
        //   - failed to open IOHIDDevice   → IOReturn 代码，常见为权限或设备被占用
        const wchar_t* e = hid_error(nullptr);
        error = "hid_open_path() failed for path: " + path;
        if (e != nullptr) error += std::string("  → ") + wideToUtf8(e);
        return false;
    }
    path_ = path;
    return true;
}

void HidTransport::close() {
    if (device_ != nullptr) {
        hid_close(asDevice(device_));
        device_ = nullptr;
    }
    path_.clear();
}

bool HidTransport::readReportDescriptor(std::vector<uint8_t>& out, std::string& error) {
    error.clear();
    out.clear();

    if (device_ == nullptr) {
        error = "device is not open";
        return false;
    }

    // 先用一个足够大的缓冲试探；hidapi 返回实际长度
    std::vector<uint8_t> buffer(4096, 0);
    const int n = hid_get_report_descriptor(asDevice(device_), buffer.data(), buffer.size());
    if (n < 0) {
        const wchar_t* e = hid_error(asDevice(device_));
        error = e ? wideToUtf8(e) : "hid_get_report_descriptor() failed";
        return false;
    }
    buffer.resize(static_cast<std::size_t>(n));
    out = std::move(buffer);
    return true;
}

int HidTransport::writeOnce(const std::vector<uint8_t>& buffer, std::string& error) {
    error.clear();

    if (device_ == nullptr) {
        error = "device is not open";
        return -1;
    }

    // -------------------------------------------------------------------
    //  单次写入：只调用一次 hid_write()。
    //  * 不重试
    //  * 不循环
    //  * 失败即返回，由调用方决定怎么报告
    // -------------------------------------------------------------------
    const int rc = hid_write(asDevice(device_), buffer.data(), buffer.size());
    if (rc < 0) {
        const wchar_t* e = hid_error(asDevice(device_));
        error = e ? wideToUtf8(e) : "hid_write() failed";
    }
    return rc;
}

std::string HidTransport::openModeDescription() const {
#if defined(__APPLE__)
    const int exclusive = hid_darwin_get_open_exclusive();
    if (device_ != nullptr) {
        const int dev_exclusive = hid_darwin_is_device_open_exclusive(asDevice(device_));
        return dev_exclusive ? "exclusive（会夺取其它程序的访问权）"
                             : "non-exclusive（未夺取其它程序的访问权）";
    }
    return exclusive ? "下一次打开将是 exclusive" : "下一次打开将是 non-exclusive";
#else
    return "（非 macOS，无此概念）";
#endif
}

}  // namespace k70
