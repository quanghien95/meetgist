# Live Assist follow-up — 2026-10-03

Checkpoint of the current implementation and outstanding work. No API keys,
meeting content, or raw provider responses belong in this document.

## Current validation

- User retested live transcription and confirmed that System and Me are now
  separated correctly on their current setup. This is not a guarantee across
  all audio devices or acoustic environments.
- Latest checks after the compact recording-control row: `make test` passed
  (243 Kit tests, 27 App tests; Python: 43 tests, one skipped), `swift build`
  and `swift build -c release` passed. The optional native microphone check
  previously passed mono delivery and stop/restart; it does not measure echo
  suppression. The most recent UI layout has not been visually verified.
- Live microphone echo cancellation uses Apple Voice Processing. Canonical
  `mic.m4a` capture remains raw; the live path and post-meeting preprocessing
  remain separate.

## Outstanding issues

### 1. Gemini API does not work in Live Assist — investigate first

User reports that adding a Gemini API key does not produce a working Live
Assist provider. Not yet reproduced or diagnosed; do not assume the key is
invalid or that Gemini itself is unavailable. Scope outside Live Assist is
not confirmed.

Next checks:

- Follow key saving/loading, selected Live Assist provider and model override
  through `AppState+LiveAssist.swift` and `CopilotLLMAdapters.swift`.
- Check the Gemini request schema, endpoint, model availability, HTTP status,
  timeout and response parsing with the user's configured provider. Keep keys
  and meeting text out of diagnostic output.
- Verify both automatic analysis and manual Suggest/Ask, plus switching the
  provider during recording. Failure must not interrupt local transcription.

Done when the configured Gemini provider completes a real request and errors
are actionable without exposing credentials or private text.

### 2. Make assistance on demand to avoid continuous token usage

User wants AI assistance only when needed, preferably one Suggest button.
Current implementation still calls the semantic LLM as System turns arrive;
turning Auto suggest off does not stop those calls. The current Suggest button
also depends on `lastQuestionID` from that background analysis.

Proposed direction discussed with the user, not implemented yet:

- Keep local System/Me transcription running independently.
- Stop background semantic analysis and automatic question detection in the
  on-demand workflow. Do not add hidden periodic LLM summaries.
- Make Suggest available from transcript context without a pre-detected
  question. One logical request should explain the latest speaker's intent
  and suggest a concise answer, flagging missing information.
- Start with a bounded recent conversation window (proposal: 2–3 minutes,
  with a character cap), both channels, prioritizing the latest System turn,
  and optional manually selected context. Older context may be omitted.
- Handle not-yet-finalized ASR, repeated clicks, cancellation and stale results.
  Reuse an unchanged result; keep retries explicit rather than recurring.
- Preserve an optional explicit Ask flow for custom questions.

Acceptance: no Live Assist LLM requests while idle, recording, receiving
transcript or changing tabs unless the user explicitly requests assistance;
Suggest works without earlier background analysis, including after a provider
failure. Audio capture and post-meeting provider behavior remain unchanged.

### 3. Provider status is ambiguous and errors lack diagnostics

The shared panel header can show “Provider unavailable — retrying…” on the
Transcript tab although local ASR is still working. In the inspected test
session, metrics recorded four failed semantic requests for Codex CLI with
`gpt-6-luna`; the failure cause was not persisted, so timeout/auth/model/network
causes remain unconfirmed.

Separate transcription and assistance status. Surface safe error categories
and useful retry feedback without persisting raw responses, credentials or
meeting text. Current semantic timeout defaults are 8s for HTTP, 45s for
Codex; after three consecutive failures the semantic scheduler waits 30s and
tries again when a later turn kicks the scheduler. Revisit this automatic
behavior with the on-demand change.

### 4. Playback becomes slightly quieter with live capture

User reports slightly reduced speaker playback volume when recording.
Apple Voice Processing other-audio ducking is a likely explanation, not a
measured diagnosis. The live mic already uses minimum ducking, advanced
voice-dependent ducking off, and AGC off. Minimum is not zero ducking.

Measure playback with live mic capture enabled/disabled and consider supported
alternatives if necessary. Preserve the working System/Me separation; do not
silently disable echo cancellation or compensate by changing system volume.
