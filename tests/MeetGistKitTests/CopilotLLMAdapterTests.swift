// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

private actor StubTransport: CopilotHTTPTransport {
    let responder: @Sendable (URLRequest) throws -> (Data, URLResponse)
    private(set) var requests: [URLRequest] = []

    init(responder: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.responder = responder
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try responder(request)
    }
}

private func okResponse(_ url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func jsonBody(_ request: URLRequest) -> [String: Any] {
    guard let body = request.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return [:]
    }
    return obj
}

@Suite struct CopilotLLMProviderResolutionTests {
    @Test func rejectsOnDeviceProvidersWithAClearMessage() {
        for provider in [
            Provider(id: "apple-foundation-models", name: "Apple On-Device", baseURL: "", notesStyle: .apple),
            Provider(id: "qwen-mlx-local", name: "Local Qwen", baseURL: "", notesStyle: .qwenMLX),
        ] {
            do {
                _ = try CopilotLLMs.make(provider: provider, key: nil)
                Issue.record("expected an unsupported error for \(provider.id)")
            } catch PipelineError.unsupported(let message) {
                #expect(message.contains("cloud provider"))
            } catch {
                Issue.record("wrong error type: \(error)")
            }
        }
    }

    @Test func rejectsAProviderWithNoNotesStyleConfigured() {
        let provider = Provider(id: "offline-whisper", name: "Offline Whisper", baseURL: "", transcribeStyle: .offline)
        #expect(throws: PipelineError.self) { _ = try CopilotLLMs.make(provider: provider, key: nil) }
    }

    @Test func geminiRequiresAKey() {
        let provider = ProviderCatalog.builtIn.first { $0.id == "gemini" }!
        #expect(throws: PipelineError.self) { _ = try CopilotLLMs.make(provider: provider, key: nil) }
        #expect(throws: PipelineError.self) { _ = try CopilotLLMs.make(provider: provider, key: "") }
    }

    @Test func chatRequiresAKeyAndAModel() {
        let provider = ProviderCatalog.builtIn.first { $0.id == "openai" }!
        #expect(throws: PipelineError.self) { _ = try CopilotLLMs.make(provider: provider, key: nil) }
        let noModel = Provider(id: "custom", name: "Custom", baseURL: "https://x", notesStyle: .chat, notesModel: "")
        #expect(throws: PipelineError.self) { _ = try CopilotLLMs.make(provider: noModel, key: "k") }
    }

    @Test func codexNeedsNoKey() throws {
        let provider = ProviderCatalog.builtIn.first { $0.id == "codex-cli" }!
        let llm = try CopilotLLMs.make(provider: provider, key: nil)
        #expect(llm.providerKind == "codex-cli")
    }
}

@Suite struct GeminiCopilotLLMTests {
    private func request(jsonSchema: String? = LiveCopilotPrompts.semanticJSONSchema) -> CopilotLLMRequest {
        CopilotLLMRequest(system: "You are a helpful assistant.", user: "Analyze this turn.",
                          jsonSchema: jsonSchema, maxOutputTokens: 300, timeout: 5, purpose: .semantic)
    }

    @Test func requestIncludesJSONModeSystemInstructionAndKey() async throws {
        let transport = StubTransport { req in
            let body = """
            {"candidates":[{"content":{"parts":[{"text":"{\\"meaning\\":\\"x\\"}"}]}}],
             "usageMetadata":{"promptTokenCount":42,"candidatesTokenCount":7}}
            """
            return (Data(body.utf8), okResponse(req.url!))
        }
        let llm = GeminiCopilotLLM(apiKey: "secret", baseURL: "https://generativelanguage.googleapis.com",
                                  model: "gemini-flash-latest", transport: transport)

        let response = try await llm.complete(request())

        #expect(response.text.contains("meaning"))
        #expect(response.inputTokens == 42)
        #expect(response.outputTokens == 7)
        let req = try #require(await transport.requests.first)
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
        #expect(!(req.url?.absoluteString.contains("secret") ?? true))
        let body = jsonBody(req)
        #expect((body["generationConfig"] as? [String: Any])?["responseMimeType"] as? String == "application/json")
        #expect((body["systemInstruction"] as? [String: Any]) != nil)
    }

