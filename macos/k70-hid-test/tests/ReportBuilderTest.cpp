// ============================================================================
//  K70HIDTest —— ReportBuilder 离线单元测试（阶段⑥）
// ----------------------------------------------------------------------------
//  **纯离线**：不打开设备、不调用 hid_write()、不发送任何数据。
//  只构造数据包并逐字节校验，最后打印四种模式各自的前 32 字节。
//
//  校验项（对应阶段 B 规范）：
//    总长度 = 1025
//    [0] = 0x00   Report ID
//    [1] = 0x08   端点/通道
//    [2] = 0x01   命令高字节
//    [3] = 0x3A   命令低字节
//    [4] = 0x00   固定参数
//    [5] = mode   BT1=0x02 / BT2=0x03 / BT3=0x08 / SLIPSTREAM=0x01
//    [6..1024] 全部为 0
// ============================================================================

#include "ReportBuilder.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool ok, const char* what) {
    ++g_checks;
    if (ok) {
        std::printf("   [PASS] %s\n", what);
    } else {
        ++g_failures;
        std::printf("   [FAIL] %s\n", what);
    }
}

std::string hex(const std::vector<uint8_t>& data, std::size_t count) {
    std::string out;
    char buf[4];
    for (std::size_t i = 0; i < count && i < data.size(); ++i) {
        std::snprintf(buf, sizeof(buf), "%02X", data[i]);
        if (!out.empty()) out += ' ';
        out += buf;
    }
    return out;
}

void testMode(k70::ConnectionMode mode, uint8_t expected, const char* name) {
    const std::vector<uint8_t> buf = k70::buildConnectionModeReport(mode);

    std::printf("── %s（mode = 0x%02X）\n", name, static_cast<unsigned>(expected));
    check(buf.size() == k70::kWriteBufferLength, "总长度 = 1025");
    check(buf.size() == 1025, "总长度恰好等于字面量 1025");
    check(buf[0] == 0x00, "[0] = 0x00（Report ID）");
    check(buf[1] == 0x08, "[1] = 0x08（端点/通道）");
    check(buf[2] == 0x01, "[2] = 0x01（命令高字节）");
    check(buf[3] == 0x3A, "[3] = 0x3A（命令低字节）");
    check(buf[4] == 0x00, "[4] = 0x00（固定参数）");
    check(buf[5] == expected, "[5] = 目标模式");

    bool padding_ok = true;
    std::size_t first_bad = 0;
    for (std::size_t i = 6; i < buf.size(); ++i) {
        if (buf[i] != 0x00) { padding_ok = false; first_bad = i; break; }
    }
    if (!padding_ok) {
        std::printf("          （首个非零填充字节在偏移 %zu，值 0x%02X）\n", first_bad, buf[first_bad]);
    }
    check(padding_ok, "[6..1024] 全部为 0");

    std::printf("       前 32 字节: %s\n\n", hex(buf, 32).c_str());
}

}  // namespace

int main() {
    std::printf("=====================================================================\n");
    std::printf(" K70HIDTest —— ReportBuilder 离线单元测试\n");
    std::printf(" 本测试不打开设备、不调用 hid_write()、不发送任何数据\n");
    std::printf("=====================================================================\n\n");

    testMode(k70::ConnectionMode::Bluetooth1, 0x02, "BT1");
    testMode(k70::ConnectionMode::Bluetooth2, 0x03, "BT2");
    testMode(k70::ConnectionMode::Bluetooth3, 0x08, "BT3");
    testMode(k70::ConnectionMode::Slipstream, 0x01, "SLIPSTREAM");

    // 附加不变量：四种包只在第 5 字节不同，其余部分必须完全一致
    const std::vector<uint8_t> a = k70::buildConnectionModeReport(k70::ConnectionMode::Bluetooth1);
    const std::vector<uint8_t> b = k70::buildConnectionModeReport(k70::ConnectionMode::Slipstream);
    bool only_mode_byte_differs = (a.size() == b.size());
    for (std::size_t i = 0; only_mode_byte_differs && i < a.size(); ++i) {
        if (i == 5) continue;
        if (a[i] != b[i]) only_mode_byte_differs = false;
    }
    std::printf("── 附加不变量\n");
    check(only_mode_byte_differs, "四种数据包仅在偏移 5（模式字节）不同，其余完全一致");
    check(k70::isKnownConnectionMode(0x01) && k70::isKnownConnectionMode(0x02) &&
          k70::isKnownConnectionMode(0x03) && k70::isKnownConnectionMode(0x08),
          "isKnownConnectionMode() 认可四种模式");
    check(!k70::isKnownConnectionMode(0x00) && !k70::isKnownConnectionMode(0x04),
          "isKnownConnectionMode() 拒绝未确认的模式值");
    std::printf("\n");

    std::printf("=====================================================================\n");
    std::printf(" 检查项 %d 个，失败 %d 个 → %s\n", g_checks, g_failures,
                g_failures == 0 ? "全部通过" : "存在失败");
    std::printf(" 离线确认：本测试全程未访问任何 HID 设备\n");
    std::printf("=====================================================================\n");

    return g_failures == 0 ? 0 : 1;
}
