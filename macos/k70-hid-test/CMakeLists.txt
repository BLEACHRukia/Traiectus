cmake_minimum_required(VERSION 3.16)
project(K70HIDTest LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
#  阶段⑤：数据包构造（纯逻辑，无设备访问）
# ---------------------------------------------------------------------------
add_library(k70_report STATIC src/ReportBuilder.cpp)
target_include_directories(k70_report PUBLIC src)

# ---------------------------------------------------------------------------
#  阶段⑥：离线单元测试
#  说明：本阶段刻意**不**添加 main.cpp / K70Device / HidTransport ——
#        设备枚举与写入属于阶段⑦⑧⑨⑩，届时再补。
# ---------------------------------------------------------------------------
add_executable(ReportBuilderTest tests/ReportBuilderTest.cpp)
target_link_libraries(ReportBuilderTest PRIVATE k70_report)

if (MSVC)
    target_compile_options(k70_report PRIVATE /W4)
    target_compile_options(ReportBuilderTest PRIVATE /W4)
else()
    target_compile_options(k70_report PRIVATE -Wall -Wextra -Wpedantic)
    target_compile_options(ReportBuilderTest PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()
add_test(NAME ReportBuilderTest COMMAND ReportBuilderTest)

# ---------------------------------------------------------------------------
#  阶段⑦：hidapi（随仓库固定版本，见 third_party/hidapi/VERSION.txt）
#  只编译 macOS 后端；上游是 C 代码，所以用 C 语言编译。
# ---------------------------------------------------------------------------
set(HIDAPI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/hidapi")

add_library(hidapi STATIC "${HIDAPI_DIR}/mac/hid.c")
target_include_directories(hidapi PUBLIC
    "${HIDAPI_DIR}/hidapi"
    "${HIDAPI_DIR}/mac"
)
target_link_libraries(hidapi PUBLIC "-framework IOKit" "-framework CoreFoundation")

# ---------------------------------------------------------------------------
#  阶段⑦：设备访问层 + CLI（当前只实现 list / info 两个只读命令）
#  注意：没有 dump（阶段⑨）、没有 test-*（阶段⑩）；
#        源码里的 HidTransport::writeOnce() 存在但没有任何命令调用它。
# ---------------------------------------------------------------------------
add_executable(K70HIDTest
    src/main.cpp
    src/HidTransport.cpp
    src/K70Device.cpp
    src/ReportBuilder.cpp
)
target_include_directories(K70HIDTest PRIVATE src)
target_link_libraries(K70HIDTest PRIVATE hidapi)
