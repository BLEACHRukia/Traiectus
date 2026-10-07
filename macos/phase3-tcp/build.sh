#!/bin/bash
# ============================================================================
#  Traiectus —— 构建脚本（把 Swift 源码打成 .app）
# ----------------------------------------------------------------------------
#  1) 用 swiftc 编译（-parse-as-library：源码用了 @main）
#  2) 组装标准 .app 目录结构 + Info.plist
#  3) 用本机自签名证书签名（关键：ad-hoc 签名会让每次重新编译都丢失
#     「辅助功能」授权，详见 macos/phase2-cgevent/README.md 第 9 节）
#
#  用法：  ./build.sh
#  需要：  Xcode 或 Command Line Tools（xcode-select --install）
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Traiectus"
APP_DIR="build/${APP_NAME}.app"
SRC_FILES=(src/TraiectusClient.swift src/KeyboardLink.swift src/SleepHotKey.swift
           src/GlobalHotKey.swift
           src/Localization.swift
           src/LoginItem.swift
           src/TraiectusConfig.swift src/KeyboardFrameRules.swift src/PeerDiscovery.swift src/DisplaySwitch.swift
           src/KeyboardDetect.swift
           src/ui/LinkState.swift src/ui/ConnectionDiagram.swift
           src/ui/PanelView.swift src/ui/SettingsView.swift
           src/ui/ShortcutRecorder.swift src/ui/TraiectusApp.swift)
# 签名身份。**换台机器 / 公开版本请先跑 ./make-signing-identity.sh 生成自己的证书**，
# 然后用环境变量覆盖这两个值：
#     TRAIECTUS_SIGN_IDENTITY="你的证书名" TRAIECTUS_SIGN_HASH="证书哈希" ./build.sh
# 找不到证书时会退回 ad-hoc 签名（每次重编都会丢「辅助功能」授权，需重新授权）。
SIGN_IDENTITY="${TRAIECTUS_SIGN_IDENTITY:-Traiectus Dev Code Signing}"
# 钥匙串里可能存在同名旧证书，按名字签名会报 "ambiguous"；哈希是唯一的。
SIGN_HASH="${TRAIECTUS_SIGN_HASH:-FC0D07D3E08682A1BC958643384C0DF374D7286D}"

echo "==> 检查 swiftc"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "没有找到 swiftc。请先安装 Xcode 或命令行工具：xcode-select --install"
    exit 1
fi
swiftc --version | head -1

echo "==> 准备 .app 目录结构"
# 注意：**不要 rm -rf 整个 .app**。整包删掉再建会让 bundle 换 inode，
# 桌面上的 Finder 别名 / LaunchServices 记录 / 图标缓存都可能失效（曾导致
# "桌面图标一直是旧的"）。这里改成原地更新内容，保留 bundle 本身。
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
rm -f "${APP_DIR}/Contents/MacOS/Traiectus"
rm -rf "${APP_DIR}/Contents/Resources/"*

echo "==> 编译 (arm64, macOS 13+)"
MODCACHE="$(pwd)/build/module-cache"
mkdir -p "${MODCACHE}"

compile() {
    # $1 = 额外的 -sdk 参数（可为空）
    # shellcheck disable=SC2086
    swiftc -O \
           -swift-version 5 \
           -parse-as-library \
           -target arm64-apple-macos14.0 \
           -module-cache-path "${MODCACHE}" \
           $1 \
           -o "${APP_DIR}/Contents/MacOS/Traiectus" \
           "${SRC_FILES[@]}"
}

if ! compile "" 2>&1 | tee build/compile.log; then
    if grep -q "SDK is not supported by the compiler" build/compile.log; then
        echo ""
        echo "==> CLT 的 SDK 与编译器小版本不一致，改用影子 SDK 重试"
        ./make-shadow-sdk.sh >/dev/null
        compile "-sdk $(pwd)/build/shadow-sdk"
    else
        echo ""
        echo "❌ 编译失败，完整输出见 build/compile.log"
        exit 1
    fi
fi

