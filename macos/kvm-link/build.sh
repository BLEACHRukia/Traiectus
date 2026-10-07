#!/bin/bash
# 编译 kvm-keywatch（事件驱动的键盘归属监听）
set -e
cd "$(dirname "$0")"
clang -O2 -Wall -framework IOKit -framework CoreFoundation -framework CoreGraphics kvm-keywatch.c -o kvm-keywatch
echo "built: $(pwd)/kvm-keywatch"
