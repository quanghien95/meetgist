// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetgist",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "meetgist")
    ]
)
