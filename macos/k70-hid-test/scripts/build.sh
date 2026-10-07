#!/bin/bash
# ============================================================================
#  K70HIDTest —— 构建并运行离线单元测试（阶段⑤⑥）
# ----------------------------------------------------------------------------
#  阶段⑤⑥：ReportBuilder + 离线单元测试
#  阶段⑦：设备访问层（枚举/打开/读 descriptor/单次写）+ list/info
#  注意：**没有任何命令会调用 writeOnce()**，本脚本也不发送任何数据。
#
#  用法：  ./scripts/build.sh                构建全部（默认）
#          ./scripts/build.sh reportbuilder  只构建阶段⑤⑥的离线测试
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="${ROOT}/build"
TP="${ROOT}/third_party/hidapi"
mkdir -p "${BUILD_DIR}"

WHAT="${1:-all}"
CXX_BIN="${CXX:-c++}"
CC_BIN="${CC:-cc}"
CXXFLAGS=(-std=c++17 -O2 -Wall -Wextra -Wpedantic)

echo "==> 构建目标：${WHAT}"
echo "    编译器: $(${CXX_BIN} --version | head -1)"
echo

# ---- 阶段⑤⑥：离线单元测试（不涉及设备） ----
echo "==> [⑤⑥] 构建 ReportBuilder + 离线测试"
"${CXX_BIN}" "${CXXFLAGS[@]}" -I "${ROOT}/src" \
    -o "${BUILD_DIR}/ReportBuilderTest" \
    "${ROOT}/src/ReportBuilder.cpp" \
    "${ROOT}/tests/ReportBuilderTest.cpp"

echo "==> [⑤⑥] 运行离线单元测试"
echo
"${BUILD_DIR}/ReportBuilderTest"
echo

if [ "${WHAT}" = "reportbuilder" ]; then
    echo "==> 按参数要求只构建阶段⑤⑥，结束"
    exit 0
fi

# ---- 阶段⑦：设备访问层 + list/info ----
echo "==> [⑦] 编译 hidapi（macOS 后端是 C 代码，必须用 C 编译器）"
"${CC_BIN}" -O2 -Wall -Wextra -I "${TP}/hidapi" -I "${TP}/mac" \
    -c "${TP}/mac/hid.c" -o "${BUILD_DIR}/hidapi_hid.o"

echo "==> [⑦] 编译工具本体"
"${CXX_BIN}" "${CXXFLAGS}" \
    -I "${ROOT}/src" -I "${TP}/hidapi" -I "${TP}/mac" \
    -o "${BUILD_DIR}/K70HIDTest" \
    "${ROOT}/src/ReportBuilder.cpp" \
    "${ROOT}/src/HidTransport.cpp" \
    "${ROOT}/src/K70Device.cpp" \
    "${ROOT}/src/main.cpp" \
    "${BUILD_DIR}/hidapi_hid.o" \
    -framework IOKit -framework CoreFoundation

echo
echo "==> 构建完成"
echo "    ${BUILD_DIR}/ReportBuilderTest   （阶段⑤⑥ 离线测试）"
echo "    ${BUILD_DIR}/K70HIDTest          （阶段⑦ 设备访问层；list / info 为只读）"
echo
echo "    提示：本阶段不提供任何写入命令，K70HIDTest 当前只有 list 与 info。"
