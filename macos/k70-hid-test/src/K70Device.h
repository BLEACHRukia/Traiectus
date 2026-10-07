// ============================================================================
//  K70HIDTest —— 目标设备身份与 Report Descriptor 解析（阶段⑦）
// ----------------------------------------------------------------------------
//  目标设备必须**同时**满足四项（规范 §9）：
//      VID = 0x1B1C   PID = 0x1BB6   Usage Page = 0xFF42   Usage = 0x0001
//  缺少任何一项 → 不匹配；出现多个匹配 → 报告并停止，绝不猜。
// ============================================================================

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "HidTransport.h"

namespace k70 {

struct DeviceIdentity {
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t usage_page;
    uint16_t usage;
};

/// 阶段 A 已确认的目标身份
constexpr DeviceIdentity kTargetDevice{0x1B1C, 0x1BB6, 0xFF42, 0x0001};

/// VID/PID 相同的全部接口（含非目标接口）——用于"报告所有候选"
std::vector<HidInterfaceInfo> findVendorCandidates();

/// 严格四项匹配的接口（正常应恰好 1 个）
std::vector<HidInterfaceInfo> findStrictMatches();

/// 单个 Report 项（Input / Output / Feature 中的一条）
struct ReportItem {
    std::string kind;        ///< "Input" / "Output" / "Feature"
    int         report_id;   ///< -1 表示未使用编号报告
    uint32_t    report_size;  ///< bit
    uint32_t    report_count;
    std::size_t byte_length; ///< ceil(size × count / 8)
    uint16_t    usage_page;  ///< 该项所在的 usage page
};

struct DescriptorSummary {
    bool                      ok = false;
    std::string               error;
    std::vector<uint16_t>     collection_usage_pages;   ///< 出现过的集合 usage page
    std::vector<ReportItem>   items;
    bool                      has_report_id = false;
    std::size_t               max_output_bytes = 0;
    std::size_t               max_input_bytes  = 0;
    std::size_t               max_feature_bytes = 0;
};

/// 解析 HID Report Descriptor（纯计算，不访问设备）
DescriptorSummary parseReportDescriptor(const std::vector<uint8_t>& descriptor);

/// 计算 hid_write() 应传入的长度：payload + 1 字节 Report ID
std::size_t expectedWriteLength(std::size_t payload_bytes);

/// usage page 的可读名称（用于报告输出）
std::string usagePageName(uint16_t page);

}  // namespace k70
