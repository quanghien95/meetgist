// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

/// Setup steps shared by every app-managed Python runtime (Offline Whisper,
/// Offline Qwen3-ASR, Local Qwen Notes): the pinned, SHA-256-verified CPython
/// build, hash-locked `pip install`, a model download at an exact revision, and
/// logged setup commands. Each runtime still owns its own root directory, so
/// installing or removing one never touches another.
enum ManagedPython {
    static let version = "3.11.16"
    static let build = "20260814"
    static let archiveSHA256 = "fcba9f3f676c83e07225e38116649f0c6eb94cb4fcc166632cf92769462b6e39"
    static let archiveURL = URL(string:
        "https://github.com/astral-sh/python-build-standalone/releases/download/\(build)/cpython-\(version)%2B\(build)-aarch64-apple-darwin-install_only.tar.gz")!

    struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func pythonURL(in root: URL) -> URL { root.appendingPathComponent("python/bin/python3") }
    static func installLogURL(in root: URL) -> URL { root.appendingPathComponent("install.log") }

    /// Recreates `root` empty (a failed or partial install never lingers).
    static func resetRoot(_ root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Downloads the pinned CPython archive, rejects it unless its SHA-256
    /// matches, and extracts it to `root/python`. `download` and
    /// `expectedSHA256` are injectable for tests.
    static func installCPython(
        into root: URL,
        expectedSHA256: String = archiveSHA256,
        download: @Sendable (URL) async throws -> (URL, URLResponse) = { try await URLSession.shared.download(from: $0) }
    ) async throws {
        let fm = FileManager.default
        let (downloaded, response) = try await download(archiveURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError("CPython download failed.")
        }
        let archive = root.appendingPathComponent("python.tar.gz")
        try fm.moveItem(at: downloaded, to: archive)
        try verifySHA256(of: archive, expected: expectedSHA256)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", root.path], logURL: installLogURL(in: root))
        try? fm.removeItem(at: archive)
        guard fm.isExecutableFile(atPath: pythonURL(in: root).path) else {
            throw SetupError("The pinned CPython archive did not contain python/bin/python3.")
        }
    }

    static func verifySHA256(of file: URL, expected: String) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw SetupError("The CPython download failed its SHA-256 check.")
        }
    }

    /// `pip install` from a bundled lockfile; every package must match its hash.
    static func pipInstall(in root: URL, lockResource: String, missingMessage: String) async throws {
        guard let requirements = Bundle.module.url(forResource: lockResource, withExtension: "lock") else {
            throw SetupError(missingMessage)
        }
        try await run(pythonURL(in: root).path,
                      ["-m", "pip", "install", "--disable-pip-version-check",
                       "--no-input", "--require-hashes", "-r", requirements.path],
                      logURL: installLogURL(in: root))
    }

    /// Downloads a Hugging Face model snapshot at an exact commit revision.
    static func downloadModel(in root: URL, repoID: String, revision: String, to modelURL: URL) async throws {
        let script = """
        import sys
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id='\(repoID)', revision='\(revision)', local_dir=sys.argv[1])
        """
        try await run(pythonURL(in: root).path, ["-c", script, modelURL.path], logURL: installLogURL(in: root))
    }

    static func writeMarker(_ marker: [String: String], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Runs a setup command, appending its output to `logURL`; on failure the
    /// error carries the log's last lines.
    static func run(_ executable: String, _ arguments: [String], logURL: URL, tailLines: Int = 10) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
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
                .split(separator: "\n").suffix(tailLines).joined(separator: "\n")
            throw SetupError(tail.flatMap { $0.isEmpty ? nil : $0 } ?? "Runtime setup command failed (\(status)).")
        }
    }
}
