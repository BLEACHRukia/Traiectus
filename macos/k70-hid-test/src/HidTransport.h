// ============================================================================
//  K70HIDTest —— 设备访问层（阶段⑦）
// ----------------------------------------------------------------------------
//  最小权限原则：
//    * 只提供"枚举 / 打开 / 关闭 / 读 descriptor / **单次**写入"这五件事
//    * 没有循环、没有重试、没有自动切换、没有后台线程
//    * macOS 上显式以**非独占**方式打开，绝不抢走其它程序的设备控制权
//    * `writeOnce()` 存在但**当前没有任何 CLI 命令调用它**（写入属阶段⑩）
// ============================================================================

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace k70 {

/// 一个 HID 接口的描述（来自 hidapi 的 `hid_enumerate`，不打开设备）
struct HidInterfaceInfo {
    uint16_t    vendor_id        = 0;
    uint16_t    product_id       = 0;
    uint16_t    usage_page       = 0;
    uint16_t    usage            = 0;
    int         interface_number = -1;
    std::string path;                 ///< hidapi 给的设备路径，供 hid_open_path 使用
    std::string serial;               ///< 可能为空
    std::string manufacturer;
    std::string product;
};

/// 枚举 HID 接口。vendor_id / product_id 传 0 表示不过滤。**不打开任何设备**。
std::vector<HidInterfaceInfo> enumerateInterfaces(uint16_t vendor_id = 0,
                                                  uint16_t product_id = 0);

/// 设备句柄的 RAII 包装。析构自动关闭。
class HidTransport {
public:
    HidTransport() = default;
    ~HidTransport();

    HidTransport(const HidTransport&)            = delete;
    HidTransport& operator=(const HidTransport&) = delete;

    /// 打开指定路径。macOS 上使用非独占打开（kIOHIDOptionsTypeNone）。
    bool open(const std::string& path, std::string& error);

    /// 关闭（幂等；内部无重试）。
    void close();

    bool isOpen() const { return device_ != nullptr; }
    const std::string& openedPath() const { return path_; }

    /// 读取 Report Descriptor（只读操作）。
    bool readReportDescriptor(std::vector<uint8_t>& out, std::string& error);

    /// **单次**写入：只调用一次 `hid_write()`，不重试、不循环。
    /// 返回 hid_write 的返回值（成功时等于传入长度）；失败返回 -1 并在 error 写入 hid_error。
    int writeOnce(const std::vector<uint8_t>& buffer, std::string& error);

    /// 描述当前打开模式（用于自证"非独占"，不夺取其它程序的访问权）
    std::string openModeDescription() const;

private:
    void*       device_ = nullptr;   ///< 实际类型是 hid_device*，这里避免头文件外泄
    std::string path_;
};

}  // namespace k70
