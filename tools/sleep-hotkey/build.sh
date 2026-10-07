#!/bin/zsh
# 编译「睡眠热键」小工具（全局热键 → 睡眠），产物在 build/睡眠热键.app
set -e
cd "$(dirname "$0")"

APP="build/睡眠热键.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/SleepHotKey" SleepHotKey.swift \
  -framework Cocoa -framework Carbon

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "（ad-hoc 签名跳过，不影响运行）"

echo "已生成：$(pwd)/$APP"
