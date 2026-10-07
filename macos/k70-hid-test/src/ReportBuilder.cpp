// ============================================================================
//  K70HIDTest —— ReportBuilder 实现（阶段⑤）
//  纯数据构造：无设备访问、无 hid_write()、无任何发送。
// ============================================================================

#include "ReportBuilder.h"

namespace k70 {

std::vector<uint8_t> buildConnectionModeReport(ConnectionMode mode) {
    return buildConnectionModeReport(static_cast<uint8_t>(mode));
}

std::vector<uint8_t> buildConnectionModeReport(uint8_t mode) {
    // 整块先置 0，天然满足 [6..1024] 全部为 0 的填充要求
    std::vector<uint8_t> buffer(kWriteBufferLength, 0x00);

    buffer[0]          = kReportId;        // 0x00 —— Report ID（无编号报告）
    buffer[1]          = kEndpointChannel; // 0x08 —— 端点/通道
    buffer[2]          = kCommandByte0;    // 0x01
    buffer[3]          = kCommandByte1;    // 0x3A
    buffer[4]          = kFixedParameter;  // 0x00
    buffer[kModeOffset] = mode;            // 目标连接模式

    return buffer;
}

bool isKnownConnectionMode(uint8_t mode) {
    switch (static_cast<ConnectionMode>(mode)) {
    case ConnectionMode::Slipstream:
    case ConnectionMode::Bluetooth1:
    case ConnectionMode::Bluetooth2:
    case ConnectionMode::Bluetooth3:
        return true;
    }
    return false;
}

const char* connectionModeName(ConnectionMode mode) {
    switch (mode) {
    case ConnectionMode::Slipstream: return "SLIPSTREAM";
    case ConnectionMode::Bluetooth1: return "Bluetooth Host 1";
    case ConnectionMode::Bluetooth2: return "Bluetooth Host 2";
    case ConnectionMode::Bluetooth3: return "Bluetooth Host 3";
    }
    return "UNKNOWN";
}

}  // namespace k70
