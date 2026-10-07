cmake_minimum_required(VERSION 3.20)

project(TraiectusPhase3Server LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(Traiectus-Server src/main.cpp)

target_compile_definitions(Traiectus-Server PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

if (MSVC)
    target_compile_options(Traiectus-Server PRIVATE /W4 /utf-8)
    target_link_options(Traiectus-Server PRIVATE /SUBSYSTEM:CONSOLE)
else()
    target_compile_options(Traiectus-Server PRIVATE -Wall -Wextra)
endif()

target_link_libraries(Traiectus-Server PRIVATE user32 gdi32 ws2_32 setupapi hid bcrypt iphlpapi)
