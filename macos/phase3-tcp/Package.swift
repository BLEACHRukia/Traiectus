// swift-tools-version: 5.9
// ============================================================================
//  Traiectus —— 给 Xcode 用的 SwiftPM 包（只为"实时预览 UI"服务）
// ----------------------------------------------------------------------------
//  为什么要有它：
//    · 正式产物仍然由 ./build.sh 生成（带 Info.plist、LSUIElement、代码签名）
//    · 这个包让 Xcode 能直接打开同一个 src/ 目录 —— 于是可以：
//        ① SwiftUI 实时预览（改一行、右边立刻变）
//        ② 在 Xcode 里跑、加断点、看视图层级
//    两者用的是**同一份源码**，不会出现两套代码打架。
//
//  用法：Xcode → File → Open… → 选这个目录（含 Package.swift）→ 打开
//        （首次会解析包，几秒钟）
//
//  注意：这里**只声明库目标**，故意不声明可执行目标。
//    ① 可执行目标在 SwiftPM 包里不能开预览（ENABLE_DEBUG_DYLIB 改不了），
//       而 Xcode 默认会选它 → 每次重启 Xcode 都要手动切 scheme，很烦。
//    ② 真正的 app 由 build.sh 用 swiftc 编译（带 Info.plist / 签名 / 图标），
//       本来就不走这个包。
//  去掉之后 Xcode 只剩 TraiectusKit 一个 scheme，预览开箱即用。
// ============================================================================

import PackageDescription

let package = Package(
    name: "Traiectus",
    platforms: [.macOS(.v14)],
    // 只有一个产物：预览用 TraiectusKit 这个 scheme。
    products: [
        .library(name: "TraiectusKit", targets: ["TraiectusKit"]),
    ],
    targets: [
        // 全部源码（含 UI）都在这个库目标里 —— Xcode 的 SwiftUI 预览直接可用
        .target(
            name: "TraiectusKit",
            path: "src",
            exclude: ["ui/TraiectusApp.swift"]
        ),
    ]
)
