// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OsmoSyncCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OsmoSyncCore", targets: ["OsmoSyncCore"]),
    ],
    targets: [
        .target(name: "OsmoSyncCore"),
        .testTarget(name: "OsmoSyncCoreTests", dependencies: ["OsmoSyncCore"]),
    ]
)
