// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TriSyncPkg",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TriSync",
            path: "Sources/TriSync"
        ),
        .testTarget(
            name: "TriSyncTests",
            dependencies: ["TriSync"],
            path: "Tests/TriSyncTests"
        )
    ]
)
