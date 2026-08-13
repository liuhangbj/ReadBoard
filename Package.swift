// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadBoard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ReadBoardContract", targets: ["ReadBoardContract"]),
        .library(name: "ReadBoardRemote", targets: ["ReadBoardRemote"]),
        .library(name: "ReadBoardUI", targets: ["ReadBoardUI"]),
        .library(name: "ReadBoardFeatures", targets: ["ReadBoardFeatures"]),
        .library(name: "ReadBoardShareExtensionKit", targets: ["ReadBoardShareExtensionKit"]),
        .library(name: "ReadBoardCore", targets: ["ReadBoard"]),
        .executable(name: "ReadBoardMain", targets: ["ReadBoardMain"])
    ],
    targets: [
        .target(
            name: "ReadBoardContract",
            path: "Sources/ReadBoardContract"
        ),
        .target(
            name: "ReadBoardRemote",
            dependencies: ["ReadBoardContract"],
            path: "Sources/ReadBoardRemote"
        ),
        .target(
            name: "ReadBoardUI",
            dependencies: ["ReadBoardContract"],
            path: "Sources/ReadBoardUI"
        ),
        .target(
            name: "ReadBoardFeatures",
            dependencies: ["ReadBoardContract", "ReadBoardUI"],
            path: "Sources/ReadBoardFeatures"
        ),
        .target(
            name: "ReadBoardShareExtensionKit",
            path: "Sources/ReadBoardShareExtension"
        ),
        .target(
            name: "ReadBoard",
            dependencies: ["ReadBoardContract", "ReadBoardUI", "ReadBoardFeatures"],
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
            dependencies: ["ReadBoard", "ReadBoardContract", "ReadBoardFeatures"],
            path: "Tests/ReadBoardTests"
        ),
        .testTarget(
            name: "ReadBoardContractTests",
            dependencies: ["ReadBoardContract"],
            path: "Tests/ReadBoardContractTests"
        ),
        .testTarget(
            name: "ReadBoardUITests",
            dependencies: ["ReadBoardUI", "ReadBoardContract"],
            path: "Tests/ReadBoardUITests"
        ),
        .testTarget(
            name: "ReadBoardFeaturesTests",
            dependencies: ["ReadBoardFeatures", "ReadBoardContract"],
            path: "Tests/ReadBoardFeaturesTests"
        )
    ]
)
