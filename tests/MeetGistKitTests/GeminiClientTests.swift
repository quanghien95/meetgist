// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

/// P2-1 regression: the Gemini API key must travel via the `x-goog-api-key`
/// header, never a `?key=` query parameter (more likely to end up in logs,
/// proxies, or crash reports). `GeminiHTTP.authed(_:)` is the single place
/// every Gemini request is built, so this only needs to check it directly.
@Suite struct GeminiClientTests {
    @Test func authedRequestCarriesKeyInHeaderNotURL() {
        let http = GeminiHTTP(apiKey: "secret-key-123", base: "https://generativelanguage.googleapis.com")

        let upload = http.authed("/upload/v1beta/files")
        let poll = http.authed("/v1beta/files/abc123")
        let generate = http.authed("/v1beta/models/gemini-flash-latest:generateContent")

        for request in [upload, poll, generate] {
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret-key-123")
            let urlString = request.url?.absoluteString ?? ""
            #expect(!urlString.contains("key="))
            #expect(!urlString.contains("secret-key-123"))
        }
    }
}
