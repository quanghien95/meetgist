// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import CryptoKit

public enum LocalNotesRuntimeState: Equatable, Sendable {
    case notInstalled
    case installing
    case ready
    case failed(String)
}

/// Owns the Python/MLX-LM runtime and Qwen model used only by the Notes slot.
/// It intentionally does not share files or lifecycle with Local Whisper.
@MainActor
public final class LocalNotesRuntimeManager: ObservableObject {
    public static let pythonVersion = "3.11.16"
    public static let pythonBuild = "20260814"
    public static let mlxLMVersion = "0.31.3"
    public static let mlxVersion = "0.32.1"
    public static let modelID = "mlx-community/Qwen3-8B-4bit"
    public static let modelRevision = "545dc4251c05440727734bcd94334791f6ab0192"
    public static let modelDownloadBytes: Int64 = 4_620_000_000
    public static let pythonArchiveSHA256 = "fcba9f3f676c83e07225e38116649f0c6eb94cb4fcc166632cf92769462b6e39"

    public static var isSupported: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    @Published public private(set) var state: LocalNotesRuntimeState = .notInstalled
    @Published public private(set) var installProgress: Double = 0
    @Published public private(set) var installDetail = ""

    public let root: URL
    public var pythonURL: URL { root.appendingPathComponent("python/bin/python3") }
    public var modelURL: URL { root.appendingPathComponent("model", isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent("ready.json") }

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        refresh()
    }

    public nonisolated static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appendingPathComponent("MeetGist/LocalNotes/Qwen3-8B/v1",
                                             isDirectory: true)
    }

    public func refresh() {
        guard Self.isSupported else {
            state = .notInstalled
            return
        }
        state = Self.isReady(at: root) ? .ready : .notInstalled
    }

    public nonisolated static func isReady(at root: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: root.appendingPathComponent("python/bin/python3").path)
            && fm.fileExists(atPath: root.appendingPathComponent("model/config.json").path)
            && fm.fileExists(atPath: root.appendingPathComponent("model/model.safetensors").path)
            && fm.fileExists(atPath: root.appendingPathComponent("ready.json").path)
    }

    public func install() async {
        guard state != .installing else { return }
        state = .installing
        installProgress = 0.02
        installDetail = "Preparing local Notes runtime…"
        do {
#if !arch(arm64)
            throw LocalNotesRuntimeError("Local Qwen Notes supports Apple Silicon Macs only.")
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
                throw LocalNotesRuntimeError("CPython download failed.")
            }
            let archive = root.appendingPathComponent("python.tar.gz")
            try fm.moveItem(at: downloaded, to: archive)
            let digest = SHA256.hash(data: try Data(contentsOf: archive))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == Self.pythonArchiveSHA256 else {
                throw LocalNotesRuntimeError("The CPython download failed its SHA-256 check.")
            }
            installProgress = 0.14
            try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", root.path])
            try? fm.removeItem(at: archive)
            guard fm.isExecutableFile(atPath: pythonURL.path) else {
                throw LocalNotesRuntimeError("The pinned CPython archive did not contain python/bin/python3.")
            }

            installDetail = "Installing MLX-LM \(Self.mlxLMVersion)…"
            installProgress = 0.22
            guard let requirements = Bundle.module.url(forResource: "qwen-notes-requirements",
                                                       withExtension: "lock") else {
                throw LocalNotesRuntimeError("Bundled Qwen requirements are missing.")
            }
            try await run(pythonURL.path, ["-m", "pip", "install", "--disable-pip-version-check",
                                           "--no-input", "-r", requirements.path])

            installDetail = "Downloading Qwen3 8B · 4-bit…"
            installProgress = 0.48
            let script = """
            import sys
            from huggingface_hub import snapshot_download
            snapshot_download(repo_id='\(Self.modelID)', revision='\(Self.modelRevision)', local_dir=sys.argv[1])
            """
            try await run(pythonURL.path, ["-c", script, modelURL.path])
            guard Self.isModelPresent(at: modelURL) else {
                throw LocalNotesRuntimeError("The Qwen model download is incomplete.")
            }

            let marker: [String: String] = [
                "python": Self.pythonVersion,
                "python_build": Self.pythonBuild,
                "mlx_lm": Self.mlxLMVersion,
                "mlx": Self.mlxVersion,
                "model": Self.modelID,
                "model_revision": Self.modelRevision,
            ]
            let data = try JSONSerialization.data(withJSONObject: marker,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: markerURL, options: .atomic)
            installProgress = 1
            installDetail = "Qwen3 8B is ready for local Notes."
            state = .ready
#endif
        } catch {
            state = .failed(error.localizedDescription)
            installDetail = error.localizedDescription
        }
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        installProgress = 0
        installDetail = ""
        state = .notInstalled
    }

    private nonisolated static func isModelPresent(at modelURL: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelURL.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: modelURL.appendingPathComponent("model.safetensors").path)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let logURL = root.appendingPathComponent("install.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n").suffix(10).joined(separator: "\n")
            throw LocalNotesRuntimeError(tail ?? "Runtime setup command failed (\(status)).")
        }
    }
}

private struct LocalNotesRuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
