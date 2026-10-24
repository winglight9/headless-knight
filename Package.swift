// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeadlessKnightMaster",
    platforms: [.macOS(.v13)],
    products: [
        // 产品名（也就是可执行文件名和 .app 名）故意短的：Finder、活动监视器、
        // 崩溃报告里显示的都是它，`HeadlessKnightMaster` 太长没人念得出来。
        // 模块名保持 HeadlessKnightMaster，改名会牵动所有 @testable import。
        .executable(name: "Knight", targets: ["HeadlessKnightMaster"]),
        .executable(name: "hkm-helper", targets: ["hkm-helper"]),
        .library(name: "HKMKit", targets: ["HKMKit"])
    ],
    targets: [
        .target(
            name: "HKMKit",
            path: "Sources/HKMKit"
        ),
        .executableTarget(
            name: "HeadlessKnightMaster",
            dependencies: ["HKMKit"],
            path: "Sources/HeadlessKnightMaster"
        ),
        .executableTarget(
            name: "hkm-helper",
            dependencies: ["HKMKit"],
            path: "Sources/hkm-helper"
        ),
        .testTarget(
            name: "HeadlessKnightMasterTests",
            dependencies: ["HKMKit", "HeadlessKnightMaster"],
            path: "Tests/HeadlessKnightMasterTests"
        )
    ]
)
