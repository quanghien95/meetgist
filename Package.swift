// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetgist",
    platforms: [.macOS(.v14)],
    products: [
        // Shared engine used by the CLI and the native app (Xcode project).
        .library(name: "MeetGistKit", targets: ["MeetGistKit"]),
        .executable(name: "meetgist", targets: ["meetgist"]),
    ],
    targets: [
        .target(name: "MeetGistKit"),
        .executableTarget(name: "meetgist", dependencies: ["MeetGistKit"]),
        .testTarget(name: "MeetGistKitTests", dependencies: ["MeetGistKit"]),
    ]
)
