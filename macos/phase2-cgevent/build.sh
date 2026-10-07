#!/bin/bash
# ============================================================================
#  MiniKVM —— 构建脚本（把 Swift 源码打成真正的 .app）
# ----------------------------------------------------------------------------
#  为什么不用 Xcode 工程：手工生成 .xcodeproj 容易出错，而这个脚本只做三件事：
#  1) 用 swiftc 编译（Apple 官方编译器，随 Xcode / Command Line Tools 提供）
#  2) 组装标准 .app 目录结构 + Info.plist
#  3) 做一次 ad-hoc 签名（让「辅助功能」权限能正确绑定到这个 App）
#
#  用法：  ./build.sh
#  需要：  Xcode 或 Command Line Tools（xcode-select --install）
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MiniKVM"
APP_DIR="build/${APP_NAME}.app"
SRC="src/MiniKVMPhase2.swift"

echo "==> 检查 swiftc"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "没有找到 swiftc。请先安装 Xcode 或命令行工具：xcode-select --install"
    exit 1
fi
swiftc --version | head -1

echo "==> 清理旧的构建产物"
rm -rf "${APP_DIR}"

echo "==> 创建 .app 目录结构"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "==> 编译 (arm64, macOS 13+)"
# -swift-version 5：避免 Swift 6 严格并发检查带来的额外报错
# -parse-as-library：源码里用了 @main，必须告诉编译器不要按"顶层代码脚本"处理
swiftc -O \
       -swift-version 5 \
       -parse-as-library \
       -target arm64-apple-macos13.0 \
       -o "${APP_DIR}/Contents/MacOS/MiniKVM" \
       "${SRC}"

echo "==> 写入 Info.plist"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# 用一张本机自签名的代码签名证书签名，而不是 ad-hoc 签名（--sign -）。
# 差别很关键：
#   * ad-hoc 签名的 App 没有任何身份，macOS 只能用"二进制指纹(cdhash)"认它，
#     于是每次重新编译指纹就变，之前授过的「辅助功能」权限立刻作废；
#   * 用证书签名后，App 的"指定要求"变成 identifier + certificate leaf，
#     重新编译不会改变它，权限授权一次即可长期有效。
# 这张证书只存在于本机登录钥匙串里（私钥从不进仓库），首次创建方式见 README 第 9 节。
# 换一台机器或证书被删掉时，脚本会自动退回 ad-hoc 签名。
SIGN_IDENTITY="MiniKVM Dev Code Signing"
echo "==> 签名（身份：${SIGN_IDENTITY}）"
if ! codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>&1; then
    echo ""
    echo "    [警告] 找不到 '${SIGN_IDENTITY}'，退回 ad-hoc 签名。"
    echo "    ad-hoc 签名下，每次重新编译都会让「辅助功能」授权失效，需要重新授权一次。"
    codesign --force --sign - "${APP_DIR}"
fi

echo ""
echo "✅ 构建完成： ${APP_DIR}"
echo ""
echo "运行：            open \"${APP_DIR}\""
echo "授权：            打开后点「请求权限」，或「打开系统设置」→ 隐私与安全性 → 辅助功能"
echo "                  如果列表里没有它，用 + 手动添加： $(pwd)/${APP_DIR}"
