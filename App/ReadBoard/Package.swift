// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReadBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReadBoard",
            path: "Sources/ReadBoard"
        )
    ]
)
