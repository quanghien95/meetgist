// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The app-owned runtime for offline Qwen3-ASR transcription (MLX Audio). Same
/// setup flow as `OfflineRuntimeManager` (see `ManagedOfflineRuntime`) but a
/// fully separate root, interpreter, and model, so installing/removing one
/// engine never touches the other.
@MainActor
public final class Qwen3ASRRuntimeManager: ManagedOfflineRuntime {
    public nonisolated static let qwen3ASRConfig = OfflineRuntimeConfig(
        rootPath: "MeetGist/Qwen3ASR/v1",
        lockResource: "offline-requirements-qwen",
        packageName: "MLX Audio",
        packageMarkerKey: "mlx_audio",
        packageVersion: "0.5.6",
        mlxVersion: "0.32.2",
        modelRepo: "mlx-community/Qwen3-ASR-1.7B-4bit",
        modelRevision: "78a389c776a5483b2d0d4ea5494e11012e0d6159",
        modelDownloadBytes: 1_607_633_106,
        modelReadyFile: "config.json",
        modelDisplayName: "Qwen3-ASR 1.7B",
        unsupportedMessage: "Offline Qwen3-ASR supports Apple Silicon Macs only.")

    public nonisolated static var pythonVersion: String { ManagedPython.version }
    public nonisolated static var pythonBuild: String { ManagedPython.build }
    public nonisolated static var mlxAudioVersion: String { qwen3ASRConfig.packageVersion }
    public nonisolated static var mlxVersion: String { qwen3ASRConfig.mlxVersion }
    public nonisolated static var modelRevision: String { qwen3ASRConfig.modelRevision }
    /// Settings rounds this using decimal units; the Python runtime and packages are additional.
    public nonisolated static var modelDownloadBytes: Int64 { qwen3ASRConfig.modelDownloadBytes }
    public nonisolated static var pythonArchiveSHA256: String { ManagedPython.archiveSHA256 }

    public init(root: URL? = nil) {
        super.init(config: Self.qwen3ASRConfig, root: root)
    }
}