echo "==> 写入 Info.plist"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "==> 打包系统弹窗文案（InfoPlist.strings）"
# 「允许访问本地网络」这种系统弹窗里的说明只能靠 .lproj 本地化，而且跟着**系统语言**
# 走（app 内那个语言开关管不到它 —— macOS 的机制如此）。没放 .lproj 的话，
# 走的是 Info.plist 里那句英文默认值。
for lproj in l10n/*.lproj; do
    [ -d "${lproj}" ] || continue
    cp -R "${lproj}" "${APP_DIR}/Contents/Resources/"
    echo "    $(basename "${lproj}")"
done

echo "==> 编译应用图标"
# 优先走官方路径：用 actool 把 AppIcon.icon（Icon Composer 文档）直接编译成
#   Assets.car —— macOS 26/27 认这个（六种外观：默认/深色/透明/着色 由系统原生渲染，
#   不会再被套上"旧格式图标"的玻璃托盘）
#   （2026-09-28 实测：actool 可以直接吃 .icon 文档；之前失败是因为把它塞进了
#     Assets.xcassets/AppIcon.appiconset，actool 会把它当文件读而报 "Is a directory"）
# 失败时回退到仓库里预生成的 AppIcon.icns（由 make-appicon.sh 产生）
ICON_OUT="build/icon-assets"
rm -rf "${ICON_OUT}"; mkdir -p "${ICON_OUT}"
if xcrun actool AppIcon.icon --compile "${ICON_OUT}" --platform macosx \
        --minimum-deployment-target 26.0 --app-icon AppIcon \
        --output-partial-info-plist "${ICON_OUT}/icon-partial.plist" >/dev/null 2>"${ICON_OUT}/actool.log" \
   && [ -f "${ICON_OUT}/Assets.car" ]; then
    # 两个都放：Assets.car 给 macOS 26+（六种外观原生渲染），AppIcon.icns 给老系统
    #   （≤ macOS 25 不认识 .icon/Assets.car，只能读压平的 .icns；没有它老系统会显示
    #    系统的"通用网格图标"）。
    # 代价（已知并接受）：macOS 26+ 上任何走"旧格式图标"路径的消费者（例如桌面上的
    #   Finder 别名）会取 .icns，显示成压平样式；透明样式下看起来偏灰。app 本体
    #   （Finder 窗口 / Dock）仍走 Assets.car，是原生玻璃。
    cp "${ICON_OUT}/Assets.car" "${APP_DIR}/Contents/Resources/Assets.car"
    [ -f "${ICON_OUT}/AppIcon.icns" ] && cp "${ICON_OUT}/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    echo "    Assets.car（26+ 六种外观）+ AppIcon.icns（老系统压平版）"
    else
      echo "    [警告] actool 失败，回退到预生成的 .icns（见 build/icon-assets/actool.log）"
      [ -f AppIcon.icns ] && cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
    fi

echo "==> 打包依赖工具（kvm-keywatch / m1ddc）"
# 让 app 自带依赖：装到 ~/Applications 或任何位置都不再依赖仓库路径
if [ -x ../kvm-link/kvm-keywatch ]; then
    cp ../kvm-link/kvm-keywatch "${APP_DIR}/Contents/Resources/kvm-keywatch"
    chmod +x "${APP_DIR}/Contents/Resources/kvm-keywatch"
    echo "    kvm-keywatch（键盘归属监听）"
else
    echo "    [提示] 未找到 ../kvm-link/kvm-keywatch —— 先跑 macos/kvm-link/build.sh"
fi
if [ -x ../kvm-link/m1ddc/m1ddc ]; then
    cp ../kvm-link/m1ddc/m1ddc "${APP_DIR}/Contents/Resources/m1ddc"
    chmod +x "${APP_DIR}/Contents/Resources/m1ddc"
    echo "    m1ddc（显示器输入源切换）"
else
    echo "    [提示] 未找到 ../kvm-link/m1ddc/m1ddc"
fi

echo "==> 签名（身份：${SIGN_IDENTITY}）"
if ! codesign --force --sign "${SIGN_HASH}" "${APP_DIR}" 2>&1; then
    echo "    [提示] 用哈希签名失败，改试证书名字…"
    if ! codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>&1; then
    echo ""
    echo "    [警告] 找不到 '${SIGN_IDENTITY}'，退回 ad-hoc 签名。"
    echo "    ad-hoc 签名下，每次重新编译都会让「辅助功能」授权失效，需要重新授权一次。"
    codesign --force --sign - "${APP_DIR}"
    fi
fi

echo ""
echo "✅ 构建完成： ${APP_DIR}"
echo ""
echo "运行：            open \"${APP_DIR}\""
echo "授权：            打开后点「请求权限」，或「打开系统设置」→ 隐私与安全性 → 辅助功能"
echo "                  如果列表里没有它，用 + 手动添加： $(pwd)/${APP_DIR}"
echo "局域网权限：      macOS 15 起首次连接内网地址时会弹「允许访问本地网络」，选允许"
