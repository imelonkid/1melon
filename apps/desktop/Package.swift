// swift-tools-version: 6.0
// 1Melon 桌面端。
//   MelonCore：不依赖界面的核心逻辑，macOS 和 Linux 都能编译和测试（CI 跑在 Linux 上）
//   MelonApp：SwiftUI 界面与系统集成，只在 macOS 上编译
import PackageDescription

var targets: [Target] = [
    // Argon2 官方参考实现（C 源码原样拷贝，来源与版本见 Sources/CArgon2/README.md）
    .target(
        name: "CArgon2",
        exclude: ["README.md", "LICENSE"],
        cSettings: [.define("ARGON2_NO_THREADS")]
    ),
    .target(
        name: "MelonCore",
        dependencies: ["CArgon2", .product(name: "Crypto", package: "swift-crypto")]
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
