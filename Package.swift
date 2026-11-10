// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vmapple-cli",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "vmapple-cli", targets: ["vmapple-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(name: "CKVMProbe"),
        .systemLibrary(name: "CTatsu", pkgConfig: "libtatsu-1.0"),
        .target(
            name: "CTicket",
            dependencies: ["CTatsu"]
        ),
        .target(
            name: "VMAppleKit",
            dependencies: ["CKVMProbe", "CTicket", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "vmapple-cli",
            dependencies: [
                "VMAppleKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "VMAppleKitTests", dependencies: ["VMAppleKit"]),
    ]
)
