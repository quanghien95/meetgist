// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetgist",
    platforms: [.macOS(.v14)],
    products: [
        // Shared engine used by the CLI and the native app.
        .library(name: "MeetGistKit", targets: ["MeetGistKit"]),
        .executable(name: "meetgist", targets: ["meetgist"]),
        .executable(name: "MeetGistApp", targets: ["MeetGistApp"]),
    ],
    targets: [
        .target(name: "MeetGistKit"),
        .executableTarget(name: "meetgist", dependencies: ["MeetGistKit"]),
        // The native SwiftUI app. Open Package.swift in Xcode and run the
        // "MeetGistApp" scheme. The Info.plist (bundle id + usage strings) is
        // embedded into the binary so Microphone/Screen-Recording prompts work.
        .executableTarget(
            name: "MeetGistApp",
            dependencies: ["MeetGistKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MeetGistApp/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "MeetGistKitTests", dependencies: ["MeetGistKit"]),
    ]
)
