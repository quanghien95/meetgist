// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import CryptoKit

public enum OfflineRuntimeState: Equatable, Sendable {
    case notInstalled
    case installing
    case ready
    case failed(String)
}

@MainActor
public final class OfflineRuntimeManager: ObservableObject {
    public static let pythonVersion = "3.11.16"
    public static let pythonBuild = "20260814"
    public static let mlxWhisperVersion = "0.4.3"
    public static let mlxVersion = "0.32.1"
    public static let modelRevision = "49e6aa286ad60c14352c404340ded53710378a11"
    /// Total repository file bytes at the pinned model revision. Settings rounds
    /// this using decimal units; the Python runtime and packages are additional.
    public static let modelDownloadBytes: Int64 = 3_083_522_487
    public static let pythonArchiveSHA256 = "fcba9f3f676c83e07225e38116649f0c6eb94cb4fcc166632cf92769462b6e39"
    public static var isSupported: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    @Published public private(set) var state: OfflineRuntimeState = .notInstalled
    @Published public private(set) var installProgress: Double = 0
    @Published public private(set) var installDetail = ""

    public let root: URL
    public var pythonURL: URL { root.appendingPathComponent("python/bin/python3") }
    public var modelURL: URL { root.appendingPathComponent("model", isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent("ready.json") }

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            self.root = support.appendingPathComponent("MeetGist/OfflineWhisper/v1", isDirectory: true)
        }
        refresh()
    }

    public func refresh() {
        guard Self.isSupported else {
            state = .notInstalled
            return
        }
        let fm = FileManager.default
        state = fm.isExecutableFile(atPath: pythonURL.path)
            && fm.fileExists(atPath: modelURL.appendingPathComponent("weights.npz").path)
            && fm.fileExists(atPath: markerURL.path) ? .ready : .notInstalled
    }

    public func install() async {
        guard state != .installing else { return }
        state = .installing
        installProgress = 0.02
        installDetail = "Preparing local runtime…"
        do {
#if !arch(arm64)
            throw RuntimeError("Offline Whisper v1 supports Apple Silicon Macs only.")
#else
            let fm = FileManager.default
            try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            installDetail = "Downloading CPython \(Self.pythonVersion)…"
            let archiveURL = URL(string:
                "https://github.com/astral-sh/python-build-standalone/releases/download/\(Self.pythonBuild)/cpython-\(Self.pythonVersion)%2B\(Self.pythonBuild)-aarch64-apple-darwin-install_only.tar.gz")!
            let (downloaded, response) = try await URLSession.shared.download(from: archiveURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw RuntimeError("CPython download failed.")
            }
            let archive = root.appendingPathComponent("python.tar.gz")
            try fm.moveItem(at: downloaded, to: archive)
            let digest = SHA256.hash(data: try Data(contentsOf: archive))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == Self.pythonArchiveSHA256 else {
                throw RuntimeError("The CPython download failed its SHA-256 check.")
            }
            installProgress = 0.16
            try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", root.path])
            try? fm.removeItem(at: archive)
            guard fm.isExecutableFile(atPath: pythonURL.path) else {
                throw RuntimeError("The pinned CPython archive did not contain python/bin/python3.")
            }

            installDetail = "Installing MLX Whisper \(Self.mlxWhisperVersion)…"
            installProgress = 0.25
            guard let requirements = Bundle.module.url(forResource: "offline-requirements", withExtension: "lock") else {
                throw RuntimeError("Bundled offline requirements are missing.")
            }
            try await run(pythonURL.path, ["-m", "pip", "install", "--disable-pip-version-check",
                                           "--no-input", "-r", requirements.path])

            installDetail = "Downloading MLX Whisper Large V3…"
            installProgress = 0.62
            let script = """
            import sys
            from huggingface_hub import snapshot_download
            snapshot_download(repo_id='mlx-community/whisper-large-v3-mlx', revision='\(Self.modelRevision)', local_dir=sys.argv[1])
            """
            try await run(pythonURL.path, ["-c", script, modelURL.path])

            let marker: [String: String] = [
                "python": Self.pythonVersion,
                "python_build": Self.pythonBuild,
                "mlx_whisper": Self.mlxWhisperVersion,
                "mlx": Self.mlxVersion,
                "model": "mlx-community/whisper-large-v3-mlx",
                "model_revision": Self.modelRevision,
            ]
            let markerData = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            try markerData.write(to: markerURL, options: .atomic)
            installProgress = 1
            installDetail = "MLX Whisper Large V3 is ready."
            state = .ready
#endif
        } catch {
            state = .failed(error.localizedDescription)
            installDetail = error.localizedDescription
        }
    }

    /// Removes only the app-owned interpreter and model cache.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        installProgress = 0
        installDetail = ""
        state = .notInstalled
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let logURL = root.appendingPathComponent("install.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try log.close()
        guard status == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").suffix(8).joined(separator: "\n")
            throw RuntimeError(tail ?? "Runtime setup command failed (\(status)).")
        }
    }
}

private struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
