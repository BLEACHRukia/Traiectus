#!/bin/bash
# ============================================================================
#  显示器双向切换测试（双击运行）
# ----------------------------------------------------------------------------
#  要回答的问题只有一个：
#     屏幕切到 Windows 的 DP 之后，Mac 还能不能跟显示器说话（DDC/CI 是否还在）？
#
#  * 能  -> Mac 一个人就能管两个方向，Windows 端不需要改任何东西
#  * 不能 -> 确认分工：Mac 负责切出去，Windows 负责切回来（已验证可行）
#
#  为什么必须由你双击：Codex 的执行环境被沙箱限制，看不到显示器
#  （CoreGraphics / system_profiler / dwc 在那边一律报 0 个显示器），
#  而你终端里的 dwc 不受此限制。
#
#  安全：只写显示器输入源 VCP 0x60，不碰其它设置。
# ============================================================================

cd "$HOME/Downloads/CLI_macOS" || { echo "找不到 ~/Downloads/CLI_macOS"; sleep 20; exit 1; }

OUT="$HOME/Desktop/mon-test-result.txt"
LOG="$(mktemp /tmp/mon-test.XXXXXX)"

{
  echo "==== 显示器双向切换测试 ===="
  date "+时间: %Y-%m-%d %H:%M:%S"
  echo
  echo "--- 1) 当前输入源（此刻屏幕应当显示 Mac，即 HDMI=17）---"
  ./dwc get InputSource
  echo
  echo "--- 2) 切到 DP(15) = Windows ---"
  ./dwc set InputSource 15
  echo "（等 6 秒，让显示器完成切换）"
  sleep 6
  echo
  echo "--- 3) 关键一步：屏幕现在在 Windows 上，再读一次 ---"
  ./dwc list
  echo "  get InputSource:"
  ./dwc get InputSource
  echo
  echo "--- 4) 切回 HDMI(17) = Mac ---"
  ./dwc set InputSource 17
  echo
  echo "==== done ===="
} > "$LOG" 2>&1

cp "$LOG" "$OUT"
cat "$LOG"
echo
echo "结果文件：$OUT"
echo "（这个窗口 40 秒后自动关闭，也可以点右上角 X）"
sleep 40
