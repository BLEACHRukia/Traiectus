#!/bin/bash
# ============================================================================
#  install-app.sh —— 按 macOS 惯例安装 Traiectus
# ----------------------------------------------------------------------------
#  做两件事（都是 macOS 上"常驻菜单栏工具"的标准姿势）：
#    ① 把 build/Traiectus.app 安装（或原地更新）到 ~/Applications
#    ② 重新签名（保持自签证书身份，辅助功能授权不会掉）
#
#  开机自启不在这里做了 —— 改由 app 自己用系统的 SMAppService 注册
#  （第一次启动时默认打开，能在「系统设置 → 通用 → 登录项」里关）。
#  这样"直接拖 .app 进应用程序"的用户也有自启，不再只有跑过这个脚本的人才有。
#  这里只负责把**老版本留下的 LaunchAgent 清掉**，免得两套自启并存。
#
#  用法：
#     ./install-app.sh          安装 / 更新
#     ./install-app.sh remove   卸载（移除登录项 + 已安装的副本）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Traiectus"
SRC="build/Traiectus.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/${APP_NAME}.app"
AGENT="$HOME/Library/LaunchAgents/com.traiectus.client.plist"
LABEL="com.traiectus.client"
# 改名前的旧东西（安装时顺手清掉，避免两套并存）
OLD_AGENT="$HOME/Library/LaunchAgents/com.minikvm.client.plist"
OLD_LABEL="com.minikvm.client"
OLD_DEST="$DEST_DIR/MiniKVM Client.app"
# 与 build.sh 一致：可用环境变量覆盖成你自己的证书
SIGN_HASH="${TRAIECTUS_SIGN_HASH:-FC0D07D3E08682A1BC958643384C0DF374D7286D}"
SIGN_NAME="${TRAIECTUS_SIGN_IDENTITY:-Traiectus Dev Code Signing}"

if [ "${1:-install}" = "remove" ]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    rm -rf "$DEST"
    echo "✅ 已卸载：$DEST（老的 LaunchAgent 登录项也清掉了）"
    echo "   如果「系统设置 → 通用 → 登录项」里还留着 Traiectus，在那儿删掉即可。"
    exit 0
fi

[ -d "$SRC" ] || { echo "找不到 $SRC —— 请先运行 ./build.sh"; exit 1; }

echo "==> 清理改名前的旧安装（如果有）"
launchctl bootout "gui/$UID/$OLD_LABEL" 2>/dev/null || true
rm -f "$OLD_AGENT"
[ -d "$OLD_DEST" ] && rm -rf "$OLD_DEST" && echo "    已移除旧 app：$OLD_DEST"

echo "==> 清理老的 LaunchAgent 登录项（自启已改由 app 自己注册）"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
[ -f "$AGENT" ] && rm -f "$AGENT" && echo "    已移除：$AGENT"

echo "==> 安装到 ${DEST}"

mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
# 原地更新（不整包删），保持 bundle inode 稳定：图标缓存 / LaunchServices / 别名都不会失效
rm -f "$DEST/Contents/MacOS/MiniKVMClient" "$DEST/Contents/MacOS/Traiectus"
rm -rf "$DEST/Contents/Resources/"*
ditto "$SRC/Contents/MacOS" "$DEST/Contents/MacOS"
ditto "$SRC/Contents/Resources" "$DEST/Contents/Resources"
cp "$SRC/Contents/Info.plist" "$DEST/Contents/Info.plist"

echo "==> 重新签名（身份：${SIGN_NAME}）"
codesign --force --sign "$SIGN_HASH" "$DEST" 2>/dev/null \
  || codesign --force --sign "$SIGN_NAME" "$DEST" 2>/dev/null \
  || codesign --force --sign - "$DEST"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" || true

echo ""
echo "✅ 完成"
echo "   已安装：$DEST"
echo "   开机自启：app 第一次启动时会自己登记（默认开，可在「系统设置 → 通用 → 登录项」里关）"
echo "   卸载：  ./install-app.sh remove"
