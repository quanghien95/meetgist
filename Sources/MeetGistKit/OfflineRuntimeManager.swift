// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine

public enum OfflineRuntimeState: Equatable, Sendable {
    case notInstalled
    case installing
    case ready
    case failed(String)
}

/// Everything that differs between the offline transcription engines' runtimes.
/// Keeping it declarative means a new engine cannot forget the model revision
/// pin, the hash-locked requirements, or its own isolated root.
public struct OfflineRuntimeConfig: Sendable, Equatable {
    /// Path under Application Support, e.g. "MeetGist/OfflineWhisper/v1".
    public let rootPath: String
    /// Bundled `<name>.lock` installed with `pip --require-hashes`.
    public let lockResource: String
    /// Engine package shown while installing and recorded in ready.json.
    public let packageName: String
    public let packageMarkerKey: String
    public let packageVersion: String
    public let mlxVersion: String
    public let modelRepo: String
    /// Exact Hugging Face commit sha — never a moving branch.
    public let modelRevision: String
    /// Total repository file bytes at the pinned revision.
    public let modelDownloadBytes: Int64
    /// File under `model/` whose presence means the snapshot is complete.
    public let modelReadyFile: String
    public let modelDisplayName: String
    public let unsupportedMessage: String
}

/// Installs and manages one app-owned Python runtime for offline transcription.
/// `OfflineRuntimeManager` (Whisper) and `Qwen3ASRRuntimeManager` (Qwen3-ASR)
/// are this class with their own config and root, fully independent of each
/// other.
@MainActor
public class ManagedOfflineRuntime: ObservableObject {
    public let config: OfflineRuntimeConfig

    @Published public private(set) var state: OfflineRuntimeState = .notInstalled
    @Published public private(set) var installProgress: Double = 0
    @Published public private(set) var installDetail = ""

    public let root: URL
    public var pythonURL: URL { ManagedPython.pythonURL(in: root) }
    public var modelURL: URL { root.appendingPathComponent("model", isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent("ready.json") }

    public nonisolated static var isSupported: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    init(config: OfflineRuntimeConfig, root: URL?) {
        self.config = config
        if let root { self.root = root }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            self.root = support.appendingPathComponent(config.rootPath, isDirectory: true)
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
            && fm.fileExists(atPath: modelURL.appendingPathComponent(config.modelReadyFile).path)
            && fm.fileExists(atPath: markerURL.path) ? .ready : .notInstalled
    }

    public func install() async {
        guard state != .installing else { return }
        state = .installing
        installProgress = 0.02
        installDetail = "Preparing local runtime…"
        do {
#if !arch(arm64)
            throw ManagedPython.SetupError(config.unsupportedMessage)
#else
            try ManagedPython.resetRoot(root)

            installDetail = "Downloading CPython \(ManagedPython.version)…"
            try await ManagedPython.installCPython(into: root)
            installProgress = 0.16

            installDetail = "Installing \(config.packageName) \(config.packageVersion)…"
            installProgress = 0.25
            try await ManagedPython.pipInstall(in: root, lockResource: config.lockResource,
                                               missingMessage: "Bundled offline requirements are missing.")

            installDetail = "Downloading \(config.modelDisplayName)…"
            installProgress = 0.62
            try await ManagedPython.downloadModel(in: root, repoID: config.modelRepo,
                                                  revision: config.modelRevision, to: modelURL)

            try ManagedPython.writeMarker(Self.marker(for: config), to: markerURL)
            installProgress = 1
            installDetail = "\(config.modelDisplayName) is ready."
            state = .ready
#endif
        } catch {
            state = .failed(error.localizedDescription)
            installDetail = error.localizedDescription
        }
    }

    /// Contents of ready.json: the exact versions this runtime was built from.
    nonisolated static func marker(for config: OfflineRuntimeConfig) -> [String: String] {
        [
            "python": ManagedPython.version,
            "python_build": ManagedPython.build,
            config.packageMarkerKey: config.packageVersion,
            "mlx": config.mlxVersion,
            "model": config.modelRepo,
            "model_revision": config.modelRevision,
        ]
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
}

/// The app-owned runtime for offline MLX Whisper transcription.
@MainActor
public final class OfflineRuntimeManager: ManagedOfflineRuntime {
    public nonisolated static let whisperConfig = OfflineRuntimeConfig(
        rootPath: "MeetGist/OfflineWhisper/v1",
        lockResource: "offline-requirements",
        packageName: "MLX Whisper",
        packageMarkerKey: "mlx_whisper",
        packageVersion: "0.4.3",
        mlxVersion: "0.32.1",
        modelRepo: "mlx-community/whisper-large-v3-mlx",
        modelRevision: "49e6aa286ad60c14352c404340ded53710378a11",
        modelDownloadBytes: 3_083_522_487,
        modelReadyFile: "weights.npz",
        modelDisplayName: "MLX Whisper Large V3",
        unsupportedMessage: "Offline Whisper v1 supports Apple Silicon Macs only.")

    public nonisolated static var pythonVersion: String { ManagedPython.version }
    public nonisolated static var pythonBuild: String { ManagedPython.build }
    public nonisolated static var mlxWhisperVersion: String { whisperConfig.packageVersion }
    public nonisolated static var mlxVersion: String { whisperConfig.mlxVersion }
    public nonisolated static var modelRevision: String { whisperConfig.modelRevision }
    /// Settings rounds this using decimal units; the Python runtime and packages are additional.
    public nonisolated static var modelDownloadBytes: Int64 { whisperConfig.modelDownloadBytes }
    public nonisolated static var pythonArchiveSHA256: String { ManagedPython.archiveSHA256 }

    public init(root: URL? = nil) {
        super.init(config: Self.whisperConfig, root: root)
    }
}
