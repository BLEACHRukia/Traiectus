#!/bin/bash
# ============================================================================
#  构造"影子 SDK"：绕过 CLT 里 SDK 与编译器小版本不一致的问题
# ----------------------------------------------------------------------------
#  症状：swiftc 报
#      error: failed to build module 'Swift'; this SDK is not supported by the
#      compiler (the SDK is built with '... 6.4.0.31.4 ...', while this compiler
#      is '... 6.4.0.34.1 ...')
#  原因：Command Line Tools 自带的 SDK 里的 Swift 预编译接口，是用**稍早一点**
#        的同版本编译器构建的；swiftc 对这个版本号做严格比对就直接拒绝。
#        两者其实是同一个 Swift 6.x，接口本身兼容。
#  做法：把 SDK 用符号链接"影子化"到本地，只把 Swift 核心模块的接口文本复制一份，
#        并把里面的版本号改成当前编译器的版本，然后用 -sdk 指向这份影子 SDK。
#
#  只写在工作区里，不动系统文件。
#  用法：  ./make-shadow-sdk.sh [输出目录]     默认 build/shadow-sdk
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:-$(pwd)/build/shadow-sdk}"
REAL="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"

if [ ! -d "$REAL" ]; then
    echo "[错误] 找不到 $REAL"
    exit 1
fi

ver_line="$(swiftc --version | head -1)"
toolchain_ver="$(printf '%s' "$ver_line" | sed -n 's/.*swiftlang-\([0-9.]*\).*/\1/p')"
clang_ver="$(printf '%s' "$ver_line" | sed -n 's/.*clang-\([0-9.]*\).*/\1/p')"
if [ -z "$toolchain_ver" ] || [ -z "$clang_ver" ]; then
    echo "[错误] 无法从 swiftc --version 解析版本：$ver_line"
    exit 1
fi
echo "当前编译器：swiftlang-$toolchain_ver  clang-$clang_ver"

rm -rf "$OUT"
mkdir -p "$OUT/usr/lib/swift"

# 顶层：除了 usr 全部软链
for e in "$REAL"/*; do
    b="$(basename "$e")"
    [ "$b" = "usr" ] && continue
    ln -s "$e" "$OUT/$b"
done
# usr：除了 lib 全部软链
for e in "$REAL"/usr/*; do
    b="$(basename "$e")"
    [ "$b" = "lib" ] && continue
    ln -s "$e" "$OUT/usr/$b"
done
# usr/lib：除了 swift 全部软链
for e in "$REAL"/usr/lib/*; do
    b="$(basename "$e")"
    [ "$b" = "swift" ] && continue
    ln -s "$e" "$OUT/usr/lib/$b"
done
# usr/lib/swift：除了 Swift.swiftmodule 全部软链
for e in "$REAL"/usr/lib/swift/*; do
    b="$(basename "$e")"
    [ "$b" = "Swift.swiftmodule" ] && continue
    ln -s "$e" "$OUT/usr/lib/swift/$b"
done

# Swift 核心模块：复制一份，改掉版本号
cp -R "$REAL/usr/lib/swift/Swift.swiftmodule" "$OUT/usr/lib/swift/Swift.swiftmodule"
for f in "$OUT/usr/lib/swift/Swift.swiftmodule/"*.swiftinterface; do
    sed -i '' \
        -e "s/swiftlang-[0-9.]*/swiftlang-$toolchain_ver/g" \
        -e "s/clang-[0-9.]*/clang-$clang_ver/g" \
        -e "s/-user-module-version [0-9.]*/-user-module-version $toolchain_ver/g" \
        "$f"
done

echo "影子 SDK 就绪：$OUT"
echo "（用 -sdk \"$OUT\" 编译即可绕过版本检查）"
