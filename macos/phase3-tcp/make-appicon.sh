#!/bin/bash
# ============================================================================
#  make-appicon.sh —— 从 AppIcon.icon（Icon Composer 文档）生成 AppIcon.icns
# ----------------------------------------------------------------------------
#  AppIcon.icon 是 macOS 26/27 的官方图标源文件（Liquid Glass 分图层 + 材质），
#  由 Icon Composer 生成/编辑；本脚本用 ictool 导出各档位 PNG，再用系统 iconutil
#  打包成 .icns 放进 app。
#
#  说明：.icns 只会被系统当作"默认外观"使用；要六种外观（深色/透明/着色）跟着
#  系统设置自动切换，需要在 Xcode 工程里把 AppIcon.icon 放进资源目录由 actool 编译。
#
#  用法： ./make-appicon.sh          （需要已装 Xcode，ictool 在 Xcode 里）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ICT" ] || { echo "找不到 ictool：$ICT（需要 Xcode）"; exit 1; }
[ -d AppIcon.icon ] || { echo "找不到 AppIcon.icon"; exit 1; }

SET="build/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"

# ictool 需要沙箱外权限（在受限环境里会报 "The file … couldn't be opened"）
for s in 16 32 64 128 256 512 1024; do
    "$ICT" AppIcon.icon --export-image --output-file "$SET/tmp-$s.png" \
        --platform macOS --rendition Default --width "$s" --height "$s" --scale 1 \
        --design-generation 27 >/dev/null
done

cp "$SET/tmp-16.png"   "$SET/icon_16x16.png";      cp "$SET/tmp-32.png"  "$SET/icon_16x16@2x.png"
cp "$SET/tmp-32.png"   "$SET/icon_32x32.png";      cp "$SET/tmp-64.png"  "$SET/icon_32x32@2x.png"
cp "$SET/tmp-128.png"  "$SET/icon_128x128.png";    cp "$SET/tmp-256.png" "$SET/icon_128x128@2x.png"
cp "$SET/tmp-256.png"  "$SET/icon_256x256.png";    cp "$SET/tmp-512.png" "$SET/icon_256x256@2x.png"
cp "$SET/tmp-512.png"  "$SET/icon_512x512.png";    cp "$SET/tmp-1024.png" "$SET/icon_512x512@2x.png"
rm -f "$SET"/tmp-*.png

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "✅ 生成 AppIcon.icns（$(stat -f '%z' AppIcon.icns) bytes）"
