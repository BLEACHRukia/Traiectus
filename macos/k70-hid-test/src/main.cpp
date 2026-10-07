// ============================================================================
//  K70HIDTest —— 命令行入口（阶段⑦）
// ----------------------------------------------------------------------------
//  已实现的命令：
//      list    枚举所有 VID/PID 匹配的接口，报告全部候选与严格匹配结果
//      info    打开严格匹配的接口，打印身份信息与 Report Descriptor 分析
//      dump    阶段⑨：纯离线构造数据包并打印 —— **不打开设备、不发送、不需要权限**
//      test-*  阶段⑩：**唯一允许写入的入口**。打开设备 → 只发送一次 → 打印结果 → 关闭 → 退出。
//              不做重试、不循环、不后台。非 BT1 的目标模式需要额外加 --confirm 才放行。
//
//  `HidTransport::writeOnce()` 只被 test-* 调用，且每次进程只调用一次。
// ============================================================================

#include <cstdio>
#include <string>
#include <vector>
#include <cctype>
#include <chrono>
#include <thread>

#include "K70Device.h"
#include "HidTransport.h"
#include "ReportBuilder.h"

namespace {

const char* kProgramName = "K70HIDTest";

void printUsage() {
    std::printf(
        "%s —— K70 Pro Mini HID 直接控制测试工具（阶段⑦）\n"
        "\n"
        "用法：\n"
        "  %s list            只读：枚举 VID/PID 匹配的全部接口并报告\n"
        "  %s info            只读：打开严格匹配的接口，打印 descriptor 分析\n"
        "  %s dump <mode>     离线：只构造数据包并打印，不打开设备、不发送\n"
        "                     <mode> = bt1 | bt2 | bt3 | slipstream\n"
        "\n"
        "真机写入（唯一允许写入的入口；每次只发一次，不重试、不循环）：\n"
        "  %s test-bt1                  目标 = 蓝牙 Host 1（风险最低）\n"
        "  %s test-slipstream --confirm 目标 = SLIPSTREAM（会把键盘交给 Windows）\n"
        "  %s test-bt2 --confirm        目标 = 蓝牙 Host 2\n"
        "  %s test-bt3 --confirm        目标 = 蓝牙 Host 3\n"
        "     非 bt1 的模式必须显式加 --confirm —— 那些模式有让键盘离开本机的风险。\n"
        "     这些命令必须在**有「输入监控」权限**的终端里运行（否则打开设备会被系统拒绝）。\n"
        "\n"
        "说明：除 test-* 外，其余命令都不会发送任何 HID 数据。\n",
        kProgramName, kProgramName, kProgramName, kProgramName,
        kProgramName, kProgramName, kProgramName, kProgramName);
}

std::string hexLine(const std::vector<uint8_t>& data, const std::size_t from,
                    const std::size_t count) {
    std::string out;
    char buf[4];
    for (std::size_t i = from; i < from + count && i < data.size(); ++i) {
        std::snprintf(buf, sizeof(buf), "%02X", data[i]);
        if (!out.empty()) out += ' ';
        out += buf;
    }
    return out;
}

std::string hexBytes(const std::vector<uint8_t>& data) {
    return hexLine(data, 0, data.size());
}

int commandList() {
    const auto candidates = k70::findVendorCandidates();
    if (candidates.empty()) {
        std::printf("未找到 VID=0x%04X PID=0x%04X 的任何 HID 接口。\n",
                    k70::kTargetDevice.vendor_id, k70::kTargetDevice.product_id);
        std::printf("请确认键盘已用 USB 数据线连接（不是只充电的线）。\n");
        return 1;
    }

    std::printf("VID=0x%04X PID=0x%04X 的 HID 接口共 %zu 个：\n\n",
                k70::kTargetDevice.vendor_id, k70::kTargetDevice.product_id,
                candidates.size());

    for (std::size_t i = 0; i < candidates.size(); ++i) {
        const auto& c = candidates[i];
        const bool strict = (c.usage_page == k70::kTargetDevice.usage_page &&
                             c.usage      == k70::kTargetDevice.usage);
        std::printf("  [%zu] UsagePage=0x%04X (%s) Usage=0x%04X  interface=%d  %s\n",
                    i + 1, c.usage_page, k70::usagePageName(c.usage_page).c_str(),
                    c.usage, c.interface_number,
                    strict ? "★ 严格匹配（目标接口）" : "");
        std::printf("      Manufacturer: %s\n", c.manufacturer.c_str());
        std::printf("      Product     : %s\n", c.product.c_str());
        std::printf("      Serial      : %s\n", c.serial.c_str());
        std::printf("      Path        : %s\n", c.path.c_str());
        std::printf("\n");
    }

    const auto matches = k70::findStrictMatches();
    if (matches.size() == 1) {
        std::printf("严格匹配（VID+PID+UsagePage+Usage 四项）结果：恰好 1 个 ✓\n");
        return 0;
    }
    if (matches.empty()) {
        std::printf("严格匹配结果：0 个 —— 缺少 usage page 0x%04X / usage 0x%04X 的接口。\n",
                    k70::kTargetDevice.usage_page, k70::kTargetDevice.usage);
        return 1;
    }
    std::printf("严格匹配结果：%zu 个 —— 出现歧义，按规范**不得猜测**，停止。\n",
                matches.size());
    return 2;
}

int commandInfo() {
    const auto matches = k70::findStrictMatches();
    if (matches.empty()) {
        std::printf("未找到严格匹配的目标接口（VID=0x%04X PID=0x%04X UsagePage=0x%04X Usage=0x%04X）。\n",
                    k70::kTargetDevice.vendor_id, k70::kTargetDevice.product_id,
                    k70::kTargetDevice.usage_page, k70::kTargetDevice.usage);
        return 1;
    }
    if (matches.size() > 1) {
        std::printf("严格匹配到 %zu 个接口 —— 出现歧义，按规范不得猜测，停止。\n", matches.size());
        return 2;
    }

    const auto& d = matches.front();
    std::printf("=== 目标设备 ===\n");
    std::printf("  Manufacturer : %s\n", d.manufacturer.c_str());
    std::printf("  Product      : %s\n", d.product.c_str());
    std::printf("  Serial       : %s\n", d.serial.c_str());
    std::printf("  VID / PID    : 0x%04X / 0x%04X\n", d.vendor_id, d.product_id);
    std::printf("  UsagePage    : 0x%04X\n", d.usage_page);
    std::printf("  Usage        : 0x%04X\n", d.usage);
    std::printf("  Interface    : %d\n", d.interface_number);
    std::printf("  Path         : %s\n", d.path.c_str());
    std::printf("\n");

    k70::HidTransport transport;
    std::string error;
    if (!transport.open(d.path, error)) {
        std::printf("打开设备失败：%s\n", error.c_str());
        return 1;
    }
    std::printf("设备已打开。打开模式：%s\n\n", transport.openModeDescription().c_str());

    std::vector<uint8_t> descriptor;
    if (!transport.readReportDescriptor(descriptor, error)) {
        std::printf("读取 Report Descriptor 失败：%s\n", error.c_str());
        transport.close();
        return 1;
    }
    std::printf("=== Report Descriptor（%zu 字节）===\n", descriptor.size());
    std::printf("  HEX: %s\n\n", hexBytes(descriptor).c_str());

    const k70::DescriptorSummary summary = k70::parseReportDescriptor(descriptor);
    if (!summary.ok) {
        std::printf("解析失败：%s\n", summary.error.c_str());
        transport.close();
        return 1;
    }

    std::printf("  集合的 Usage Page：");
    for (std::size_t i = 0; i < summary.collection_usage_pages.size(); ++i) {
        if (i) std::printf(", ");
        std::printf("0x%04X (%s)", summary.collection_usage_pages[i],
                    k70::usagePageName(summary.collection_usage_pages[i]).c_str());
    }
    std::printf("\n");
    std::printf("  使用编号报告（Report ID）：%s\n", summary.has_report_id ? "是" : "否（Report ID = 0）");
    std::printf("\n  Report 项：\n");
    for (const auto& item : summary.items) {
        std::printf("    %-7s reportID=%-4d %5zu 字节   page=0x%04X (%s)  size=%u bit × count=%u\n",
                    item.kind.c_str(), item.report_id, item.byte_length,
                    item.usage_page, k70::usagePageName(item.usage_page).c_str(),
                    item.report_size, item.report_count);
    }
    std::printf("\n=== 计算 ===\n");
    std::printf("  Output Report 最大长度 : %zu 字节\n", summary.max_output_bytes);
    std::printf("  Input  Report 最大长度 : %zu 字节\n", summary.max_input_bytes);
    std::printf("  Feature Report 最大长度: %zu 字节\n", summary.max_feature_bytes);
    std::printf("  hid_write() 应为        : %zu 字节（= %zu + 1 字节 Report ID）\n",
                k70::expectedWriteLength(summary.max_output_bytes), summary.max_output_bytes);
    std::printf("\n");
    std::printf("（只读操作结束。本命令不会发送任何数据。）\n");

    transport.close();
    return 0;
}

// ---------------------------------------------------------------------------
//  dump（阶段⑨）：纯离线构造数据包并打印。
//  本函数**不包含任何设备 API 调用** —— 不枚举、不打开、不发送。
//  因此它不需要任何系统权限，设备插不插都能运行。
// ---------------------------------------------------------------------------
int commandDump(const std::string& modeArg) {
    std::string lower;
    for (char c : modeArg) {
        lower += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    k70::ConnectionMode mode;
    const char* modeName = nullptr;
    if (lower == "bt1") {
        mode = k70::ConnectionMode::Bluetooth1; modeName = "Bluetooth Host 1";
    } else if (lower == "bt2") {
        mode = k70::ConnectionMode::Bluetooth2; modeName = "Bluetooth Host 2";
    } else if (lower == "bt3") {
        mode = k70::ConnectionMode::Bluetooth3; modeName = "Bluetooth Host 3";
    } else if (lower == "slipstream") {
        mode = k70::ConnectionMode::Slipstream; modeName = "SLIPSTREAM";
    } else {
        std::printf("未知模式：%s（可用：bt1 | bt2 | bt3 | slipstream）\n", modeArg.c_str());
        return 2;
    }

    const std::vector<uint8_t> packet = k70::buildConnectionModeReport(mode);
    const unsigned modeByte = static_cast<unsigned>(static_cast<uint8_t>(mode));

    std::printf("=== dump：%s（纯离线构造，未打开任何设备、未发送任何数据）===\n", modeName);
    std::printf("  模式       : %s\n", modeName);
    std::printf("  模式字节   : 0x%02X\n", modeByte);
    std::printf("  Report ID  : 0x%02X\n", k70::kReportId);
    std::printf("  端点/通道  : 0x%02X\n", k70::kEndpointChannel);
    std::printf("  命令       : 0x%02X 0x%02X\n", k70::kCommandByte0, k70::kCommandByte1);
    std::printf("  固定参数   : 0x%02X\n", k70::kFixedParameter);
    std::printf("  数据包总长 : %zu 字节（= %zu 字节报告 + 1 字节 Report ID）\n",
                packet.size(), k70::kOutputReportLength);
    std::printf("  hid_write() : 应传入 %zu 字节\n", packet.size());
    std::printf("\n  前 32 字节 : %s\n", hexLine(packet, 0, 32).c_str());
    std::printf("  第 33 – %zu 字节：全部为 0x00\n", packet.size());
    std::printf("\n  （本命令不打开设备、不需要任何权限；写入属阶段⑩，需单独批准。）\n");
    return 0;
}

// ---------------------------------------------------------------------------
//  test-<mode>（阶段⑩）：**唯一允许写入的入口**
//  流程：找目标 → 打开（非独占）→ 只调用一次 writeOnce() → 打印结果 → 关闭
//        → 一次固定等待 → 枚举对比 → 三层判定
//  不重试、不循环、不轮询、不后台。
// ---------------------------------------------------------------------------
enum class RiskLevel { Low, Medium, High };

const char* riskName(RiskLevel r) {
    switch (r) {
    case RiskLevel::Low:    return "低（预期键盘仍留在本机；若「有线优先」，命令会被忽略）";
    case RiskLevel::Medium: return "中（键盘可能被交给另一台机器，本机将失去键盘）";
    case RiskLevel::High:   return "高（目标主机可能未配对，键盘可能暂时谁都连不上）";
    }
    return "?";
}

int commandTest(const std::string& modeArg, bool confirmed) {
    std::string lower;
    for (char c : modeArg) {
        lower += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    k70::ConnectionMode mode;
    const char* modeName = nullptr;
    RiskLevel risk = RiskLevel::Low;
    if (lower == "bt1") {
        mode = k70::ConnectionMode::Bluetooth1; modeName = "Bluetooth Host 1"; risk = RiskLevel::Low;
    } else if (lower == "bt2") {
        mode = k70::ConnectionMode::Bluetooth2; modeName = "Bluetooth Host 2"; risk = RiskLevel::High;
    } else if (lower == "bt3") {
        mode = k70::ConnectionMode::Bluetooth3; modeName = "Bluetooth Host 3"; risk = RiskLevel::High;
    } else if (lower == "slipstream") {
        mode = k70::ConnectionMode::Slipstream; modeName = "SLIPSTREAM"; risk = RiskLevel::Medium;
    } else {
        std::printf("未知目标：%s（可用：bt1 | bt2 | bt3 | slipstream）\n", modeArg.c_str());
        return 2;
    }

    std::printf("=== test-%s：真实写入（只发送一次；不重试、不循环、不后台）===\n", lower.c_str());
    std::printf("  目标模式 : %s（0x%02X）\n", modeName,
                static_cast<unsigned>(static_cast<uint8_t>(mode)));
    std::printf("  风险等级 : %s\n", riskName(risk));

    if (risk != RiskLevel::Low && !confirmed) {
        std::printf("\n[已拒绝] 该模式需要显式确认，未发送任何数据。\n");
        std::printf("  原因：它可能把键盘交给另一台机器，或让它暂时谁也连不上。\n");
        std::printf("  确认方式：命令末尾加 --confirm，例如\n");
        std::printf("      %s test-%s --confirm\n", kProgramName, lower.c_str());
        std::printf("  恢复手段：拔插 USB 线，或在键盘上按 Fn 组合键切回。\n");
        return 3;
    }
    std::printf("\n");

    // ---- 1) 定位目标 ----
    const auto matches = k70::findStrictMatches();
    if (matches.empty()) {
        std::printf("[停止] 未找到严格匹配的目标接口，未发送任何数据。\n");
        std::printf("       请确认键盘已用 USB 数据线连接，且本进程有「输入监控」权限。\n");
        return 1;
    }
    if (matches.size() > 1) {
        std::printf("[停止] 严格匹配到 %zu 个接口，出现歧义；按规范不得猜测，未发送任何数据。\n",
                    matches.size());
        return 2;
    }
    const auto& d = matches.front();
    std::printf("=== 目标设备 ===\n");
    std::printf("  VID / PID    : 0x%04X / 0x%04X\n", d.vendor_id, d.product_id);
    std::printf("  UsagePage    : 0x%04X\n", d.usage_page);
    std::printf("  Usage        : 0x%04X\n", d.usage);
    std::printf("  Interface    : %d\n", d.interface_number);
    std::printf("  Path         : %s\n", d.path.c_str());
    std::printf("\n");

    // ---- 2) 打开 ----
    k70::HidTransport transport;
    std::string error;
    std::printf("=== 打开 ===\n");
    if (!transport.open(d.path, error)) {
        std::printf("  打开失败：%s\n", error.c_str());
        std::printf("  （未发送任何数据。）\n");
        return 1;
    }
    std::printf("  打开成功。打开模式：%s\n", transport.openModeDescription().c_str());
    std::printf("\n");

    // ---- 3) 构造 ----
    const std::vector<uint8_t> packet = k70::buildConnectionModeReport(mode);
    std::printf("=== 将要发送的数据包 ===\n");
    std::printf("  Report ID    : 0x%02X\n", k70::kReportId);
    std::printf("  数据包总长   : %zu 字节（= %zu 字节报告 + 1 字节 Report ID）\n",
                packet.size(), k70::kOutputReportLength);
    std::printf("  hid_write()  : 传入 %zu 字节\n", packet.size());
    std::printf("  前 32 字节   : %s\n", hexLine(packet, 0, 32).c_str());
    std::printf("\n");

    // ---- 4) 唯一一次写入 ----
    std::printf("=== 写入（仅此一次）===\n");
    const int rc = transport.writeOnce(packet, error);
    std::printf("  hid_write() 返回值 : %d（期望 %zu）\n", rc, packet.size());
    std::printf("  hid_error()        : %s\n", error.empty() ? "（无错误）" : error.c_str());
    std::printf("\n");

    // ---- 5) 关闭 ----
    transport.close();
    std::printf("=== 关闭 ===\n");
    std::printf("  设备已关闭（关闭结果：成功）\n");
    std::printf("\n");

    // ---- 6) 一次固定等待后枚举对比（不轮询、不重试）----
    const int settleMs = 1500;
    std::printf("=== 发送后观察 ===\n");
    std::printf("  等待 %d ms 让设备完成切换（只等一次，不轮询）…\n", settleMs);
    std::this_thread::sleep_for(std::chrono::milliseconds(settleMs));

    const auto vendorAfter = k70::findStrictMatches();
    const auto bluetoothAfter = k70::enumerateInterfaces(0x1B1C, 0x1B6E);   // 蓝牙连接时的 PID
    std::printf("  厂商接口（FF42/01）数量 : %zu（发送前为 %zu）\n",
                vendorAfter.size(), matches.size());
    std::printf("  蓝牙设备（PID 1B6E）数量 : %zu\n", bluetoothAfter.size());
    if (vendorAfter.empty()) {
        std::printf("  → 命令后设备断开/离开：这可能正是连接模式切换的表现（规范 §13），不能直接判为失败。\n");
    }
    std::printf("\n");

    // ---- 7) 三层判定（规范 §8：不把「写入成功」当成「切换成功」）----
    std::printf("=== 三层判定 ===\n");
    std::printf("  第 1 层 HID 写入是否成功 : %s\n",
                (rc == static_cast<int>(packet.size())) ? "是（系统接受了这次写入）" : "否");
    std::printf("  第 2 层 设备是否仍可访问 : %s\n",
                vendorAfter.empty() ? "否（厂商接口已消失）" : "是（厂商接口仍在）");
    if (!bluetoothAfter.empty()) {
        std::printf("  第 3 层 模式是否真的改变 : 观察到键盘已以蓝牙方式出现（PID 0x1B6E）→ 切换成功\n");
    } else {
        std::printf("  第 3 层 模式是否真的改变 : **无法独立确认**\n");
        std::printf("      （未观察到蓝牙设备出现；请用目视 + 在键盘上打字确认；\n");
        std::printf("        若键盘仍在有线模式，说明「有线优先」使命令被忽略，也属正常结果。）\n");
    }
    std::printf("\n  本次进程只调用了 writeOnce() 一次；未重试、未循环、未后台。\n");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        printUsage();
        return 2;
    }

    const std::string cmd = argv[1];
    if (cmd == "list") return commandList();
    if (cmd == "info") return commandInfo();
    if (cmd == "dump") {
        if (argc < 3) {
            std::printf("dump 需要模式参数：bt1 | bt2 | bt3 | slipstream\n\n");
            printUsage();
            return 2;
        }
        return commandDump(argv[2]);
    }
    if (cmd.rfind("test-", 0) == 0) {
        bool confirmed = false;
        for (int i = 2; i < argc; ++i) {
            if (std::string(argv[i]) == "--confirm") confirmed = true;
        }
        return commandTest(cmd.substr(5), confirmed);
    }
    if (cmd == "--help" || cmd == "-h" || cmd == "help") {
        printUsage();
        return 0;
    }

    std::printf("未知命令：%s\n\n", cmd.c_str());
    printUsage();
    return 2;
}
