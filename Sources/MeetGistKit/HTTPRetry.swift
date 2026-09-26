// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Shared retry-with-backoff for the cloud HTTP clients (`GeminiClient.swift`,
/// `OpenAIClient.swift`). A single 429/5xx or transient network hiccup used to
/// fail an entire meeting's processing; every call site now routes its
/// request through `HTTPRetry.withRetry`.
///
/// Design:
/// - `ensureOK` is the same 2xx check every client used to inline, kept as a
///   single shared place. A non-2xx status still throws the existing
///   `PipelineError.http(status, body)` — unchanged message, unchanged type —
///   except that a status in `retryableStatusCodes` is wrapped in
///   `RetryableHTTPFailure` first, so `withRetry` can catch and retry it;
///   the wrapped `PipelineError.http` is exactly what surfaces once retries
///   are exhausted or for a non-retryable status, so failure text never
///   changes.
/// - `withRetry` retries `RetryableHTTPFailure` and the transient `URLError`
///   codes (timeouts, DNS, dropped connections) with exponential backoff
///   (1s, 2s, 4s for the default 3 retries) plus jitter, honoring a
///   `Retry-After` header (seconds form, capped) in place of the computed
///   delay. `URLError.cancelled` and any other error are never retried.
/// - Both the backoff sleep and the policy are injected, so tests can run
///   with no real waiting and still exercise cancellation.
enum HTTPRetry {
    struct Policy: Sendable {
        var maxRetries: Int
        var baseDelay: Double
        var maxRetryAfterSeconds: Double
        /// Whether `URLError.timedOut` is retried. Off for long model calls
        /// (generate / chat / transcribe): the server may still be working on
        /// — and billing — a request whose client timed out, so retrying it
        /// could pay for the same work several times. Uploads and status polls
        /// are cheap to repeat and keep it on.
        var retryTimeouts: Bool

        init(maxRetries: Int = 3, baseDelay: Double = 1.0, maxRetryAfterSeconds: Double = 30.0,
             retryTimeouts: Bool = true) {
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
            self.maxRetryAfterSeconds = maxRetryAfterSeconds
            self.retryTimeouts = retryTimeouts
        }

        /// For expensive, possibly-still-running model calls.
        static let modelCall = Policy(retryTimeouts: false)
    }

    /// Thrown by `ensureOK` for a status in `retryableStatusCodes`. `withRetry`
    /// catches this to drive the retry loop; `underlying` — the ordinary
    /// `PipelineError.http` — is what callers actually see once retries are
    /// exhausted.
    struct RetryableHTTPFailure: Error {
        let statusCode: Int
        let retryAfter: Double?
        let underlying: Error
    }

    /// HTTP statuses worth retrying: request timeout, rate limit, and the
    /// 5xx family. Any other 4xx (bad key, bad model, …) is not in this set
    /// and therefore fails immediately, same as before this helper existed.
    static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// Transient network conditions worth retrying. `.cancelled` is
    /// deliberately excluded — it means the task was cancelled (Cancel,
    /// starting a recording), not a flaky network.
    static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// Checks `response` for a 2xx status. Throws `RetryableHTTPFailure`
    /// (wrapping `PipelineError.http`) for a retryable status, or
    /// `PipelineError.http` directly otherwise — the exact error every client
    /// threw before retry support existed.
    static func ensureOK(_ response: URLResponse, _ data: Data,
                        retryAfterCap: Double = Policy().maxRetryAfterSeconds) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String((String(data: data, encoding: .utf8) ?? "").prefix(400))
            let error = PipelineError.http(http.statusCode, body)
            if retryableStatusCodes.contains(http.statusCode) {
                throw RetryableHTTPFailure(statusCode: http.statusCode,
                                           retryAfter: retryAfterSeconds(http, cap: retryAfterCap),
                                           underlying: error)
            }
            throw error
        }
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse, cap: Double) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(raw) else { return nil }
        return min(max(seconds, 0), cap)
    }

    /// Runs `operation`, retrying on a `RetryableHTTPFailure` (thrown by
    /// `ensureOK`) or a transient `URLError`, up to `policy.maxRetries` times,
    /// with exponential backoff + jitter between attempts. `progress` (when
    /// given) reports each retry without altering any of the caller's normal
    /// progress messages. Honors Swift Task cancellation: cancellation is
    /// checked before every attempt, and the injected `sleep` (real
    /// `Task.sleep` by default) throws `CancellationError` promptly instead of
    /// waiting out the backoff.
    static func withRetry<T>(
        label: String,
        policy: Policy = Policy(),
        progress: (@Sendable (String) -> Void)? = nil,
        sleep: @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
        },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let failure as RetryableHTTPFailure {
                guard attempt < policy.maxRetries else { throw failure.underlying }
                let delay = backoffDelay(attempt: attempt, retryAfter: failure.retryAfter, policy: policy)
                attempt += 1
                progress?("\(label) is busy (HTTP \(failure.statusCode)) — retrying in \(formatSeconds(delay))…")
                try await sleep(delay)
            } catch let urlError as URLError {
                guard urlError.code != .cancelled,
                      urlError.code != .timedOut || policy.retryTimeouts,
                      attempt < policy.maxRetries,
                      retryableURLErrorCodes.contains(urlError.code)
                else { throw urlError }
                let delay = backoffDelay(attempt: attempt, retryAfter: nil, policy: policy)
                attempt += 1
                progress?("\(label) had a network hiccup — retrying in \(formatSeconds(delay))…")
                try await sleep(delay)
            }
        }
    }

    private static func backoffDelay(attempt: Int, retryAfter: Double?, policy: Policy) -> Double {
        if let retryAfter { return retryAfter }
        let exponential = policy.baseDelay * pow(2.0, Double(attempt))
        return exponential + Double.random(in: 0...(exponential * 0.25))
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }
}
