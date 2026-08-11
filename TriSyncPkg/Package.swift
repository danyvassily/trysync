// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TriSyncPkg",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "TriSyncCore",
            targets: ["TriSyncCore"]
        ),
        .executable(
            name: "TriSync",
            targets: ["TriSync"]
        )
    ],
    targets: [
        .target(
            name: "TriSyncCore",
            path: "Sources/TriSyncCore"
        ),
        .executableTarget(
            name: "TriSync",
            dependencies: ["TriSyncCore"],
            path: "Sources/TriSync"
        ),
        .testTarget(
            name: "TriSyncCoreTests",
            dependencies: ["TriSyncCore"],
            path: "Tests/TriSyncCoreTests"
        )
    ]
)
