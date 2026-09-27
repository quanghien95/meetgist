// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine

public enum LocalNotesRuntimeState: Equatable, Sendable {
    case notInstalled
    case installing
    case ready
    case failed(String)
}

/// Central description of the pinned local Notes model. Keeping every
/// model-specific constant here (instead of scattered across the runtime
/// manager, the worker, and the UI) is what lets a future swap — e.g. to a
/// Qwen3.5 or 2B checkpoint — touch one place instead of rewriting the
/// pipeline. See `docs/ARCHITECTURE.md` for the provider boundary this
/// config sits behind.
public struct LocalNotesModelConfig: Sendable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen3-4B-Instruct-2507-4bit".
    public let modelID: String
    /// Exact pinned revision (commit sha) — never a moving branch/tag.
    public let modelRevision: String
    /// Approximate total download size in bytes, for UI/readiness messaging.
    public let downloadBytes: Int64
    /// Short label shown in Settings and as the notes-writer label.
    public let displayLabel: String
    /// Source-transcript token budget below which a meeting is processed in a
    /// single direct generation call, no map/reduce.
    public let directSourceTokens: Int
    /// Per-chunk source token budget for the map (extract) stage.
    public let mapSourceTokens: Int
    /// Max output tokens for one map (extract) call.
    public let mapOutputTokens: Int
    /// Source token budget for the reduce (condense) stage batches.
    public let reduceSourceTokens: Int
    /// Max output tokens for one reduce (condense) call.
    public let reduceOutputTokens: Int
    /// Max output tokens for the final polished+summary generation call.
    public let finalOutputTokens: Int
    /// Sampler settings recommended by the model card's generation_config.json.
    public let temperature: Double
    public let topP: Double
    public let topK: Int

    /// Qwen3-4B-Instruct-2507 · MLX-LM · 4-bit. Non-thinking-only model — no
    /// `enable_thinking` toggle needed. Pinned from mlx-community; revision is
    /// the exact commit sha, not a branch, so installs are reproducible.
    public static let qwen3_4bInstruct2507 = LocalNotesModelConfig(
        modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        modelRevision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        downloadBytes: 2_280_000_000,
        displayLabel: "Qwen3 4B Instruct (2507) · MLX-LM · 4-bit",
        directSourceTokens: 28_000,
        mapSourceTokens: 6_000,
        mapOutputTokens: 700,
        reduceSourceTokens: 6_000,
        reduceOutputTokens: 700,
        finalOutputTokens: 3_072,
        temperature: 0.7,
        topP: 0.8,
        topK: 20
    )
}

/// Owns the Python/MLX-LM runtime and Qwen model used only by the Notes slot.
/// It intentionally does not share files or lifecycle with Local Whisper.
@MainActor
public final class LocalNotesRuntimeManager: ObservableObject {
    public nonisolated static var pythonVersion: String { ManagedPython.version }
    public nonisolated static var pythonBuild: String { ManagedPython.build }
    public nonisolated static let mlxLMVersion = "0.31.3"
    public nonisolated static let mlxVersion = "0.32.1"
    // Immutable Sendable value, safe to read from any isolation context (the
    // notes writer runs off the main actor).
    public nonisolated static let activeModel = LocalNotesModelConfig.qwen3_4bInstruct2507
    public nonisolated static var modelID: String { activeModel.modelID }
    public nonisolated static var modelRevision: String { activeModel.modelRevision }
    public nonisolated static var modelDownloadBytes: Int64 { activeModel.downloadBytes }
    public nonisolated static var pythonArchiveSHA256: String { ManagedPython.archiveSHA256 }

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
    public var pythonURL: URL { ManagedPython.pythonURL(in: root) }
    public var modelURL: URL { root.appendingPathComponent("model", isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent("ready.json") }

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        refresh()
    }

    public nonisolated static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        // A distinct path per model generation means switching the pinned model
        // (as here, 8B → 4B) never mistakes a stale install of a different model
        // for a ready one; the old Qwen3-8B directory is simply orphaned and can
        // be removed by the user like any other stale runtime.
        return support.appendingPathComponent("MeetGist/LocalNotes/Qwen3-4B/v1",
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
            throw ManagedPython.SetupError("Local Qwen Notes supports Apple Silicon Macs only.")
#else
            try ManagedPython.resetRoot(root)

            installDetail = "Downloading CPython \(Self.pythonVersion)…"
            try await ManagedPython.installCPython(into: root)
            installProgress = 0.14

            installDetail = "Installing MLX-LM \(Self.mlxLMVersion)…"
            installProgress = 0.22
            try await ManagedPython.pipInstall(in: root, lockResource: "qwen-notes-requirements",
                                               missingMessage: "Bundled Qwen requirements are missing.")

            installDetail = "Downloading \(Self.activeModel.displayLabel)…"
            installProgress = 0.48
            try await ManagedPython.downloadModel(in: root, repoID: Self.modelID,
                                                  revision: Self.modelRevision, to: modelURL)
            guard Self.isModelPresent(at: modelURL) else {
                throw ManagedPython.SetupError("The Qwen model download is incomplete.")
            }

            try ManagedPython.writeMarker(Self.marker, to: markerURL)
            installProgress = 1
            installDetail = "\(Self.activeModel.displayLabel) is ready for local Notes."
            state = .ready
#endif
        } catch {
            state = .failed(error.localizedDescription)
            installDetail = error.localizedDescription
        }
    }

    /// Contents of ready.json: the exact versions this runtime was built from.
    nonisolated static var marker: [String: String] {
        [
            "python": pythonVersion,
            "python_build": pythonBuild,
            "mlx_lm": mlxLMVersion,
            "mlx": mlxVersion,
            "model": modelID,
            "model_revision": modelRevision,
        ]
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
}
