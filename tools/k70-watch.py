#!/usr/bin/env python3
# ============================================================================
#  K70 Pro Mini 蓝牙连接监视器（macOS 侧，只读）
# ----------------------------------------------------------------------------
#  用途：验证"用软件命令把键盘切到蓝牙"是否真的生效。
#
#  为什么需要它：键盘切到蓝牙是**蓝牙层**的事，Mac 上只能通过"这个 HID 设备
#  有没有出现"来判断。靠人去打字试有两个问题：看不出时间点、也看不出它
#  到底有没有断过重连。这个脚本每秒看一次，把出现/消失的时刻打出来。
#
#  它做的事：轮询 `hidutil list`，检查有没有 Corsair（VID 0x1b1c）设备以
#  「Bluetooth Low Energy」方式呈现。纯只读，不打开设备、不发任何命令。
#
#  用法：
#      python3 tools/k70-watch.py            # 默认监视 300 秒
#      python3 tools/k70-watch.py 60         # 监视 60 秒
# ============================================================================

import subprocess
import sys
import time

VID_TOKEN = "0x1b1c"
BT_TOKEN = "Bluetooth Low Energy"


def k70_over_bluetooth() -> bool:
    """当前是否有 Corsair 设备以蓝牙方式挂在系统上。"""
    try:
        out = subprocess.run(["hidutil", "list"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return False
    for line in out.splitlines():
        low = line.lower()
        if VID_TOKEN in low and BT_TOKEN.lower() in low:
            return True
    return False


def main() -> int:
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
    started = time.time()
    state = k70_over_bluetooth()

    def stamp() -> str:
        t = time.time()
        return time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d}"

    print(f"[{stamp()}] 开始监视 K70 的蓝牙连接（{duration:.0f} 秒）")
    print(f"[{stamp()}] 当前状态：{'已连接（蓝牙）' if state else '未以蓝牙方式连接'}")
    print("     （期间只要它出现或消失，都会立刻打印一行）")
    print()

    while time.time() - started < duration:
        time.sleep(1.0)
        now = k70_over_bluetooth()
        if now != state:
            state = now
            if now:
                print(f"[{stamp()}] ✅ K70 以蓝牙方式出现（键盘已切到本机）")
            else:
                print(f"[{stamp()}] ⛔ K70 从蓝牙上消失（键盘已切走或断开）")
            sys.stdout.flush()

    print()
    print(f"[{stamp()}] 监视结束，最终状态：{'已连接（蓝牙）' if state else '未以蓝牙方式连接'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
