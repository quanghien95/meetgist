// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Testing
import Foundation
@testable import MeetGistKit

/// Covers `HTTPRetry.withRetry`/`ensureOK` in isolation, without any network
/// access: every test drives the retry loop with a fake `operation` closure
/// (throwing `HTTPRetry.ensureOK`'s error for a given fake status, or a
/// `URLError`) and a `sleep` stub that never really waits, so the suite runs
/// instantly while still exercising the real backoff/cancellation logic.
@Suite struct HTTPRetryTests {
    /// Thread-safe mutable counter/log, since `withRetry`'s closures are
    /// `@Sendable` and Swift Testing runs suites concurrently.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func update(_ body: (inout T) -> Void) {
            lock.lock(); defer { lock.unlock() }
            body(&value)
        }
        var current: T {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func response(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/x")!, statusCode: code,
                        httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// A `sleep` stub that records the requested delay and returns instantly
    /// instead of actually waiting — but still checks cancellation first, so
    /// cancellation tests can use it too.
    static func instantSleep(_ delays: Box<[Double]>) -> @Sendable (Double) async throws -> Void {
        { seconds in
            try Task.checkCancellation()
            delays.update { $0.append(seconds) }
        }
    }

    @Test func retriesA503ThenSucceeds() async throws {
        let delays = Box<[Double]>([])
        let attempts = Box<Int>(0)
        let result = try await HTTPRetry.withRetry(label: "Test", sleep: Self.instantSleep(delays)) { () -> String in
            var isSecondAttempt = false
            attempts.update { $0 += 1; isSecondAttempt = $0 == 2 }
            if !isSecondAttempt {
                try HTTPRetry.ensureOK(Self.response(503), Data())
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.current == 2)
        #expect(delays.current.count == 1)
        // First retry delay should be ~1s (base delay) plus up to 25% jitter.
        #expect(delays.current[0] >= 1.0 && delays.current[0] <= 1.3)
    }

    @Test func honorsRetryAfterHeader() async throws {
        let delays = Box<[Double]>([])
        let attempts = Box<Int>(0)
        let result = try await HTTPRetry.withRetry(label: "Test", sleep: Self.instantSleep(delays)) { () -> String in
            var isSecondAttempt = false
            attempts.update { $0 += 1; isSecondAttempt = $0 == 2 }
            if !isSecondAttempt {
                try HTTPRetry.ensureOK(Self.response(429, headers: ["Retry-After": "5"]), Data())
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(delays.current == [5.0])
    }

    @Test func capsAnOverlongRetryAfterHeader() async throws {
        let delays = Box<[Double]>([])
        let attempts = Box<Int>(0)
        _ = try await HTTPRetry.withRetry(label: "Test", sleep: Self.instantSleep(delays)) { () -> String in
            var isSecondAttempt = false
            attempts.update { $0 += 1; isSecondAttempt = $0 == 2 }
            if !isSecondAttempt {
                try HTTPRetry.ensureOK(Self.response(503, headers: ["Retry-After": "600"]), Data())
            }
            return "ok"
        }
        #expect(delays.current == [30.0])
    }

    @Test func doesNotRetry401() async throws {
        let attempts = Box<Int>(0)
        await #expect(throws: PipelineError.self) {
            try await HTTPRetry.withRetry(label: "Test") { () -> String in
                attempts.update { $0 += 1 }
                try HTTPRetry.ensureOK(Self.response(401), Data())
                return "unreachable"
            }
        }
        #expect(attempts.current == 1)
    }

    @Test func doesNotRetry400() async throws {
        let attempts = Box<Int>(0)
        await #expect(throws: PipelineError.self) {
            try await HTTPRetry.withRetry(label: "Test") { () -> String in
                attempts.update { $0 += 1 }
                try HTTPRetry.ensureOK(Self.response(400), Data())
                return "unreachable"
            }
        }
        #expect(attempts.current == 1)
    }

    @Test func givesUpAfterMaxAttemptsWithLastError() async throws {
        let delays = Box<[Double]>([])
        let attempts = Box<Int>(0)
        do {
            _ = try await HTTPRetry.withRetry(label: "Test", policy: .init(maxRetries: 2, baseDelay: 0.01),
                                              sleep: Self.instantSleep(delays)) { () -> String in
                attempts.update { $0 += 1 }
                try HTTPRetry.ensureOK(Self.response(503), Data(#"{"error":"still down"}"#.utf8))
                return "unreachable"
            }
            Issue.record("expected the retry loop to give up and throw")
        } catch let PipelineError.http(code, body) {
            #expect(code == 503)
            #expect(body.contains("still down"))
        }
        // 1 initial attempt + 2 retries = 3 total attempts, 2 backoff sleeps.
        #expect(attempts.current == 3)
        #expect(delays.current.count == 2)
    }

    @Test func cancellationDuringBackoffThrowsCancellationErrorQuickly() async throws {
        let started = Date()
        let task = Task {
            try await HTTPRetry.withRetry(label: "Test", policy: .init(maxRetries: 3, baseDelay: 10)) { () -> String in
                try HTTPRetry.ensureOK(Self.response(503), Data())
                return "unreachable"
            }
        }
        // Give the task a moment to start its backoff sleep, then cancel it —
        // with a 10s base delay, only prompt cancellation keeps this fast.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        #expect(Date().timeIntervalSince(started) < 3.0)
    }

    @Test func urlErrorCancelledIsNeverRetried() async throws {
        let attempts = Box<Int>(0)
        await #expect(throws: URLError.self) {
            try await HTTPRetry.withRetry(label: "Test") { () -> String in
                attempts.update { $0 += 1 }
                throw URLError(.cancelled)
            }
        }
        #expect(attempts.current == 1)
    }

    @Test func retriesTransientURLErrorThenSucceeds() async throws {
        let delays = Box<[Double]>([])
        let attempts = Box<Int>(0)
        let result = try await HTTPRetry.withRetry(label: "Test", sleep: Self.instantSleep(delays)) { () -> String in
            var isSecondAttempt = false
            attempts.update { $0 += 1; isSecondAttempt = $0 == 2 }
            if !isSecondAttempt {
                throw URLError(.networkConnectionLost)
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.current == 2)
        #expect(delays.current.count == 1)
    }

    /// A timed-out model call may still be running (and billed) server-side,
    /// so the model-call policy must not resend it; uploads/polls still do.
    @Test func modelCallPolicyDoesNotRetryTimeouts() async throws {
        let attempts = Box<Int>(0)
        let delays = Box<[Double]>([])
        await #expect(throws: URLError.self) {
            try await HTTPRetry.withRetry(label: "Test", policy: .modelCall,
                                          sleep: Self.instantSleep(delays)) { () -> String in
                attempts.update { $0 += 1 }
                throw URLError(.timedOut)
            }
        }
        #expect(attempts.current == 1)

        let defaultAttempts = Box<Int>(0)
        let result = try await HTTPRetry.withRetry(label: "Test", sleep: Self.instantSleep(delays)) { () -> String in
            var first = false
            defaultAttempts.update { $0 += 1; first = $0 == 1 }
            if first { throw URLError(.timedOut) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(defaultAttempts.current == 2)
    }
}
