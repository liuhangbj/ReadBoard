// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ReadBoard",
            path: "Sources/ReadBoard",
            resources: [
                .copy("Resources/migrations"),
                .copy("Resources/engine")
            ]
        ),
        .executableTarget(
            name: "ReadBoardMain",
            dependencies: ["ReadBoard"],
            path: "Sources/ReadBoardMain"
        ),
        .testTarget(
            name: "ReadBoardTests",
            dependencies: ["ReadBoard"],
            path: "Tests/ReadBoardTests"
        )
    ]
)
