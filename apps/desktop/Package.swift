// swift-tools-version: 6.0
// 1Melon 桌面端。
//   MelonCore：不依赖界面的核心逻辑，macOS 和 Linux 都能编译和测试（CI 跑在 Linux 上）
//   MelonApp：SwiftUI 界面与系统集成，只在 macOS 上编译
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MelonCore",
        dependencies: [.product(name: "Crypto", package: "swift-crypto")]
    ),
    .testTarget(
        name: "MelonCoreTests",
        dependencies: ["MelonCore"]
    ),
]
var products: [Product] = [
    .library(name: "MelonCore", targets: ["MelonCore"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "MelonApp", dependencies: ["MelonCore"]))
products.append(.executable(name: "MelonApp", targets: ["MelonApp"]))
#endif

let package = Package(
    name: "1Melon",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        // 在 Apple 平台上直接转发 CryptoKit，在 Linux 上用 BoringSSL 实现同一套 API
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: targets
)
