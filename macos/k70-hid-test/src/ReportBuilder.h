// ============================================================================
//  K70HIDTest —— ReportBuilder（阶段⑤）
// ----------------------------------------------------------------------------
//  本文件**只做数据包构造**：
//    * 不打开任何设备
//    * 不调用 hid_write()
//    * 不发送任何 HID Output Report
//  所有常量都来自两处已验证来源（缺一不可）：
//    1. OpenLinkHub `src/devices/k70pmWU/k70pmWU.go`（协议结构）
//    2. 本机 USB 直连后读到的 Report Descriptor（0xFF42/0x01：无 Report ID、
//       Output Report = 8 bit × 1024 = 1024 字节）
// ============================================================================

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace k70 {

// ---------------------------------------------------------------------------
//  连接模式（数值来自 OpenLinkHub k70pmWU.go 的 Fn 键分支）
// ---------------------------------------------------------------------------
enum class ConnectionMode : uint8_t {
    Slipstream = 0x01,   // 2.4G 接收器（SLIPSTREAM）
    Bluetooth1 = 0x02,   // 蓝牙 Host 1
    Bluetooth2 = 0x03,   // 蓝牙 Host 2
    Bluetooth3 = 0x08,   // 蓝牙 Host 3
};

// ---------------------------------------------------------------------------
//  长度常量（由 Report Descriptor 验证得出）
// ---------------------------------------------------------------------------
/// HID Output Report 的净长度：Report Size(8bit) × Report Count(1024)
constexpr std::size_t kOutputReportLength = 1024;

/// hid_write() 需要的总长度 = 报告净长度 + 1 字节 Report ID
/// （hidapi 头文件：calls to hid_write() will always contain one more byte than the report contains）
constexpr std::size_t kWriteBufferLength = kOutputReportLength + 1;   // 1025

// ---------------------------------------------------------------------------
//  协议字节（来自 OpenLinkHub k70pmWU.go 的 transfer() / changeConnectionMode()）
// ---------------------------------------------------------------------------
/// descriptor 中没有 Report ID 项 → Report ID = 0（不使用编号报告）
constexpr uint8_t kReportId         = 0x00;
/// bufferW[1]：端点 / 通道字节
constexpr uint8_t kEndpointChannel  = 0x08;
/// cmdConnectionMode = {0x01, 0x3A}
constexpr uint8_t kCommandByte0     = 0x01;
constexpr uint8_t kCommandByte1     = 0x3A;
/// changeConnectionMode() 里 buf[0] 的固定参数
constexpr uint8_t kFixedParameter   = 0x00;
/// 模式参数在缓冲里的位置（buf[1] → 写缓冲第 5 字节）
constexpr std::size_t kModeOffset   = 5;

// ---------------------------------------------------------------------------
//  构造
// ---------------------------------------------------------------------------
/// 构造 1025 字节的 connection-mode 写缓冲。
/// 布局： [0]=0x00  [1]=0x08  [2]=0x01  [3]=0x3A  [4]=0x00  [5]=mode  [6..1024]=0x00
std::vector<uint8_t> buildConnectionModeReport(ConnectionMode mode);

/// 同上，接受裸数值（调用方应先用 isKnownConnectionMode() 校验）
std::vector<uint8_t> buildConnectionModeReport(uint8_t mode);

/// 是否为已确认的四种模式之一
bool isKnownConnectionMode(uint8_t mode);

/// 人类可读名称（日志 / CLI 用）
const char* connectionModeName(ConnectionMode mode);

}  // namespace k70