    @Test func noJSONSchemaOmitsResponseMimeType() async throws {
        let transport = StubTransport { req in
            let body = #"{"candidates":[{"content":{"parts":[{"text":"free text"}]}}]}"#
            return (Data(body.utf8), okResponse(req.url!))
        }
        let llm = GeminiCopilotLLM(apiKey: "k", baseURL: "https://generativelanguage.googleapis.com",
                                  model: "gemini-flash-latest", transport: transport)
        _ = try await llm.complete(request(jsonSchema: nil))
        let body = jsonBody(try #require(await transport.requests.first))
        #expect((body["generationConfig"] as? [String: Any])?["responseMimeType"] == nil)
    }

    @Test func httpErrorSurfacesAsPipelineError() async {
        let transport = StubTransport { req in (Data("bad key".utf8), okResponse(req.url!, status: 401)) }
        let llm = GeminiCopilotLLM(apiKey: "k", baseURL: "https://generativelanguage.googleapis.com",
                                  model: "gemini-flash-latest", transport: transport)
        await #expect(throws: PipelineError.self) { _ = try await llm.complete(request()) }
    }
}

@Suite struct ChatCopilotLLMTests {
    private func request() -> CopilotLLMRequest {
        CopilotLLMRequest(system: "sys", user: "user", jsonSchema: LiveCopilotPrompts.semanticJSONSchema,
                          maxOutputTokens: 300, timeout: 5, purpose: .semantic)
    }

    @Test func requestIncludesBearerTokenAndJSONResponseFormat() async throws {
        let transport = StubTransport { req in
            let body = """
            {"choices":[{"message":{"content":"{\\"meaning\\":\\"x\\"}"}}],
             "usage":{"prompt_tokens":11,"completion_tokens":5}}
            """
            return (Data(body.utf8), okResponse(req.url!))
        }
        let llm = ChatCopilotLLM(apiKey: "sk-test", baseURL: "https://api.openai.com/v1",
                                 model: "gpt-4o-mini", transport: transport,
                                 jsonModeState: ChatJSONModeState())
        let response = try await llm.complete(request())

        #expect(response.inputTokens == 11)
        #expect(response.outputTokens == 5)
        let req = try #require(await transport.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = jsonBody(req)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(body["model"] as? String == "gpt-4o-mini")
    }

    @Test func fallsBackToNoResponseFormatAfterA400AndRemembersItForNextCall() async throws {
        let transport = StubTransport { req in
            let hadJSONMode = (jsonBody(req)["response_format"] != nil)
            if hadJSONMode {
                return (Data("unsupported parameter".utf8), okResponse(req.url!, status: 400))
            }
            let body = #"{"choices":[{"message":{"content":"ok text"}}]}"#
            return (Data(body.utf8), okResponse(req.url!))
        }
        let state = ChatJSONModeState()
        let llm = ChatCopilotLLM(apiKey: "k", baseURL: "https://example.test/v1", model: "m",
                                 transport: transport, jsonModeState: state)

        let first = try await llm.complete(request())
        #expect(first.text == "ok text")
        let firstRequests = await transport.requests
        #expect(firstRequests.map { jsonBody($0)["response_format"] != nil } == [true, false])

        // A second call within the same session must not retry JSON mode again.
        let second = try await llm.complete(request())
        #expect(second.text == "ok text")
        let allRequests = await transport.requests
        #expect(allRequests.map { jsonBody($0)["response_format"] != nil } == [true, false, false])
    }
}

@Suite struct CodexCLICopilotLLMTests {
    private actor RecordingGenerator: CodexCLIGeneralGenerating {
        private(set) var calls: [(prompt: String, effort: String, timeout: TimeInterval, outputSchema: String?)] = []
        let response: String
        init(response: String) { self.response = response }
        func generate(prompt: String, reasoningEffort: String, timeout: TimeInterval, outputSchema: String?) async throws -> String {
            calls.append((prompt, reasoningEffort, timeout, outputSchema))
            return response
        }
    }

