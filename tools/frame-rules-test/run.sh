#!/bin/zsh
# ============================================================================
#  跑键盘状态帧规则的离线测试
#  不需要键盘、不需要设备、不联网；只编译一个纯函数文件 + 测试主体
# ============================================================================
set -e
cd "$(dirname "$0")"

RULES="../../macos/phase3-tcp/src/KeyboardFrameRules.swift"
CONFIG="../../macos/phase3-tcp/src/TraiectusConfig.swift"
[ -f "$RULES" ] || { echo "找不到 $RULES"; exit 1; }
[ -f "$CONFIG" ] || { echo "找不到 $CONFIG"; exit 1; }

command -v swiftc >/dev/null 2>&1 || { echo "需要 swiftc（Xcode 或命令行工具）"; exit 1; }

mkdir -p build
swiftc -O -module-cache-path build/mc -o build/rulesTest main.swift "$RULES" "$CONFIG"
./build/rulesTest
