// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The app-owned runtime for the persistent Live ASR worker (plan §5.4). A
/// separate `ManagedOfflineRuntime` root from the one-shot offline Qwen3-ASR
/// engine (`Qwen3ASRRuntimeManager`) — different model size, different
/// lifecycle (loaded once per recording instead of once per job) — but it
/// reuses the same pinned `mlx-audio` requirements lockfile
/// ("offline-requirements-qwen"), since both engines load a Qwen3-ASR model
/// through the same `mlx_audio.stt.utils.load_model` path.
///
/// Quantization pin: **4bit is the default** (2026-09-27 "latency first"
/// decision, plan §3 — the post-meeting offline/cloud pipeline is the
/// accuracy backstop for the canonical transcript, so Live Assist optimizes
/// for lower latency/memory). The 8bit revision is kept fully documented
/// below so switching is a one-line change once P4 benchmarks both on this
/// machine (plan §9).
///
/// Revisions/sizes verified directly against the HF API on 2026-09-27:
/// `curl https://huggingface.co/api/models/mlx-community/Qwen3-ASR-0.6B-4bit?blobs=true`
/// (and `-8bit`), summing sibling file sizes.
@MainActor
public final class LiveASRRuntimeManager: ManagedOfflineRuntime {
    /// Default: `mlx-community/Qwen3-ASR-0.6B-4bit` — rev
    /// `313d850181767edf09f00a9c289becca70e58cd0`, 712,781,279 bytes total.
    public nonisolated static let qwen0_6BConfig = OfflineRuntimeConfig(
        rootPath: "MeetGist/LiveASR/Qwen3-ASR-0.6B/v1",
        lockResource: "offline-requirements-qwen",
        packageName: "MLX Audio",
        packageMarkerKey: "mlx_audio",
        packageVersion: "0.5.6",
        mlxVersion: "0.32.2",
        modelRepo: "mlx-community/Qwen3-ASR-0.6B-4bit",
        modelRevision: "313d850181767edf09f00a9c289becca70e58cd0",
        modelDownloadBytes: 712_781_279,
        modelReadyFile: "config.json",
        modelDisplayName: "Qwen3-ASR 0.6B (4-bit, live)",
        unsupportedMessage: "Live Assist's realtime transcription supports Apple Silicon Macs only.")

    /// Alternative, not installed by default: `mlx-community/Qwen3-ASR-0.6B-8bit`
    /// — rev `89e96d92ba34aca20b3e29fb10cc284097d1219f`, 1,010,773,761 bytes
    /// total. P4 benchmarks this against the 4bit default (ASR latency,
    /// memory) before deciding whether to switch (plan §5.4/§9).
    public nonisolated static let qwen0_6B8BitConfig = OfflineRuntimeConfig(
        rootPath: "MeetGist/LiveASR/Qwen3-ASR-0.6B-8bit/v1",
        lockResource: "offline-requirements-qwen",
        packageName: "MLX Audio",
        packageMarkerKey: "mlx_audio",
        packageVersion: "0.5.6",
        mlxVersion: "0.32.2",
        modelRepo: "mlx-community/Qwen3-ASR-0.6B-8bit",
        modelRevision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
        modelDownloadBytes: 1_010_773_761,
        modelReadyFile: "config.json",
        modelDisplayName: "Qwen3-ASR 0.6B (8-bit, live)",
        unsupportedMessage: "Live Assist's realtime transcription supports Apple Silicon Macs only.")

    public nonisolated static var pythonVersion: String { ManagedPython.version }
    public nonisolated static var pythonBuild: String { ManagedPython.build }
    public nonisolated static var mlxAudioVersion: String { qwen0_6BConfig.packageVersion }
    public nonisolated static var mlxVersion: String { qwen0_6BConfig.mlxVersion }
    public nonisolated static var modelRevision: String { qwen0_6BConfig.modelRevision }
    public nonisolated static var modelDownloadBytes: Int64 { qwen0_6BConfig.modelDownloadBytes }
    public nonisolated static var pythonArchiveSHA256: String { ManagedPython.archiveSHA256 }

    public init(root: URL? = nil, config: OfflineRuntimeConfig = LiveASRRuntimeManager.qwen0_6BConfig) {
        super.init(config: config, root: root)
    }
}