    @Test func semanticRequestsAlwaysForceReasoningEffortNoneRegardlessOfConfiguredEffort() async throws {
        let generator = RecordingGenerator(response: #"{"meaning":"x"}"#)
        let llm = CodexCLICopilotLLM(reasoningEffort: "high", generator: generator)
        let request = CopilotLLMRequest(system: "sys", user: "user", jsonSchema: LiveCopilotPrompts.semanticJSONSchema,
                                        maxOutputTokens: 300, timeout: 45, purpose: .semantic)
        let response = try await llm.complete(request)

        #expect(response.text.contains("meaning"))
        #expect(response.inputTokens == nil, "Codex CLI exposes no token usage")
        let calls = await generator.calls
        #expect(calls.count == 1)
        #expect(calls.first?.effort == "none")
        #expect(calls.first?.timeout == 45)
        #expect(calls.first?.outputSchema == LiveCopilotPrompts.semanticJSONSchema)
        #expect(calls.first?.prompt.contains("sys") == true)
        #expect(calls.first?.prompt.contains("user") == true)
    }

    @Test func v2RequestsAlsoForceReasoningEffortNoneRegardlessOfConfiguredEffort() async throws {
        // Plan §7 "Scheduling": "Codex answers use the same fast path ... and
        // reasoning effort 'none' unless measurements show 'low' is needed" —
        // P6's measurement (docs/live-copilot-plan.md §13) found "none"
        // acceptable, so both V2 purposes stay on the same policy as
        // `.semantic`.
        let generator = RecordingGenerator(response: #"{"answer":"x","known_from_meeting":[],"from_context":[],"assumptions":[],"confidence":"low"}"#)
        let llm = CodexCLICopilotLLM(reasoningEffort: "high", generator: generator)
        for purpose: CopilotPurpose in [.suggestAnswer, .ask] {
            let request = CopilotLLMRequest(system: "sys", user: "user", jsonSchema: LiveCopilotPrompts.answerJSONSchema,
                                            maxOutputTokens: 500, timeout: 60, purpose: purpose)
            _ = try await llm.complete(request)
        }
        let calls = await generator.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.effort == "none" })
    }

    @Test func invalidStoredEffortNormalizesToNone() {
        let llm = CodexCLICopilotLLM(reasoningEffort: "not-a-real-value")
        #expect(llm.reasoningEffort == "none")
    }

    @Test func unavailableCodexThrowsAClearUnsupportedError() async {
        struct AlwaysUnavailable: CodexCLIGeneralGenerating {
            func generate(prompt: String, reasoningEffort: String, timeout: TimeInterval, outputSchema: String?) async throws -> String {
                throw PipelineError.unsupported("Codex CLI unavailable. Install it and run `codex login` first.")
            }
        }
        let llm = CodexCLICopilotLLM(reasoningEffort: "none", generator: AlwaysUnavailable())
        let request = CopilotLLMRequest(system: "", user: "u", maxOutputTokens: 100, timeout: 10, purpose: .semantic)
        await #expect(throws: PipelineError.self) { _ = try await llm.complete(request) }
    }
}

/// F4 (2026-09-27): `CodexCLIGeneralProcessGenerator` reads the user's own
/// `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) to preserve their
/// configured model when it adds `--ignore-user-config` for latency — these
/// tests exercise just that parsing, pointed at a scratch `CODEX_HOME` via
/// the env var so nothing here touches the real `~/.codex`.
@Suite(.serialized) struct CodexUserConfiguredModelTests {
    private func withScratchCodexHome(_ configText: String?, _ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetgist-codex-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let configText {
            try? configText.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        let previous = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", dir.path, 1)
        defer {
            if let previous { setenv("CODEX_HOME", previous, 1) } else { unsetenv("CODEX_HOME") }
        }
        body()
    }

    @Test func readsAQuotedTopLevelModelLine() {
        withScratchCodexHome("model = \"gpt-6-luna\"\nmodel_reasoning_effort = \"xhigh\"\n") {
            #expect(CodexCLIGeneralProcessGenerator.codexUserConfiguredModel() == "gpt-6-luna")
        }
    }

    @Test func ignoresModelReasoningEffortLine() {
        withScratchCodexHome("model_reasoning_effort = \"xhigh\"\npersonality = \"pragmatic\"\n") {
            #expect(CodexCLIGeneralProcessGenerator.codexUserConfiguredModel() == nil)
        }
    }

    @Test func stripsTrailingCommentAndSingleQuotes() {
        withScratchCodexHome("model = 'gpt-6-astra' # inline comment\n") {
            #expect(CodexCLIGeneralProcessGenerator.codexUserConfiguredModel() == "gpt-6-astra")
        }
    }

    @Test func missingConfigFileReturnsNil() {
        withScratchCodexHome(nil) {
            #expect(CodexCLIGeneralProcessGenerator.codexUserConfiguredModel() == nil)
        }
    }

    @Test func emptyModelValueReturnsNil() {
        withScratchCodexHome("model = \"\"\n") {
            #expect(CodexCLIGeneralProcessGenerator.codexUserConfiguredModel() == nil)
        }
    }
}
