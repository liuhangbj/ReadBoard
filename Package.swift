// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadBoard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ReadBoardContract", targets: ["ReadBoardContract"]),
        .library(name: "ReadBoardCore", targets: ["ReadBoard"]),
        .executable(name: "ReadBoardMain", targets: ["ReadBoardMain"])
    ],
    targets: [
        .target(
            name: "ReadBoardContract",
            path: "Sources/ReadBoardContract"
        ),
        .target(
            name: "ReadBoard",
            dependencies: ["ReadBoardContract"],
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
            dependencies: ["ReadBoard", "ReadBoardContract"],
            path: "Tests/ReadBoardTests"
        ),
        .testTarget(
            name: "ReadBoardContractTests",
            dependencies: ["ReadBoardContract"],
            path: "Tests/ReadBoardContractTests"
        )
    ]
)
