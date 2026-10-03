// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import AVFoundation
@testable import MeetGistKit

/// P4/P4-fix real-measurement benchmark (plan §9/§13) — env-gated
/// (`MEETGIST_LIVE_BENCH=1`), excluded from normal `make test`/CI.
///
/// Split into 3 **independent** `@Test`s (review finding F3, 2026-09-27):
/// the original single monolithic test ran ASR, Codex-semantic, and
/// end-to-end sections back to back in one `@Test func`, and — combined
/// with `print()` being fully block-buffered rather than line-buffered when
/// `swift test`'s stdout isn't a real terminal — a real (bounded, not
/// infinite) slow patch in one later section looked indistinguishable from
/// a silent hang in the earlier ones, since no output reached the log until
/// a buffer flushed. Root cause, from direct measurement (see the P4-fix
/// progress entry in docs/live-copilot-plan.md for the numbers): no
/// deadlock/leak was found in `QwenLiveTranscriber`, `ChildProcess`, or
/// `LiveCopilotEngine`'s scheduler — every await path there is already
/// timeout-guarded and cancellation-propagating. The stall is fully
/// explained by (a) stdout buffering hiding real progress, and (b) real
/// Codex CLI calls occasionally running close to their per-call timeout
/// ceiling under system load, and a single monolithic test summing many
/// such calls with no section-level cap. Fixed by: `setvbuf(stdout, nil,
/// _IOLBF, 0)` so prints flush immediately, one `@Test` per section so a
/// slow section can never block another's results being reported, and an
/// explicit hard wall-clock guard (`runWithHardDeadline`) around each
/// section's real work so this file itself can never again run
/// unboundedly long regardless of what's inside.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEETGIST_LIVE_BENCH"] == "1"))
struct LiveCopilotBenchmarkTests {
    // MARK: - Fixtures

    /// Mixed EN/VI meeting-style sentences with technical terms, 12 turns,
    /// each intended to render as roughly 4–18s of speech at `say`'s default
    /// rate (plan §9: "5–20s clips, ≥10 turns, mixed EN/VI, technical
    /// terms"). No real meeting content.
    private struct Fixture { let text: String; let voice: String }
    private static let fixtures: [Fixture] = [
        Fixture(text: "Good morning everyone, thanks for joining the call today. Let's start by reviewing last week's action items before we move into the roadmap discussion.", voice: "Samantha"),
        Fixture(text: "The new authentication service needs to support OAuth two point oh and SAML for enterprise customers by the end of this quarter.", voice: "Samantha"),
        Fixture(text: "Can we confirm whether the database migration is scheduled for this Friday, or should we push it to next week?", voice: "Samantha"),
        Fixture(text: "Chào mọi người, hôm nay chúng ta sẽ thảo luận về tiến độ dự án và các vấn đề còn tồn đọng.", voice: "Linh"),
        Fixture(text: "Bạn có thể xác nhận lại thời hạn hoàn thành tính năng thanh toán trước cuối tháng này được không?", voice: "Linh"),
        Fixture(text: "Chúng ta cần deploy phiên bản mới của API gateway lên production trước khi release ngày mai.", voice: "Linh"),
        Fixture(text: "Looking at the sprint retrospective, the team delivered twelve story points last week, which is slightly below our average velocity of fifteen points, so we should discuss capacity planning for the next sprint and whether we need additional headcount on the platform team.", voice: "Samantha"),
        Fixture(text: "We've decided to go with PostgreSQL instead of MongoDB for the new analytics service, since it gives us better support for complex joins and reporting queries.", voice: "Samantha"),
        Fixture(text: "Vấn đề chính hiện tại là hiệu năng của hệ thống khi có nhiều người dùng truy cập cùng lúc, đặc biệt là trong giờ cao điểm buổi sáng.", voice: "Linh"),
        Fixture(text: "So, um, I was wondering, whether the client actually approved the new pricing model, or if that's still pending legal review?", voice: "Samantha"),
        Fixture(text: "The Kubernetes cluster autoscaling policy triggered three times yesterday because the CPU threshold was set quá thấp, so let's tăng it lên eighty percent.", voice: "Samantha"),
        Fixture(text: "Yes, that sounds good, let's move on to the next topic.", voice: "Samantha"),
    ]

