// ============================================================================
//  netinfo.h —— 查"当前默认路由那张网卡"的 IPv4 / 网关 / 适配器名 / DHCP 租约
// ----------------------------------------------------------------------------
//  用途：
//    · 托盘状态区那行「本机 IP：x.x.x.x」（用户自己核对，也方便回报）
//    · 服务端启动时日志里那行「本机网络：…」（排查地址飘没飘）
//
//  为什么用 GetAdaptersAddresses 而不是"连一下 8.8.8.8 看源地址"：
//    后者会受 TUN / 虚拟网卡（Tailscale、Clash 等）影响，拿到的可能是
//    100.x 那种隧道地址，而不是 Mac 能连到的那张网卡。这里显式挑
//    **有默认网关、且在线**的那张，并跳过 169.254.* 的链路本地地址。
//
//  依赖：<iphlpapi.h>（链接时加 iphlpapi）
//  包含顺序：本文件必须排在 windows.h **后面**（两个使用方都是这么做的）。
//
//  这份文件在 launcher\ 和 phase3-tcp\src\ 下各一份，**内容必须完全一致**。
// ============================================================================
#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <iptypes.h>

#include <string>
#include <vector>

struct NetInfo {
    bool               valid        = false;
    std::wstring       adapter;                  // 适配器友好名，例如 WLAN
    std::wstring       ip;                       // a.b.c.d
    std::wstring       gateway;                  // a.b.c.d（可能为空）
    bool               dhcp         = false;
    unsigned long long leaseExpires = 0;         // Unix 时间戳；0 = 没有/不适用
};

namespace netinfo_detail {

inline std::wstring Ip4Text(const SOCKADDR* sa) {
    if (!sa || sa->sa_family != AF_INET) return std::wstring();
    const BYTE* b = reinterpret_cast<const BYTE*>(
                        &reinterpret_cast<const SOCKADDR_IN*>(sa)->sin_addr.S_un.S_addr);
    wchar_t buf[32];
    ::swprintf(buf, 32, L"%u.%u.%u.%u", (unsigned)b[0], (unsigned)b[1],
               (unsigned)b[2], (unsigned)b[3]);
    return std::wstring(buf);
}

inline bool IsLinkLocal(const SOCKADDR* sa) {
    if (!sa || sa->sa_family != AF_INET) return false;
    const BYTE* b = reinterpret_cast<const BYTE*>(
                        &reinterpret_cast<const SOCKADDR_IN*>(sa)->sin_addr.S_un.S_addr);
    return b[0] == 169 && b[1] == 254;           // 169.254.x.x
}

}  // namespace netinfo_detail

// 找不到就返回 valid == false（调用方自己决定显示什么）
inline NetInfo QueryDefaultRouteNet() {
    NetInfo out;
    const DWORD flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST |
                        GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    ULONG size = 0;
    if (::GetAdaptersAddresses(AF_INET, flags, nullptr, nullptr, &size) != ERROR_BUFFER_OVERFLOW) {
        return out;
    }
    std::vector<BYTE> buf((size_t)size);
    auto* head = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
    if (::GetAdaptersAddresses(AF_INET, flags, nullptr, head, &size) != NO_ERROR) {
        return out;
    }

    const IP_ADAPTER_ADDRESSES* pick     = nullptr;
    const IP_ADAPTER_ADDRESSES* fallback = nullptr;
    for (auto* a = head; a != nullptr; a = a->Next) {
        if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        if (a->OperStatus != IfOperStatusUp) continue;

        bool usable = false;
        for (auto* u = a->FirstUnicastAddress; u != nullptr; u = u->Next) {
            if (u->Address.lpSockaddr && u->Address.lpSockaddr->sa_family == AF_INET &&
                !netinfo_detail::IsLinkLocal(u->Address.lpSockaddr)) {
                usable = true;
                break;
            }
        }
        if (!usable) continue;

        if (a->FirstGatewayAddress) { pick = a; break; }   // 有默认网关 → 就是它
        if (!fallback) fallback = a;                        // 没网关的留作兜底
    }
    if (!pick) pick = fallback;
    if (!pick) return out;

    for (auto* u = pick->FirstUnicastAddress; u != nullptr; u = u->Next) {
        if (u->Address.lpSockaddr && u->Address.lpSockaddr->sa_family == AF_INET &&
            !netinfo_detail::IsLinkLocal(u->Address.lpSockaddr)) {
            out.ip = netinfo_detail::Ip4Text(u->Address.lpSockaddr);
            break;
        }
    }
    if (out.ip.empty()) return out;

    if (pick->FirstGatewayAddress) {
        out.gateway = netinfo_detail::Ip4Text(pick->FirstGatewayAddress->Address.lpSockaddr);
    }
    if (pick->FriendlyName) out.adapter = pick->FriendlyName;

    // DHCP 租约：GetAdaptersAddresses 不提供，用老的 GetAdaptersInfo 按 AdapterName 对一下。
    // 两个 API 的 AdapterName 是同一个字符串（{GUID}），所以能对上。
    ULONG sz = 0;
    if (::GetAdaptersInfo(nullptr, &sz) == ERROR_BUFFER_OVERFLOW && sz > 0) {
        std::vector<BYTE> buf2((size_t)sz);
        auto* info = reinterpret_cast<IP_ADAPTER_INFO*>(buf2.data());
        if (::GetAdaptersInfo(info, &sz) == ERROR_SUCCESS) {
            for (auto* p = info; p != nullptr; p = p->Next) {
                if (pick->AdapterName && ::lstrcmpA(p->AdapterName, pick->AdapterName) == 0) {
                    out.dhcp         = (p->DhcpEnabled != 0);
                    out.leaseExpires = (unsigned long long)p->LeaseExpires;
                    break;
                }
            }
        }
    }

    out.valid = true;
    return out;
}

// Unix 时间戳 → "2026-10-07 11:53:14"（本地时间）；时间戳为 0 返回空串
inline std::wstring NetLeaseText(unsigned long long unixTs) {
    if (unixTs == 0) return std::wstring();
    time_t t = (time_t)unixTs;
    // 刻意用最普通的 localtime()：
    //   · MSVC 的 localtime_s 是 (tm*, time*)，而 MinGW-w64 的 localtime_s 是
    //     C11 Annex K 那个反过来的签名 (time*, tm*) —— 两边同名不同序，坑；
    //   · localtime_r 在 MinGW 下要开 _POSIX_C_SOURCE 才声明。
    // 这里只在启动时调一次、不并发，所以普通 localtime + 立刻拷贝一份就够。
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable: 4996)      // "localtime 不安全" 的弃用警告：已拷贝，且本处无并发
#endif
    const struct tm* p = ::localtime(&t);
#if defined(_MSC_VER)
#pragma warning(pop)
#endif
    if (p == nullptr) return std::wstring();
    const struct tm tmv = *p;
    wchar_t buf[32];
    ::swprintf(buf, 32, L"%04d-%02d-%02d %02d:%02d:%02d",
               tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
               tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    return std::wstring(buf);
}
