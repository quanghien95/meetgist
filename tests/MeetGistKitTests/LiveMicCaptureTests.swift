// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import AVFoundation
@testable import MeetGistKit

/// Explicitly opt-in hardware startup/restart check. Never requests OS
/// permission, saves audio, or runs ASR/cloud calls. This validates native
/// processed mono capture, not acoustic suppression or speech recognition.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEETGIST_LIVE_MIC_CHECK"] == "1"))
struct LiveMicCaptureTests {
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var sumSquares = 0.0
        func ingest(_ samples: [Float]) {
            let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            lock.lock()
            count += samples.count
            sumSquares += energy
            lock.unlock()
        }
        func reading() -> (count: Int, db: Double) {
            lock.lock()
            defer { lock.unlock() }
            return (count, count > 0 && sumSquares > 0 ? 10 * log10(sumSquares / Double(count)) : -160)
        }
    }

    @Test func nativeEchoCancellationDeliversMonoPCM() async throws {
        // The explicit env flag authorizes this capture, but it must never
        // open a new OS permission dialog from a test process.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Issue.record("Hardware check needs existing Microphone permission; no permission was requested.")
            return
        }
        let cleaned = Meter()
        let mic = LiveMicTap()
        do {
            try await mic.start { chunk in
                #expect(chunk.channels == 1)
                cleaned.ingest(chunk.samples)
            }
            try await Task.sleep(for: .seconds(4))
            await mic.stop()
            let firstCount = cleaned.reading().count
            try await mic.start { chunk in
                #expect(chunk.channels == 1)
                cleaned.ingest(chunk.samples)
            }
            try await Task.sleep(for: .seconds(1))
            await mic.stop()
            #expect(cleaned.reading().count > firstCount + 16_000)
        } catch {
            await mic.stop()
            throw error
        }
        let after = cleaned.reading()
        #expect(after.count > 16_000)
        print("[native mic check] mono=true, processed_db=\(after.db), processed_samples=\(after.count), restart=true")
    }
}
