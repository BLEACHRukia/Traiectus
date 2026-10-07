// ============================================================================
//  kvm-keywatch —— 键盘归属事件监听（Mac 侧，事件驱动，不轮询）
// ----------------------------------------------------------------------------
//  为什么需要它：早期脚本原来用"每 0.5 秒跑一次 hidutil list"来判断键盘
//  在不在 Mac 上，最快也要 0.5 秒才可能发现变化。这个工具改成订阅 IOKit 的
//  设备接入/移除通知 —— 键盘一走，回调立刻触发，检测延迟降到毫秒级。
//
//  输出（一行一个事件，立即 flush，便于管道实时读取）：
//      <epoch 秒.毫秒> ADD    <transport> | <product>
//      <epoch 秒.毫秒> REMOVE <transport> | <product>
//  其中 transport 为 "USB"（有线插在 Mac）或 "Bluetooth Low Energy"（蓝牙）。
//
//  只读：只订阅通知，不打开设备、不发送任何数据。
//
//  用法：
//      kvm-keywatch            打开 IOHIDManager + 订阅设备接入/移除事件
//      kvm-keywatch --center   把光标移到主屏中心后退出
//      kvm-keywatch --vid 0x1B1C   监听别的厂商 ID（默认 0x1b1c = Corsair）
//
//  编译：clang -O2 -framework IOKit -framework CoreFoundation kvm-keywatch.c -o kvm-keywatch
// ============================================================================

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WATCH_VID 0x1b1c

static double now_epoch(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void emit(const char *kind, IOHIDDeviceRef dev) {
    char tbuf[64] = "?";
    char pbuf[160] = "?";
    CFTypeRef tr = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey));
    CFTypeRef pr = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    if (tr && CFGetTypeID(tr) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)tr, tbuf, sizeof tbuf, kCFStringEncodingUTF8);
    if (pr && CFGetTypeID(pr) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)pr, pbuf, sizeof pbuf, kCFStringEncodingUTF8);
    printf("%.3f %s %s | %s\n", now_epoch(), kind, tbuf, pbuf);
    fflush(stdout);
}

static void on_add(void *ctx, IOReturn res, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)res; (void)sender;
    emit("ADD", dev);
}

static void on_remove(void *ctx, IOReturn res, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)res; (void)sender;
    emit("REMOVE", dev);
}

// 显示器接入/移除事件：用来量"切屏命令发出"到"画面真的换了"之间显示器自己的耗时
static void on_display(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    (void)userInfo;
    printf("%.3f DISPLAY id=%u flags=0x%x%s%s%s%s\n",
           now_epoch(), (unsigned)display, (unsigned)flags,
           (flags & kCGDisplayAddFlag)    ? " ADD"    : "",
           (flags & kCGDisplayRemoveFlag) ? " REMOVE" : "",
           (flags & kCGDisplaySetModeFlag)? " SETMODE": "",
           (flags & kCGDisplayBeginConfigurationFlag) ? " BEGIN" : "");
    fflush(stdout);
}

// 把 Mac 自己的光标移到主屏中心（切换时调用，让两边位置对称）
static int center_cursor(void) {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    CGPoint p = CGPointMake(b.origin.x + b.size.width / 2.0,
                            b.origin.y + b.size.height / 2.0);

    // 打印所有显示器（排查"光标跑到看不见的地方"这类问题）
    CGDirectDisplayID ids[8];
    uint32_t cnt = 0;
    if (CGGetOnlineDisplayList(8, ids, &cnt) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < cnt; i++) {
            CGRect db = CGDisplayBounds(ids[i]);
            printf("display ids=%u bounds=(%.0f,%.0f %.0fx%.0f) main=%d active=%d\n",
                   (unsigned)ids[i], db.origin.x, db.origin.y, db.size.width, db.size.height,
                   CGDisplayIsMain(ids[i]) ? 1 : 0, CGDisplayIsActive(ids[i]) ? 1 : 0);
        }
    }

    CGError err = CGWarpMouseCursorPosition(p);
    // ★ 关键：warp 会把"光标"和"鼠标"解绑（macOS 的已知行为）。
    //   不补这一句，光标会卡在原地/看起来不动，即使事件在正常注入。
    CGAssociateMouseAndMouseCursorPosition(1);
    printf("center cursor -> (%.0f, %.0f)  CGError=%d  (re-associated with mouse)\n",
           p.x, p.y, (int)err);
    return err == kCGErrorSuccess ? 0 : 1;
}

int main(int argc, char **argv) {
    int vid = WATCH_VID;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--center") == 0) {
            return center_cursor();
        }
        if (strcmp(argv[i], "--vid") == 0 && i + 1 < argc) {
            // 接受 0x1B1C / 0x1b1c / 7092 三种写法；认不出来就退回默认值
            char *end = NULL;
            long parsed = strtol(argv[i + 1], &end, 0);
            if (end != argv[i + 1] && parsed > 0 && parsed <= 0xFFFF) {
                vid = (int)parsed;
            } else {
                fprintf(stderr, "无法解析 --vid %s，改用默认 0x%04x\n", argv[i + 1], WATCH_VID);
            }
            i++;
        }
    }

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!mgr) {
        fprintf(stderr, "IOHIDManagerCreate failed\n");
        return 1;
    }

    CFNumberRef vidRef = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    const void *keys[] = { CFSTR(kIOHIDVendorIDKey) };
    const void *vals[] = { vidRef };
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, vals, 1,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, matching);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_add, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, on_remove, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CGDisplayRegisterReconfigurationCallback(on_display, NULL);
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("# keywatch watching VID 0x%04x (IOHIDManagerOpen=%d)\n", vid, (int)r);
    fflush(stdout);

    CFRunLoopRun();
    return 0;
}
