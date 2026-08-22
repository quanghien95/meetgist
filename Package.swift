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
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
    ],
    targets: [
        .target(
            name: "MeetGistKit",
            resources: [.copy("Resources/offline_worker.py"),
                        .copy("Resources/offline-requirements.lock"),
                        .copy("Resources/qwen_notes_worker.py"),
                        .copy("Resources/qwen-notes-requirements.lock")]
        ),
        .executableTarget(name: "meetgist", dependencies: ["MeetGistKit"]),
        // SwiftUI app sources live in app/Sources and are the source of truth for
        // BOTH this SPM target (headless compile-check: `swift build`) and the real
        // Xcode app (app/project.yml → MeetGist.xcodeproj, which adds the bundle,
        // app icon, entitlements). KeyboardShortcuts powers the global hotkey.
        .executableTarget(
            name: "MeetGistApp",
            dependencies: [
                "MeetGistKit",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "app/Sources"
        ),
        .testTarget(
            name: "MeetGistKitTests",
            dependencies: ["MeetGistKit"],
            path: "tests/MeetGistKitTests"
        ),
    ]
)