    /// Synthesizes `fixture` with `say` to AIFF, then decodes + resamples to
    /// mono 16kHz Float32 (matching `LiveAudioFeed`'s own resampling
    /// approach) — the exact format `SpeechSegment`/the worker protocol
    /// expect.
    private static func synthesize(_ fixture: Fixture, into dir: URL) throws -> [Float] {
        let aiffURL = dir.appendingPathComponent("\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", fixture.voice, "-o", aiffURL.path, fixture.text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: aiffURL.path) else {
            throw BenchError.sayFailed(fixture.voice)
        }
        return try decodeMono16k(aiffURL)
    }

    private static func decodeMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchError.decodeFailed
        }
        try file.read(into: buffer)
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { throw BenchError.decodeFailed }
        var mono = [Float](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var sum: Float = 0
            for ch in 0..<channels { sum += channelData[ch][frame] }
            mono[frame] = sum / Float(channels)
        }
        let sourceRate = buffer.format.sampleRate
        guard abs(sourceRate - 16_000) > 0.01 else { return mono }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return mono }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, let dest = inBuffer.floatChannelData?[0] else { return }
            dest.update(from: base, count: mono.count)
        }
        let ratio = 16_000.0 / sourceRate
        let outCapacity = AVAudioFrameCount((Double(mono.count) * ratio).rounded(.up)) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return mono }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData
            return inBuffer
        }
        guard conversionError == nil, let data = outBuffer.floatChannelData?[0] else { return mono }
        return Array(UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
    }

    enum BenchError: Error, LocalizedError {
        case sayFailed(String), decodeFailed, workerEOF, timedOut, sectionDeadlineExceeded(String)
        var errorDescription: String? {
            switch self {
            case .sayFailed(let voice): return "`say -v \(voice)` failed"
            case .decodeFailed: return "Could not decode synthesized audio"
            case .workerEOF: return "Live ASR worker closed its stdout unexpectedly"
            case .timedOut: return "Timed out waiting for the worker"
            case .sectionDeadlineExceeded(let label): return "\(label) exceeded its hard wall-clock deadline"
            }
        }
    }

    /// F3 fix: a hard, section-level wall-clock ceiling so one slow/stuck
    /// section can never silently consume the whole benchmark run. Mirrors
    /// `LiveCopilotEngine.withTimeout`'s race-against-a-sleep pattern
    /// (already proven not to leak) rather than inventing a new mechanism.
    /// On timeout the still-running `body` task is cancelled (every real
    /// operation inside these sections — `ChildProcess`, `URLSession`, the
    /// worker's own read-loop deadlines — already responds to Task
    /// cancellation or has its own inner deadline) and the failure is
    /// recorded via `Issue.record` rather than thrown, so the surrounding
    /// `@Test` can still report whatever partial results it already printed.
    private static func runWithHardDeadline(seconds: Double, label: String,
                                            _ body: @escaping @Sendable () async throws -> Void) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw BenchError.sectionDeadlineExceeded(label)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            Issue.record("[bench] \(label) did not finish within its \(Int(seconds))s hard wall-clock limit (or failed): \(error)")
        }
    }

    // MARK: - Direct worker protocol harness (raw JSON-lines, sequential)
    //
    // Talks to the real `live_asr_worker.py` directly (not through
    // `QwenLiveTranscriber`) so this benchmark can read the worker's own
    // `load_ms`/`asr_ms`/`peak_memory_mb` fields, which the production Swift
    // wrapper doesn't expose (it only needs the transcribed text). The
    // production integration itself (Swift ↔ worker end to end) is covered
    // separately below via `QwenLiveTranscriber` and via `LiveAssistSession`.
    private actor DirectWorkerHarness {
        private let process = Process()
        private let stdin: FileHandle
        private let stdout: FileHandle
        private var buffer = Data()

        init(pythonURL: URL, workerScriptURL: URL, modelDirURL: URL) throws {
            process.executableURL = pythonURL
            process.arguments = ["-u", workerScriptURL.path, "--model-dir", modelDirURL.path]
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            stdin = inPipe.fileHandleForWriting
            stdout = outPipe.fileHandleForReading
        }

        nonisolated var pid: Int32 { process.processIdentifier }

        func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try stdin.write(contentsOf: data + Data([0x0A]))
        }

        func readMessage(timeoutSeconds: Double = 60) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while true {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    buffer.removeSubrange(...newlineIndex)
                    if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] { return obj }
                    continue
                }
                if Date() > deadline { throw BenchError.timedOut }
                let chunk = await Self.readAvailable(stdout)
                if chunk.isEmpty { throw BenchError.workerEOF }
                buffer.append(chunk)
            }
        }

        func shutdown() {
            try? send(["type": "shutdown"])
            process.terminate()
            process.waitUntilExit()
        }

        private nonisolated static func readAvailable(_ handle: FileHandle) async -> Data {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: handle.availableData) }
            }
        }
    }

    private struct TurnMetric { let asrMs: Double; let audioSeconds: Double; let peakMemoryMB: Double }

    /// Runs every fixture through the worker at `modelDirURL`, sequentially
    /// (no pipelining — this is a latency benchmark, not a throughput one).
    /// Returns (loadMs, per-turn metrics, max RSS in MB sampled via `ps`).
    private static func runWorkerBenchmark(pythonURL: URL, workerScriptURL: URL, modelDirURL: URL,
                                           samples: [[Float]], workDir: URL) async throws
        -> (loadMs: Double, turns: [TurnMetric], maxRSSMB: Double) {
        let harness = try DirectWorkerHarness(pythonURL: pythonURL, workerScriptURL: workerScriptURL, modelDirURL: modelDirURL)
        let ready = try await harness.readMessage(timeoutSeconds: 180)
        let loadMs = (ready["load_ms"] as? Double) ?? 0
        var turns: [TurnMetric] = []
        var maxRSSKB: Double = 0
        for (index, pcm) in samples.enumerated() {
            let pcmURL = workDir.appendingPathComponent("turn-\(index).f32")
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: pcmURL)
            try await harness.send(["type": "transcribe", "id": index, "pcm_path": pcmURL.path, "sample_rate": 16_000])
            let reply = try await harness.readMessage()
            try? FileManager.default.removeItem(at: pcmURL)
            if let rss = Self.psRSSKB(pid: harness.pid) { maxRSSKB = max(maxRSSKB, rss) }
            guard reply["type"] as? String == "result" else {
                print("  [bench] turn \(index) worker error: \(reply["message"] ?? "unknown")"); fflush(stdout)
                continue
            }
            let asrMs = (reply["asr_ms"] as? Double) ?? 0
            let audioSeconds = (reply["audio_seconds"] as? Double) ?? (Double(pcm.count) / 16_000)
            let peakMB = (reply["peak_memory_mb"] as? Double) ?? 0
            turns.append(TurnMetric(asrMs: asrMs, audioSeconds: audioSeconds, peakMemoryMB: peakMB))
            let text = (reply["text"] as? String) ?? ""
            print("  [bench] turn \(index) (\(String(format: "%.1fs", audioSeconds))): \(asrMs)ms → \"\(text.prefix(70))\"")
            fflush(stdout)
        }
        await harness.shutdown()
        return (loadMs, turns, maxRSSKB / 1024)
    }

    private static func psRSSKB(pid: Int32) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap(Double.init)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.down))))
        return sorted[index]
    }

    private static func printSummary(_ label: String, loadMs: Double, turns: [TurnMetric], maxRSSMB: Double) {
        let asrMs = turns.map(\.asrMs)
        let rtfs = turns.map { $0.audioSeconds > 0 ? $0.asrMs / 1000 / $0.audioSeconds : 0 }
        let workerPeakMB = turns.map(\.peakMemoryMB).max() ?? 0
        print("""
        === \(label) ===
        load_ms: \(loadMs)
        turns: \(turns.count)
        asr_ms p50/p90: \(percentile(asrMs, 0.5)) / \(percentile(asrMs, 0.9))
        RTF (asr/audio) p50/p90: \(percentile(rtfs, 0.5)) / \(percentile(rtfs, 0.9))
        peak_memory_mb (worker-reported): \(workerPeakMB)
        peak_memory_mb (ps -o rss): \(maxRSSMB)
        """)
        fflush(stdout)
    }

    private static func synthesizeAllFixtures(into audioDir: URL) throws -> [[Float]] {
        print("[bench] synthesizing \(Self.fixtures.count) fixtures with `say`…"); fflush(stdout)
        let samples = try Self.fixtures.map { try Self.synthesize($0, into: audioDir) }
        for (i, s) in samples.enumerated() {
            print("  [bench] fixture \(i): \(String(format: "%.2fs", Double(s.count) / 16_000)) (\(Self.fixtures[i].voice))")
        }
        fflush(stdout)
        return samples
    }

    /// One-time setup shared by every section: line-buffer stdout (F3 —
    /// see the type doc; block-buffering is what made a real-but-bounded
    /// slow run look like a silent hang) and create a fresh scratch dir.
    private static func makeScratchRoot() throws -> URL {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = URL(fileURLWithPath: "/private/tmp/claude-501/live-copilot-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Section 1: ASR-only (F3 — independent, own deadline)

    @Test func asrOnlyBenchmark() async throws {
        let scratchRoot = try Self.makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        let audioDir = scratchRoot.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        await Self.runWithHardDeadline(seconds: 240, label: "ASR-only benchmark") {
            let samples = try Self.synthesizeAllFixtures(into: audioDir)

            let runtime = await LiveASRRuntimeManager()
            await runtime.refresh()
            if await runtime.state != .ready {
                print("[bench] installing Live ASR runtime (4bit)…"); fflush(stdout)
                await runtime.install()
            }
            let runtimeState = await runtime.state
            guard runtimeState == .ready else {
                Issue.record("Live ASR runtime failed to install: \(runtimeState)")
                return
            }
            let pythonURL = await runtime.pythonURL
            let modelURL4bit = await runtime.modelURL
            let workerScriptURL = try QwenLiveTranscriber.resolveWorkerScriptURL()

            print("[bench] running 4bit ASR benchmark (shipped default)…"); fflush(stdout)
            let bench4bit = try await Self.runWorkerBenchmark(pythonURL: pythonURL, workerScriptURL: workerScriptURL,
                                                              modelDirURL: modelURL4bit, samples: samples, workDir: scratchRoot)
            Self.printSummary("Qwen3-ASR-0.6B-4bit", loadMs: bench4bit.loadMs, turns: bench4bit.turns, maxRSSMB: bench4bit.maxRSSMB)
            #expect(!bench4bit.turns.isEmpty)

            // Smoke-check the real Swift integration (QwenLiveTranscriber)
            // against the same installed runtime — full metrics come from
            // the direct-protocol harness above.
            let transcriberConfig = QwenLiveTranscriber.Config(pythonURL: pythonURL, workerScriptURL: workerScriptURL, modelDirURL: modelURL4bit)
            let transcriber = QwenLiveTranscriber(config: transcriberConfig)
            try await transcriber.prepare()
            for i in 0..<min(2, samples.count) {
                let segment = SpeechSegment(track: .speaker, startedAt: 0, endedAt: Double(samples[i].count) / 16_000, samples16k: samples[i])
                let text = try await transcriber.transcribe(segment)
                print("[bench] QwenLiveTranscriber smoke check turn \(i): \"\(text.prefix(70))\""); fflush(stdout)
                #expect(!text.isEmpty)
            }
            await transcriber.shutdown()
        }
    }

    // MARK: - Section 2: Codex semantic-only (F3 — independent, own deadline; also F4's evidence)

    @Test func codexSemanticOnlyBenchmark() async throws {
        await Self.runWithHardDeadline(seconds: 300, label: "Codex semantic-only benchmark") {
            let codexLLM = CodexCLICopilotLLM(reasoningEffort: "none")
            var codexLatencies: [Double] = []
            for (i, fixture) in Self.fixtures.enumerated() {
                let turn = LiveTranscriptTurn(id: i, track: .speaker, startedAt: Double(i) * 10, endedAt: Double(i) * 10 + 5, text: fixture.text)
                let request = CopilotLLMRequest(
                    system: LiveCopilotPrompts.semanticSystemPrompt(language: "Vietnamese"),
                    user: LiveCopilotPrompts.semanticUserContent(language: "Vietnamese", state: LiveMeetingState().compactView(),
                                                                 recentTurns: [], currentTurns: [turn]),
                    jsonSchema: LiveCopilotPrompts.semanticJSONSchema, maxOutputTokens: 350, timeout: 45, purpose: .semantic)
                do {
                    let response = try await codexLLM.complete(request)
                    codexLatencies.append(response.latency)
                    print("  [bench] codex turn \(i): \(String(format: "%.2fs", response.latency))"); fflush(stdout)
                } catch {
                    print("  [bench] codex turn \(i) FAILED: \(error.localizedDescription)"); fflush(stdout)
                }
            }
            if !codexLatencies.isEmpty {
                print("""
                === Codex CLI semantic latency (\(codexLatencies.count)/\(Self.fixtures.count) succeeded) ===
                p50/p90 seconds: \(Self.percentile(codexLatencies, 0.5)) / \(Self.percentile(codexLatencies, 0.9))
                """)
            } else {
                print("=== Codex CLI semantic latency: not measured (every request failed) ===")
            }
            fflush(stdout)
            #expect(!codexLatencies.isEmpty)

            // Gemini/OpenAI: only if a key already exists in the Keychain
            // (accessed only through `Keychain.get`/`Provider.keyAccount`,
            // never printed or logged).
            let sampleTurn = LiveTranscriptTurn(id: 0, track: .speaker, startedAt: 0, endedAt: 1, text: Self.fixtures[0].text)
            if let gemini = ProviderCatalog.builtIn.first(where: { $0.id == "gemini" }),
               let geminiKey = Keychain.get(gemini.keyAccount), !geminiKey.isEmpty {
                let llm = GeminiCopilotLLM(apiKey: geminiKey, baseURL: gemini.baseURL, model: gemini.notesModel ?? "gemini-flash-latest")
                do {
                    let request = CopilotLLMRequest(
                        system: LiveCopilotPrompts.semanticSystemPrompt(language: "Vietnamese"),
                        user: LiveCopilotPrompts.semanticUserContent(language: "Vietnamese", state: LiveMeetingState().compactView(),
                                                                     recentTurns: [], currentTurns: [sampleTurn]),
                        jsonSchema: LiveCopilotPrompts.semanticJSONSchema, maxOutputTokens: 350, timeout: 8, purpose: .semantic)
                    let response = try await llm.complete(request)
                    print("=== Gemini semantic latency: \(String(format: "%.2fs", response.latency)) ===")
                } catch {
                    print("=== Gemini semantic latency: request failed (\(error.localizedDescription)) ===")
                }
            } else {
                print("=== Gemini semantic latency: not measured (no key in Keychain) ===")
            }
            if let openai = ProviderCatalog.builtIn.first(where: { $0.id == "openai" }),
               let openaiKey = Keychain.get(openai.keyAccount), !openaiKey.isEmpty {
                let llm = ChatCopilotLLM(apiKey: openaiKey, baseURL: openai.baseURL, model: openai.notesModel ?? "gpt-4o-mini")
                do {
                    let request = CopilotLLMRequest(
                        system: LiveCopilotPrompts.semanticSystemPrompt(language: "Vietnamese"),
                        user: LiveCopilotPrompts.semanticUserContent(language: "Vietnamese", state: LiveMeetingState().compactView(),
                                                                     recentTurns: [], currentTurns: [sampleTurn]),
                        jsonSchema: LiveCopilotPrompts.semanticJSONSchema, maxOutputTokens: 350, timeout: 8, purpose: .semantic)
                    let response = try await llm.complete(request)
                    print("=== OpenAI semantic latency: \(String(format: "%.2fs", response.latency)) ===")
                } catch {
                    print("=== OpenAI semantic latency: request failed (\(error.localizedDescription)) ===")
                }
            } else {
                print("=== OpenAI semantic latency: not measured (no key in Keychain) ===")
            }
            fflush(stdout)
        }
    }

    // MARK: - Section 3: End-to-end (F3 — independent, own deadline)

    @Test func endToEndBenchmark() async throws {
        let scratchRoot = try Self.makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        let audioDir = scratchRoot.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        await Self.runWithHardDeadline(seconds: 300, label: "End-to-end benchmark") {
            let samples = try Self.synthesizeAllFixtures(into: audioDir)

            let runtime = await LiveASRRuntimeManager()
            await runtime.refresh()
            if await runtime.state != .ready {
                print("[bench] installing Live ASR runtime (4bit)…"); fflush(stdout)
                await runtime.install()
            }
            guard await runtime.state == .ready else {
                Issue.record("Live ASR runtime not ready for end-to-end benchmark")
                return
            }
            let pythonURL = await runtime.pythonURL
            let modelURL4bit = await runtime.modelURL
            let workerScriptURL = try QwenLiveTranscriber.resolveWorkerScriptURL()
            let codexLLM = CodexCLICopilotLLM(reasoningEffort: "none")

            print("[bench] end-to-end runs (audio → endpointer → ASR → Codex semantic → snapshot)…"); fflush(stdout)
            var e2eLatencies: [Double] = []
            let runCount = min(10, samples.count)
            for i in 0..<runCount {
                let engine = LiveCopilotEngine(config: LiveCopilotEngine.Config(language: "Vietnamese"), llm: codexLLM)
                let e2eTranscriberConfig = QwenLiveTranscriber.Config(pythonURL: pythonURL, workerScriptURL: workerScriptURL, modelDirURL: modelURL4bit)
                let e2eTranscriber = QwenLiveTranscriber(config: e2eTranscriberConfig)
                let speaker = BenchAudioSource()
                let session = LiveAssistSession(engine: engine, transcriber: e2eTranscriber, speakerSource: speaker,
                                                micSource: nil, config: LiveAssistSession.Config(recordingAnchorHostNs: 0))
                await session.start()
                let start = DispatchTime.now()
                speaker.feed(samples: samples[i % samples.count], sampleRate: 16_000)
                speaker.feed(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)   // 1s silence → hangover
                var asrDoneAt: DispatchTime?
                var semanticDoneAt: DispatchTime?
                // Per-run deadline well under the section's own 300s budget
                // (real Codex p50/p90 measured elsewhere ≈ 9-11s) so a
                // single stuck run can't consume the whole section either.
                let deadline = Date().addingTimeInterval(25)
                while Date() < deadline {
                    let snapshot = await session.currentSnapshot()
                    if asrDoneAt == nil, snapshot.latestTranscriptTurn != nil { asrDoneAt = DispatchTime.now() }
                    if semanticDoneAt == nil, snapshot.lastMeaning != nil { semanticDoneAt = DispatchTime.now(); break }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                await session.stop()
                if let asrDoneAt, let semanticDoneAt {
                    let asrLatency = Double(asrDoneAt.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                    let totalLatency = Double(semanticDoneAt.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                    e2eLatencies.append(totalLatency)
                    print("  [bench] e2e run \(i): asr \(String(format: "%.2fs", asrLatency)), total (asr+semantic) \(String(format: "%.2fs", totalLatency))")
                } else {
                    print("  [bench] e2e run \(i): did not complete within 25s")
                }
                fflush(stdout)
            }
            if !e2eLatencies.isEmpty {
                print("""
                === End-to-end (audio fed → endpointer → ASR → Codex semantic → snapshot), \(e2eLatencies.count)/\(runCount) completed ===
                p50/p90 seconds: \(Self.percentile(e2eLatencies, 0.5)) / \(Self.percentile(e2eLatencies, 0.9))
                """)
            } else {
                print("=== End-to-end: not measured (no run completed within its 25s per-run deadline) ===")
            }
            fflush(stdout)
            #expect(!e2eLatencies.isEmpty)
        }
    }
    // MARK: - Section 4: V2 (Suggest Answer / Ask Meet Gist) — plan §9/P6
    //
    // Real Codex CLI calls through the exact same prompt builders
    // (`LiveCopilotPrompts.answerUserContent`/`answerSystemPrompt`) and
    // adapter (`CodexCLICopilotLLM`) the app uses — no fakes. Produces the
    // ≥10 Suggest Answer / ≥10 Ask Meet Gist measurements plan §9/P6 asks
    // for, plus the real "Họ đang nói"/"Họ đang hỏi"/"Live Notes" examples
    // (via a few real semantic calls, Vietnamese) that seed a real
    // `LiveMeetingState` — the Suggest Answer/Ask prompts below are built
    // from that real, non-fabricated state, not hand-invented JSON.

    /// Ten synthetic questions a "Suggest Answer" button press might answer,
    /// each plausible given `Self.fixtures`' synthetic meeting content.
    private static let suggestAnswerQuestions: [String] = [
        "Liệu bản demo thanh toán có sẵn sàng trước cuối tuần không?",
        "Is the database migration confirmed for this Friday?",
        "Chúng ta đã chốt dùng PostgreSQL hay vẫn đang cân nhắc MongoDB?",
        "Was the new pricing model actually approved by the client?",
        "Ai sẽ chịu trách nhiệm việc tăng ngưỡng CPU cho cụm Kubernetes?",
        "What's blocking the OAuth 2.0 and SAML support for enterprise customers?",
        "Đội đã đạt bao nhiêu story point trong sprint vừa rồi?",
        "Is legal review for the pricing model finished or still pending?",
        "Vấn đề hiệu năng giờ cao điểm buổi sáng đã được xử lý chưa?",
        "Should we increase headcount on the platform team next sprint?",
    ]

    /// Ten free-form "Ask Meet Gist" questions, matching the shape of the
    /// user's own example prompts (a literal translation check, a time-boxed
    /// summary, an action-item lookup, …).
    private static let askQuestions: [String] = [
        "Ý của câu vừa nói về Kubernetes autoscaling là gì?",
        "Tóm tắt 5 phút vừa rồi giúp tôi.",
        "Có action item nào giao cho tôi không?",
        "What decisions have we actually made so far, not just discussed?",
        "Ai đang phụ trách việc migrate sang PostgreSQL?",
        "Có câu hỏi nào vẫn đang bỏ ngỏ chưa được trả lời không?",
        "Tình trạng hiện tại của việc hỗ trợ SAML cho doanh nghiệp ra sao?",
        "Summarize the retrospective discussion in one or two sentences.",
        "Deadline nào đã được xác nhận rõ ràng trong cuộc họp này?",
        "Is there anything the team disagreed on during this discussion?",
    ]

    @Test func suggestAnswerAndAskMeetGistBenchmark() async throws {
        await Self.runWithHardDeadline(seconds: 480, label: "V2 (Suggest Answer / Ask Meet Gist) benchmark") {
            let language = "Vietnamese"
            let codexLLM = CodexCLICopilotLLM(reasoningEffort: "none")

            // Seed a *real* LiveMeetingState from a handful of real semantic
            // calls over the synthetic fixtures (not fabricated JSON) so the
            // Suggest/Ask prompts below carry a real compact STATE + real
            // recent TURNS, exactly like a live meeting would.
            var state = LiveMeetingState()
            var seededTurns: [LiveTranscriptTurn] = []
            print("[bench] seeding a real LiveMeetingState via real semantic calls (Vietnamese)…"); fflush(stdout)
            for (i, fixture) in Self.fixtures.prefix(6).enumerated() {
                let turn = LiveTranscriptTurn(id: i, track: .speaker, startedAt: Double(i) * 10, endedAt: Double(i) * 10 + 5, text: fixture.text)
                seededTurns.append(turn)
                let request = CopilotLLMRequest(
                    system: LiveCopilotPrompts.semanticSystemPrompt(language: language),
                    user: LiveCopilotPrompts.semanticUserContent(language: language, state: state.compactView(),
                                                                 recentTurns: Array(seededTurns.dropLast()), currentTurns: [turn]),
                    jsonSchema: LiveCopilotPrompts.semanticJSONSchema, maxOutputTokens: 350, timeout: 45, purpose: .semantic)
                do {
                    let response = try await codexLLM.complete(request)
                    let parsed = try SemanticResultParser.parse(response.text)
                    state.apply(parsed, forTurns: [turn])
                    print("""
                      [bench] seed turn \(i): meaning=\"\(parsed.meaning)\" is_question=\(parsed.isQuestion) \
                    question=\"\(parsed.question)\"
                    """)
                } catch {
                    print("  [bench] seed turn \(i) failed (\(error.localizedDescription)) — continuing with whatever state exists")
                }
                fflush(stdout)
            }
            print("""
            === Real seeded state (source for Suggest/Ask prompts below) ===
            topic: \(state.topic)
            key_points: \(state.keyPoints.map(\.text))
            decisions: \(state.decisions.map(\.text))
            action_items: \(state.actionItems.map(\.text))
            open_questions: \(state.openQuestions.map(\.text))
            last_meaning: \(state.lastMeaning ?? "(none)")
            last_question: \(state.lastQuestion ?? "(none)")
            """)
            fflush(stdout)

            let bounds = LiveCopilotPrompts.Bounds(maxRecentTurns: 8, maxRecentTurnsChars: 4_000)
            let compact = state.compactView()

            func runAnswerRequests(_ label: String, purpose: CopilotPurpose, questions: [String]) async -> [Double] {
                var latencies: [Double] = []
                for (i, question) in questions.enumerated() {
                    let request = CopilotLLMRequest(
                        system: LiveCopilotPrompts.answerSystemPrompt(language: language),
                        user: LiveCopilotPrompts.answerUserContent(language: language, question: question, state: compact,
                                                                   turns: seededTurns, context: [], bounds: bounds),
                        jsonSchema: LiveCopilotPrompts.answerJSONSchema, maxOutputTokens: 500,
                        timeout: purpose == .suggestAnswer ? 60 : 60, purpose: purpose)
                    do {
                        let response = try await codexLLM.complete(request)
                        latencies.append(response.latency)
                        let parsed = try LiveAssistAnswerParser.parse(response.text, providerLabel: response.providerLabel)
                        let checked = LiveAssistAnswerPostCheck.apply(parsed, evidencePool: seededTurns.map(\.text).joined(separator: " "))
                        print("""
                          [bench] \(label) \(i) (\(String(format: "%.2fs", response.latency))): Q: \(question)
                            A: \(checked.answer)
                            known_from_meeting: \(checked.knownFromMeeting)
                            assumptions: \(checked.assumptions)
                            confidence: \(checked.confidence)
                        """)
                    } catch {
                        print("  [bench] \(label) \(i) FAILED: \(error.localizedDescription)")
                    }
                    fflush(stdout)
                }
                return latencies
            }

            print("[bench] running \(Self.suggestAnswerQuestions.count) real Suggest Answer requests…"); fflush(stdout)
            let suggestLatencies = await runAnswerRequests("suggest", purpose: .suggestAnswer, questions: Self.suggestAnswerQuestions)
            print("""
            === Suggest Answer latency (\(suggestLatencies.count)/\(Self.suggestAnswerQuestions.count) succeeded) ===
            p50/p90 seconds: \(Self.percentile(suggestLatencies, 0.5)) / \(Self.percentile(suggestLatencies, 0.9))
            success rate: \(String(format: "%.0f%%", 100.0 * Double(suggestLatencies.count) / Double(Self.suggestAnswerQuestions.count)))
            """)
            fflush(stdout)

            print("[bench] running \(Self.askQuestions.count) real Ask Meet Gist requests…"); fflush(stdout)
            let askLatencies = await runAnswerRequests("ask", purpose: .ask, questions: Self.askQuestions)
            print("""
            === Ask Meet Gist latency (\(askLatencies.count)/\(Self.askQuestions.count) succeeded) ===
            p50/p90 seconds: \(Self.percentile(askLatencies, 0.5)) / \(Self.percentile(askLatencies, 0.9))
            success rate: \(String(format: "%.0f%%", 100.0 * Double(askLatencies.count) / Double(Self.askQuestions.count)))
            """)
            fflush(stdout)

            #expect(!suggestLatencies.isEmpty)
            #expect(!askLatencies.isEmpty)
        }
    }
}

/// Minimal `LiveAudioSource` for the benchmark's end-to-end runs: feeds
/// pre-synthesized PCM directly (as if a capture callback delivered it) with
/// no real-time pacing.
private final class BenchAudioSource: LiveAudioSource, @unchecked Sendable {
    private var onChunk: (@Sendable (LivePCMChunk) -> Void)?
    func start(onChunk: @escaping @Sendable (LivePCMChunk) -> Void) async throws { self.onChunk = onChunk }
    func stop() async { onChunk = nil }
    func feed(samples: [Float], sampleRate: Double) {
        onChunk?(LivePCMChunk(samples: samples, sampleRate: sampleRate, channels: 1, hostTimeNs: DispatchTime.now().uptimeNanoseconds))
    }
}
