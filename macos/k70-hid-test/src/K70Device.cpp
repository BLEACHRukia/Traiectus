// ============================================================================
//  K70HIDTest —— 目标设备身份与 Report Descriptor 解析实现（阶段⑦）
// ============================================================================

#include "K70Device.h"

#include <cstddef>
#include <cstdio>

namespace k70 {

namespace {

constexpr uint16_t kUpGenericDesktop = 0x01;
constexpr uint16_t kUpKeyCodes       = 0x07;
constexpr uint16_t kUpLed            = 0x08;
constexpr uint16_t kUpButton         = 0x09;
constexpr uint16_t kUpConsumer       = 0x0C;
constexpr uint16_t kUpVendorCorsair  = 0xFF42;

}  // namespace

std::string usagePageName(uint16_t page) {
    switch (page) {
    case kUpGenericDesktop: return "Generic Desktop";
    case 0x02:              return "Simulation";
    case 0x06:              return "Keyboard/Keypad";
    case kUpKeyCodes:       return "Key Codes";
    case kUpLed:            return "LED";
    case kUpButton:         return "Button";
    case kUpConsumer:       return "Consumer";
    case kUpVendorCorsair:  return "Vendor 0xFF42";
    default: {
        char buf[24];
        std::snprintf(buf, sizeof(buf), "0x%04X", page);
        return buf;
    }
    }
}

std::vector<HidInterfaceInfo> findVendorCandidates() {
    const auto all = enumerateInterfaces(kTargetDevice.vendor_id, kTargetDevice.product_id);
    return all;   // 同一 VID/PID 的所有接口，交给上层全部列出
}

std::vector<HidInterfaceInfo> findStrictMatches() {
    std::vector<HidInterfaceInfo> matches;
    for (const auto& info : findVendorCandidates()) {
        if (info.usage_page == kTargetDevice.usage_page &&
            info.usage      == kTargetDevice.usage) {
            matches.push_back(info);
        }
    }
    return matches;
}

DescriptorSummary parseReportDescriptor(const std::vector<uint8_t>& descriptor) {
    DescriptorSummary s;
    if (descriptor.empty()) {
        s.error = "descriptor is empty";
        return s;
    }

    uint16_t    usage_page = 0;
    int         report_id  = -1;
    uint32_t    report_size = 0;
    uint32_t    report_count = 0;
    std::size_t depth = 0;

    std::size_t i = 0;
    while (i < descriptor.size()) {
        const uint8_t prefix = descriptor[i];
        if (prefix == 0xFE) {                       // 长项目：跳过
            if (i + 2 >= descriptor.size()) break;
            const std::size_t len = descriptor[i + 1];
            i += 3 + len;
            continue;
        }

        std::size_t size = prefix & 0x03;
        if (size == 3) size = 4;
        const int type = (prefix >> 2) & 0x03;      // 0=主项 1=全局项 2=局部项
        const int tag  = (prefix >> 4) & 0x0F;

        std::uint32_t value = 0;
        for (std::size_t k = 0; k < size && i + 1 + k < descriptor.size(); ++k) {
            value |= static_cast<std::uint32_t>(descriptor[i + 1 + k]) << (8 * k);
        }

        if (type == 1) {                            // 全局项
            if (tag == 0x0)      usage_page   = static_cast<uint16_t>(value);
            else if (tag == 0x7) report_size  = value;
            else if (tag == 0x8) { report_id = static_cast<int>(value); s.has_report_id = true; }
            else if (tag == 0x9) report_count = value;
        } else if (type == 0) {                     // 主项
            if (tag == 0xA) {                       // Collection
                s.collection_usage_pages.push_back(usage_page);
                ++depth;
            } else if (tag == 0xC) {                // End Collection
                if (depth > 0) --depth;
            } else if (tag == 0x8 || tag == 0x9 || tag == 0xB) {   // Input / Output / Feature
                ReportItem item;
                item.kind         = (tag == 0x8) ? "Input" : (tag == 0x9) ? "Output" : "Feature";
                item.report_id    = (report_id >= 0) ? report_id : -1;
                item.report_size  = report_size;
                item.report_count = report_count;
                item.byte_length  = (static_cast<std::size_t>(report_size) *
                                     static_cast<std::size_t>(report_count) + 7) / 8;
                item.usage_page   = usage_page;
                s.items.push_back(item);

                if (item.kind == "Output"  && item.byte_length > s.max_output_bytes)  s.max_output_bytes  = item.byte_length;
                if (item.kind == "Input"   && item.byte_length > s.max_input_bytes)   s.max_input_bytes   = item.byte_length;
                if (item.kind == "Feature" && item.byte_length > s.max_feature_bytes) s.max_feature_bytes = item.byte_length;
            }
        }
        i += 1 + size;
    }

    s.ok = true;
    return s;
}

std::size_t expectedWriteLength(std::size_t payload_bytes) {
    // hidapi 约定：hid_write() 的缓冲 = Report ID 字节 + 报告负载
    return payload_bytes + 1;
}

}  // namespace k70
