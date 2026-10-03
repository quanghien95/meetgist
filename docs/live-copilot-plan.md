# Live Meeting Copilot — implementation plan and handoff record

Status: **approved plan, implementation in progress** (branch `feature/live-copilot`).
This file is the single handoff document for every agent working on Live
Copilot. Read it fully, then read `AGENTS.md` and `docs/ARCHITECTURE.md`,
before touching code. **Update the Progress log (§0) and any decision you
change before you finish a work session.**

Scope now: **V1 (Live Understanding) and V2 (Live Assistant)**.
V3 (Meeting Memory / RAG) and V4 (Proactive Copilot) are **not** to be
implemented — see §12 for the extension points only.

---

## 0. Progress log

| Phase | Owner | Status | Notes |
| --- | --- | --- | --- |
| P0 Plan + repo inspection | planner | done | this document |
| P1 Kit core: endpointing, turns, live ASR worker, runtime config | agent | done | §5.1–§5.4 |
| P2 Kit core: CopilotLLM adapters, semantic analyzer, LiveMeetingState, engine | agent | done | §5.5–§5.9 |
| P3 App integration: audio taps, AppState+LiveAssist, panel UI, settings, persistence | agent | done | §5.10–§5.14 |
| P4 V1 validation: tests, real measurements, docs | agent | done | §8, §9 |
| P4-fix Coordinator code-review findings (F1-F4): frame ordering, system PCM extraction, benchmark stall, Codex CLI latency | agent | done | §13, this entry |
| P4b Mic-track echo fix (remote voices leaking into Me) | agent | removed | removed on 2026-10-03 at user request; canonical audio is transcribed directly |
| P5 V2: Suggest Answer, Ask Meet Gist, manual project context | agent | done | §7 |
| P6 V2 validation + final report | agent | done | §8, §9, §13 |

Append dated entries below as work lands (what changed, what was verified,
what is still unverified):

- 2026-09-27 — plan written after inspecting the repo (see §2).
- 2026-09-27 — **P1/P2 landed** (`MeetGistKit` only; no `app/Sources` changes,
  per scope). Baseline before this work: `make test` 112 Swift Testing tests
  (21 suites) + 31 Python unittest tests, all green; `swift build` green.
  After this work: `make test` **180 Swift Testing tests (32 suites)** + **39
  Python unittest tests**, all green (68 new Swift tests, 8 new Python tests,
  zero pre-existing tests changed or broken); `swift build` and `swift build
  --target MeetGistKit` both green with no new warnings.

  Files added (all under `Sources/MeetGistKit/LiveCopilot/` unless noted):
  `LiveTypes.swift` (`LiveTrack`, `LiveTurnTimings`, `LiveTranscriptTurn`,
  `SpeechSegment`, `RealtimeTranscriber`, the `LiveContextProvider`/
  `ContextSnippet` V3 seam), `LiveTextNormalize.swift` (shared
  normalize/stem/dedup/evidence-appears helpers), `SpeechEndpointer.swift`
  (`LiveEndpointerConfig` + the pure/synchronous endpointer),
  `LiveAudioFeed.swift` (downmix/resample/framing), `LiveTurnFilter.swift`,
  `CopilotLLM.swift` (protocol/request/response/purpose/`CopilotLLMs.make`),
  `CopilotLLMAdapters.swift` (`CopilotHTTPTransport`, Gemini/Chat/Codex
  adapters, `ChatJSONModeState`, `CodexCLIGeneralProcessGenerator`),
  `LiveCopilotPrompts.swift`, `SemanticResult.swift` (+ tolerant parser),
  `LiveMeetingState.swift` (+ `LiveItem`/`LiveQuestion`/`LiveActionItem`),
  `LiveMetrics.swift`, `LiveCopilotPersistence.swift`,
  `LiveAssistSnapshot.swift`, `LiveCopilotEngine.swift`,
  `QwenLiveTranscriber.swift`, `LiveASRRuntimeManager.swift`; plus
  `Sources/MeetGistKit/Resources/live_asr_worker.py` (registered in
  `Package.swift`). Tests added: `tests/MeetGistKitTests/LiveCopilot*.swift`,
  `CopilotLLMAdapterTests.swift`, `LiveMeetingStateTests.swift`,
  `LiveASRRuntimeTests.swift`, `tests/test_live_asr_worker.py`.

  Deviations from this document (folded into §3/§5.4 below — **latency-first
  decision, coordinator-directed**): the live ASR runtime now pins the
  **0.6B-4bit** model by default (not 8bit); the endpointer's hangover/soft-
  max/hard-max defaults are shorter (0.8 s / 10 s+0.35 s / 20 s, not 0.8 s /
  25 s+0.3 s / 45 s); the semantic prompt uses 2–3 recent turns and a
  smaller compact-state view (not 5 / last-12), a lower `maxOutputTokens`
  (350, not 700) and a shorter HTTP timeout (8 s, not 12 s); Codex CLI
  semantic calls always force `model_reasoning_effort=none` regardless of the
  provider's configured notes effort. Everything else matches this document.
  Also: V2 (`suggestAnswer`/`ask`) is intentionally **not implemented** — only
  the `CopilotPurpose`/`LiveContextProvider`/`ContextSnippet` seams exist, per
  this task's explicit scope (V2 lands in P5).

  Known gaps / unverified (left for P3+): no real-audio verification (the
  endpointer/feed are exercised only with synthetic frames); the live ASR
  worker has not been run against a real installed model (P1 explicitly
  excludes downloading the model); no measurements yet (P4); persistence
  (`LiveCopilotPersistence`) is exercised only indirectly through the engine
  tests, not with dedicated throttling-timing tests; `LiveAudioFeed`'s
  timestamping is a documented best-effort approximation (own running clock,
  not per-frame host-time re-derivation) with no dedicated unit tests (it's
  not in this phase's required test list and needs real `AVAudioEngine`
  buffers to test meaningfully — left for P3).

- 2026-09-27 — **P3 landed** (app integration). Files added:
  `Sources/MeetGistKit/LiveCopilot/LiveAssistSession.swift` (the Kit
  orchestrator: PCM sources → `LiveAudioFeed` → `SpeechEndpointer` (per
  track) → `RealtimeTranscriber` → `LiveTranscriptTurn` →
  `LiveCopilotEngine`; start/stop/pause/resume; one automatic ASR restart;
  never publishes a turn once stopped mid-flight),
  `LiveAudioSources.swift` (`SystemAudioLiveSource` wrapping
  `SessionRecorder`'s new live sink, `LiveMicTap` — a dedicated
  `AVAudioEngine` input tap, no voice processing), plus the `LivePCMChunk`/
  `LiveAudioSource` seam in `LiveTypes.swift`;
  `app/Sources/AppState/AppState+LiveAssist.swift` (settings
  `liveAssistEnabled`/`liveAssistProviderID`/`liveAnalyzeMic`,
  `ProviderModelSlot.live`, start/stop/pause/resume wiring, provider
  resolution through `effective(_:)`/`key(for:)`, the
  `liveTranscriberFactory`/`copilotLLMFactory`/`liveAudioSourceFactory` test
  seams, `LiveAssistFactories` production factories);
  `app/Sources/LiveAssist/LiveAssistPanel.swift` (floating non-activating
  `NSPanel`, pattern: `MiniController`), `LiveAssistSettingsView.swift`
  (Settings "Live Assist" GroupBox: enable, provider picker limited to cloud
  Notes providers, model override, analyze-mic toggle, Live ASR
  install/remove + status, privacy note), `LiveAssistLabels.swift` (the
  Vietnamese/English content-language table, keyed off `notesLanguage`, kept
  separate from the app's own en/zh UI `LStr` table). Changed:
  `Sources/MeetGistKit/Recorder.swift` (`SystemAudioRecorder.setLivePCMSink`,
  called only after the existing append logic and only when not paused —
  `nil` sink is byte-for-byte identical to before), `SessionRecorder.swift`
  (`recordingAnchorHostNs`, `setLiveSystemSink` pass-through — both purely
  additive), `app/Sources/AppState/AppState.swift` (new stored
  properties/settings/factories/`liveASRRuntime`, `ProviderModelSlot.live`),
  `AppState+Recording.swift` (`startLiveAssistIfEnabled` after `rec.start()`
  succeeded, own `Task`; `stopLiveAssist()` at the very start of
  `stopRecording()`, hard 2s cap; pause/resume forwarding),
  `AppState+Providers.swift` (`setModel` notifies a running session on the
  `.live` slot), `AppState+Runtimes.swift` (`installLiveASRRuntime`/
  `removeLiveASRRuntime`), `MenuBarPopover.swift` (Live Assist toggle),
  `SettingsView.swift` (inserts the new GroupBox), `L10n.swift` (new
  `LStr`s, en + zh), `MeetGistApp.swift` (installs the panel like
  `installMiniController`). Small additive Kit API needed for the wiring:
  `LiveCopilotEngine.setTranscriptionStatus(_:)`/`recordUIUpdate(forTurnID:
  atHostNs:)`, `LiveMetrics.recordUIUpdate`, `LiveAssistSnapshot.Status
  .liveASRNotInstalled`, `QwenLiveTranscriber.resolveWorkerScriptURL()` (so
  app code — a different module/target — can find the bundled worker
  script without reaching into `MeetGistKit`'s own `Bundle.module`).

  Tests: `tests/MeetGistKitTests/LiveAssistSessionTests.swift` (5 tests:
  turn flows end to end with a fake audio source/transcriber; pause
  finalizes-and-discards an incomplete segment and resume still works; ASR
  failure degrades status with exactly one automatic restart attempt, never
  a second one; stop while a transcription is in flight never publishes;
  mic tap failure falls back to Speaker-only live mode),
  `tests/MeetGistAppTests/AppStateLiveAssistTests.swift` (5 tests: disabled
  → no factories called; factory failures surface only through
  `liveAssist.snapshot.status`, `state`/`lastError`/`recorder`/
  `processTask` all untouched; defaults; `stopLiveAssist()` with nothing
  running is a no-op; a normal cloud processing job still succeeds with
  Live Assist enabled-but-failing), plus one added test in the existing
  `MeetingStoreTests.swift` confirming `<session>/live/` doesn't change
  `MeetingStore.list`/`Exporter` output (delete already trashes the whole
  session directory, verified by reading `AppState.moveMeetingToTrash` —
  no code path reads inside a meeting directory selectively). `make test`:
  **191 Swift Testing tests (34 suites)** + **39 Python unittest tests**,
  all green (11 new Swift tests, 2 new suites, 0 new/changed Python tests,
  zero pre-existing tests broken); `swift build` and `swift build --target
  MeetGistApp`/`--target MeetGistKit` all green, no new warnings.

  Deviations/notes: the plan's exact wording "own status setup" is realized
  as `LiveAssistSnapshot.Status.liveASRNotInstalled` (a new, additive
  status case) rather than a separate `LiveAssistState.setupError` field —
  simpler, and it already flows through the existing snapshot-stream/UI
  path. `LiveAssistPanel`'s V1 content omits the V2-only rows ("Gợi ý trả
  lời" button, "Hỏi Meet Gist" field) since V2 isn't implemented (per
  scope); everything else in §5.12 is present. Persistence
  (`LiveCopilotPersistence`) needed no changes — it already worked exactly
  as wired into the engine in P1/P2.

  Known gaps / unverified (left for P4/manual): real `AVAudioEngine` +
  `AVAudioRecorder` coexistence (R1) — `LiveMicTap` compiles and its
  `start()`/`stop()` logic is unit-tested with a fake source, but it has
  never captured real audio in a real recording; toggling Live Assist
  mid-recording, killing the worker mid-meeting, and disconnecting network
  mid-meeting are all implemented (their unit tests cover the underlying
  engine/session behavior) but not manually exercised end to end. See §11's
  manual checklist below.

- 2026-09-27 — **P4 landed** (real measurements + one real bug fix). Full
  results in §13; summary here:
  - Installed the real, pinned 4-bit Live ASR runtime via
    `LiveASRRuntimeManager.install()` (the app's own code path) into this
    machine's actual Application Support root, and downloaded the 8-bit
    alternative (pinned revision, same runtime Python, no bypass of
    hash/revision pinning) into a scratch dir under `/private/tmp/claude-501/`.
  - Built `tests/MeetGistKitTests/LiveCopilotBenchmarkTests.swift`
    (`MEETGIST_LIVE_BENCH=1`, excluded from `make test`): synthesizes 12
    mixed EN/VI + technical-term meeting turns with macOS `say`
    ("Samantha"/"Linh"), runs them through the real `live_asr_worker.py`
    (direct protocol, for worker-reported `load_ms`/`asr_ms`/
    `peak_memory_mb`) for both quantizations, a `QwenLiveTranscriber` smoke
    check, `CodexCLICopilotLLM` semantic calls, a Keychain-gated Gemini/
    OpenAI check, and end-to-end `LiveAssistSession` runs.
  - **Found and fixed a real bug**: every real Codex CLI semantic call
    failed (12/12, HTTP 400 `invalid_json_schema`) because
    `LiveCopilotPrompts.semanticJSONSchema` didn't meet OpenAI's strict
    structured-output requirements (`additionalProperties: false` on every
    object level; every property listed in `required`). Fixed in
    `LiveCopilotPrompts.swift`. This means Live Assist's Codex CLI provider
    would never have worked in real use before this fix — the most
    important outcome of this measurement pass.
  - ASR benchmark numbers are real and reproduced twice (see §13): kept the
    4-bit default — real latency/memory numbers and comparable transcript
    quality on both quantizations support the existing latency-first
    decision.
  - The automated benchmark's Codex/end-to-end sections did not finish in
    a practical time on this machine on either attempt (see §13 "Known
    limitations"), so Codex CLI semantic latency (p50 ≈ 9s, p90 ≈ 11s, 10
    real calls) was measured by invoking the exact same `codex exec`
    command-line contract directly, and the end-to-end number is an
    analytical estimate, not directly measured — both explicitly flagged as
    such in §13, per "never turn a benchmark result into a project fact
    without stating uncertainty."
  - Gemini/OpenAI: not measured (no Keychain key on this machine, checked
    without printing/logging any key).
  - `make test`: **192 Swift Testing tests (35 suites)** + **39 Python
    unittest tests**, all green (1 new suite/test — the env-gated benchmark,
    which is skipped by default and does not count toward "passing" claims
    about real hardware/network behavior); `swift build` and `swift build
    --target MeetGistApp` both green.
  - Manual verification checklist (§11): filled in as **unverified** for
    every item requiring a real running `MeetGistApp`/OS permissions/real
    audio — this environment cannot provide those. See §11 for exactly
    what was and wasn't covered by unit tests instead.

- 2026-09-27 — **P4-fix landed**: fixed 4 coordinator code-review findings
  (F1-F4) against the P1-P4 code, per **latency-first** priority (realtime
  speed over accuracy — the post-meeting pipeline is the accuracy backstop).
  Baseline before this work: `make test` 192 Swift Testing tests (35 suites)
  + 39 Python unittest tests, all green. After this work: **205 Swift
  Testing tests (37 suites)** + **39 Python unittest tests**, all green (13
  new Swift tests, 2 new suites — `SystemAudioPCMExtractionTests`,
  `CodexUserConfiguredModelTests` — zero pre-existing tests changed or
  broken); `swift build` and `swift build --target MeetGistApp` both green,
  no new warnings. Full details below; new measurement table at the end of
  §13.

  **F1 — frame ordering / actor reentrancy**
  (`Sources/MeetGistKit/LiveCopilot/LiveAssistSession.swift`). Root cause:
  every 30 ms frame spawned its own unstructured `Task { await
  self?.handleFrame(...) }`. Unstructured tasks have no FIFO guarantee for
  *when they actually enter the actor* — under real scheduling pressure
  (many tasks created in a tight loop, e.g. one `LiveAudioFeed.ingest` call
  can synchronously emit dozens of 30 ms frames), a later frame's task could
  reach `SpeechEndpointer.process` before an earlier one, especially while
  another frame's task was suspended awaiting the ~300 ms ASR call —
  corrupting segment timing and letting turns reach `LiveCopilotEngine.ingest`
  out of speech order. Fix: two ordered, bounded stages replace the
  per-frame `Task`. (1) Per track, `LiveAudioFeed`'s callback now
  synchronously `yield`s into that track's own unbounded `AsyncStream`
  (never spawns a `Task`); exactly one loop task per track
  (`runFrameLoop`) consumes it and calls the (pure, synchronous) endpointer
  in strict yield order — there is only one reader, so frames can never be
  reordered. (2) Finalized segments from either track go into one bounded
  queue (`pendingSegments`, default cap 4, drop-oldest-**mic**-first — the
  same policy `QwenLiveTranscriber` already used for its own queue, now
  applied at the session level since the session — not the transcriber —
  is what serializes ASR calls one at a time); exactly one ASR loop task
  (`runASRLoop`) drains it, so turn IDs/engine ingestion always happen in
  strict finalization order and ASR latency never blocks frame ingestion
  (stage 1 keeps running independently). `stop()` finishes both frame
  streams and wakes the ASR loop's waiter so both stages exit promptly, but
  deliberately does **not** await the ASR loop's own completion — an
  in-flight `transcriber.transcribe` may still be resolving (e.g. a real
  timeout, or a test holding it open deliberately), and `stop()` must return
  promptly regardless; the pre-existing `isRunning` re-check inside
  `transcribeAndIngest` (unchanged) still guarantees nothing publishes after
  a stop. Tests added (`tests/MeetGistKitTests/LiveAssistSessionTests.swift`,
  both fail reliably against the old per-frame-`Task` design):
  `framesAndSegmentsStayOrderedAndUnlostWhileASRIsBusy` (3 speaker segments,
  each fed as one burst of dozens of 30 ms frames — exactly the pattern that
  used to race — against a transcriber that responds slowly; asserts all 3
  segments are dispatched, none lost, strictly increasing `startedAt`, and
  the final turn ID/text arrive in speech order) and
  `pendingSegmentQueueDropsOldestMicSegmentFirstWhenBackloggedByASR` (backs
  up 3 more segments behind one hung in-flight call at capacity 2; asserts
  the eventually-transcribed set always keeps a queued speaker segment over
  a queued mic one, regardless of the mic/speaker frame loops' relative
  scheduling order). Both pass reliably across 6 repeated runs.

  **F2 — system PCM extraction**
  (`Sources/MeetGistKit/Recorder.swift`, `SystemAudioRecorder.pcmChunk`).
  Root cause: the function passed a single-`AudioBuffer`-sized
  `AudioBufferList` (`bufferListSize: MemoryLayout<AudioBufferList>.size`)
  to `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`. Screen­
  CaptureKit audio is commonly delivered as **non-interleaved** Float32
  stereo — one `AudioBuffer` per channel — which needs 2 buffer-list
  entries; the previous call fails outright for that shape (`bufferListOut`
  too small), silently returning `nil`, i.e. **no live system audio tap at
  all** whenever SCStream hands back non-interleaved audio. Even a
  hypothetical success path (e.g. if it happened to be sized right by luck)
  would then feed `LiveAudioFeed.downmix`, which assumes one interleaved
  buffer — concatenating two independent per-channel buffers and averaging
  the result as if interleaved would produce garbage, not silence.
  Fixed by: querying `bufferListSizeNeededOut` first, allocating a correctly
  sized list via `AudioBufferList.allocate(maximumBuffers:)` (channel count
  is always a safe upper bound), checking `kAudioFormatFlagIsNonInterleaved`,
  and — when set — averaging every channel's buffer per frame and emitting
  **mono directly** (`channels = 1`), never concatenating. Interleaved input
  (a single buffer, the pre-existing behavior) is copied through unchanged.
  `pcmChunk` is unchanged in every other respect and still only ever runs
  when `livePCMSink` is set (byte-for-byte identical with no sink, as
  before) — access was widened from `private` to internal only so
  `@testable import` tests can call it directly.
  `LiveMicTap.chunk(from:when:)` (`LiveAudioSources.swift`) was checked
  separately and is **already correct**: `AVAudioPCMBuffer.floatChannelData`
  is always per-channel non-interleaved regardless of the underlying
  hardware format, and it already interleaves multi-channel data correctly
  frame-by-frame before handing it to `LiveAudioFeed` — no change needed.
  Tests added (`tests/MeetGistKitTests/SystemAudioPCMExtractionTests.swift`,
  4 tests): builds real `CMSampleBuffer`s for both layouts via
  `CMAudioFormatDescriptionCreate` +
  `CMSampleBufferSetDataBufferFromAudioBufferList` (the documented inverse
  of the API `pcmChunk` itself calls) and asserts interleaved stereo is
  copied through unchanged, non-interleaved stereo produces the exact
  per-frame average (not a concatenation — the old bug's failure mode),
  non-interleaved mono is copied through unchanged, and a non-interleaved
  3-channel buffer averages all 3 channels per frame.
  **Follow-up noted, not fixed** (out of scope per the task's "minimal
  Recorder.swift change" instruction): `updateSystemPeak` (same file, a few
  lines above `pcmChunk`) uses the exact same single-buffer-sized
  `AudioBufferList` pattern this fix replaced, and is suspected of the same
  non-interleaved bug — the live **system level meter** (not the Live
  Assist PCM tap) may silently read as digital silence whenever
  ScreenCaptureKit delivers non-interleaved audio. This needs the same real
  ScreenCaptureKit session to actually confirm (this environment can't grant
  Screen Recording permission), so it's flagged here for manual
  verification rather than changed speculatively. See §11's manual
  checklist, new row.

  **F3 — unexplained benchmark stall** (P4's report: the Codex/e2e section
  of the automated benchmark hung once for ~13 minutes with no output after
  the ASR section). Investigated `QwenLiveTranscriber` (pipe draining,
  readline loop, continuation resumption on every path — timeout, cancel,
  worker-exit — all already correct: every dispatched request's
  continuation is resolved exactly once, `shutdown()` rejects any
  outstanding/dispatched request so nothing can hang past it),
  `CodexCLIGeneralProcessGenerator`/`ChildProcess` (timeout is enforced via
  `ChildProcess.run(timeout:)`, itself backed by a real
  `DispatchWorkItem`-based timer independent of task cancellation; stdin is
  a real file handle closed via `defer`; the process group is killed via
  `kill(-pid, …)`, not just the direct child — all already correct), and
  `LiveCopilotEngine`'s scheduler (`withTimeout` races the real operation
  against a `Task.sleep`, `cancelAll()`s the loser, generation/seq guards
  prevent any stale publish — no continuation leak, no batch that never
  starts). **No deadlock or leak was found anywhere in the production Kit
  code.** The stall is fully explained by two things in the *benchmark
  harness itself*, both fixed: (a) the harness's `print()` calls go to a
  non-terminal (piped) stdout under `swift test`, which is fully
  block-buffered by default rather than line-buffered — a real (bounded)
  slow patch later in the one monolithic `@Test func` could produce no
  visible output for minutes even while genuinely making progress, which is
  indistinguishable from a hang when watching the log; (b) the single
  monolithic test had **no section-level wall-clock cap** — 12 real Codex
  calls plus 3 end-to-end runs (each with its own 45-60s *per-call* ceiling)
  could legitimately sum to several minutes under real system load (the
  original P4 entry's own "Known limitations" independently observed heavy
  `mds`/Spotlight CPU load during that session), and nothing would report
  intermediate results if a later real call ran unusually slowly. Fixed by
  splitting `tests/MeetGistKitTests/LiveCopilotBenchmarkTests.swift` into 3
  independent `@Test`s (`asrOnlyBenchmark`, `codexSemanticOnlyBenchmark`,
  `endToEndBenchmark`), each wrapped in a new `runWithHardDeadline(seconds:
  label:)` helper (same race-a-`Task.sleep`-against-the-real-work pattern as
  `LiveCopilotEngine.withTimeout`, proven correct there) so no section can
  ever again silently consume the whole run, plus `setvbuf(stdout, nil,
  _IOLBF, 0)` so progress prints flush immediately instead of buffering.
  Section deadlines: ASR-only 240s, Codex-only 300s, end-to-end 300s (each
  generous vs. the real numbers below). **Re-ran all 3 for real** on this
  machine after the fix — see the new measurement table below; total
  combined wall time across all 3 was ~4 minutes, no stall reproduced, and
  each section finished well inside its deadline. No regression test beyond
  the split itself was needed since no actual hang was found in production
  code — the fix *is* the regression test (a section can structurally no
  longer block another's results, and a future genuine hang would now
  surface as a recorded `Issue` with a clear "did not finish within its Ns
  hard wall-clock limit" message instead of silence).

  **F4 — Codex CLI latency** (coordinator's mid-task priority update:
  optimize Codex CLI latency first, since no Gemini/Groq key will be added
  and Codex CLI is the only live LLM provider for now). Measured cheaply
  with direct `codex exec` calls before changing any code (all real calls,
  this machine, `codex-cli 0.157.1`, ChatGPT-account login):
  - **Floor latency**: a trivial `codex exec … "hi"` (no schema) already
    took ~6.5-6.9s across repeated real calls — most of a semantic call's
    latency is fixed per-call overhead, not our prompt content.
  - **`--output-schema` cost**: the real semantic prompt + schema (vs. the
    same trivial call) added only ~1.5s (~8.2-8.3s vs ~6.5-6.9s) — schema
    validation itself is cheap; the difference is mostly a longer/ structured
    output.
  - **Root cause of the fixed overhead, found via `--json` event
    timestamps**: `usage.input_tokens` was **~20,459** on a call whose real
    content was a two-word prompt. Codex CLI loads the user's full
    `~/.codex/config.toml` — in this case 10 enabled plugins (github,
    browser, chrome, documents, pdf, spreadsheets, presentations,
    template-creator, codex-app-tools, visualize) and 2 MCP servers
    (`node_repl`, `computer-use`) — into the model's context on **every**
    invocation, none of which a live JSON-only semantic call needs.
    Suppressing just `plugins`/`mcp_servers` via `-c plugins={} -c
    mcp_servers={}` (keeping the rest of the user's config) did **not**
    reduce `input_tokens` (still ~20,320) — the overhead isn't (only) the
    plugin/MCP tool schemas, so that path was abandoned.
  - **`--ignore-user-config`**: dropped `input_tokens` to ~14,914 (11,008 of
    those server-side cached) and cut real wall-clock latency from
    ~6.5-6.9s to ~4.1-4.4s for the trivial call — a genuine, reproducible
    win. **Caveat found**: `--ignore-user-config` also silently falls back
    to a *different* built-in default model (`gpt-6-astra` on this
    account) which **rejects** `model_reasoning_effort=none` — the value
    the semantic path always forces (plan §3) — with a real HTTP 400. So
    `--ignore-user-config` alone is unsafe; it must be paired with an
    explicit `-m <model>` that both accepts `effort=none` and is one the
    account actually has (verified with a real call — `-m
    bogus-model-xyz` reliably 400s with a clear message, confirming invalid
    names fail fast rather than silently degrading).
  - **`codex exec resume` (reusing a server-side thread/session)**:
    measured and **rejected** as an architecture fit — 3 sequential resumed
    turns showed `input_tokens` growing every turn (20,320 → 40,661 →
    61,023, the full conversation re-sent each time) even though wall time
    dropped slightly per turn from caching (8.4s → 7.1s → 5.7s). Over a real
    30-60 minute meeting with dozens of turns this would make **later**
    turns progressively **slower**, the opposite of what a bounded-context
    live path needs (plan §5.6's whole design is a small, bounded prompt per
    turn) — not adopted.
  - **`exec-server`/`app-server` (persistent local process/daemon modes)**:
    `codex --help` confirms both exist (`[EXPERIMENTAL] Run the standalone
    exec-server service`, `[experimental] Run the app server or related
    tooling`), but both use undocumented-beyond-`--help` wire protocols
    (only `app-server generate-json-schema`/`generate-ts` hint at a schema,
    with no example messages) that would need non-trivial reverse
    engineering to integrate safely. Since (a) any local persistent-process
    approach can only remove the *local* portion of the fixed overhead
    (process start + config parse — measured above at ~1.5-2s), never the
    *remote* portion (session creation + generation on OpenAI's backend,
    which dominates: ~4-7s of the ~9s total), and (b) the one persistence
    mechanism that *was* safe to test end-to-end (`resume`) turned out to be
    architecturally wrong for this bounded-context design — **a persistent
    Codex daemon/session was not implemented.** Recommendation if revisited:
    prototype against `codex app-server` specifically (it, not
    `exec-server`, is the one with schema-generation tooling built in,
    suggesting a more stable/intended-for-integration protocol), behind the
    existing `CopilotLLM` protocol as an alternate `CodexCLICopilotLLM`
    backend with automatic fallback to the per-call `codex exec` path on any
    error — and budget real time to reverse-engineer/validate its JSON-RPC
    framing and turn-completion signaling before trusting it in the live
    path, since a wedged persistent process is a worse failure mode than a
    slow one-shot process (the existing timeout/kill supervision only
    covers one already-spawned `Process` per call today).
  - **Applied fix** (`Sources/MeetGistKit/LiveCopilot/CopilotLLMAdapters.swift`,
    `CodexCLIGeneralProcessGenerator`, Live Copilot's generator only —
    `CodexCLINotes.swift`'s own process generator is untouched, per
    instructions): best-effort read `~/.codex/config.toml` (or
    `$CODEX_HOME/config.toml`) for its top-level `model = "…"` line
    (`codexUserConfiguredModel()`, pure string parsing, no TOML dependency).
    When found, the **fast path** adds `--ignore-user-config -m <that
    model>` to the existing arguments; when not found, arguments are
    byte-for-byte the original ones (zero behavior change). If the fast path
    fails for **any** reason, it automatically retries **once** with the
    original (always-safe, unmodified) arguments using whatever timeout
    budget remains — so a config shape this heuristic doesn't handle, or an
    account whose fallback model differs from this one, degrades to
    exactly today's behavior rather than a new failure mode. Verified with
    22 real Codex calls in this pass (12 in the semantic-only benchmark, 10
    in the end-to-end benchmark) — **22/22 succeeded on the fast path, zero
    fallbacks triggered** — and cut measured p50 latency from the
    pre-fix-equivalent raw-CLI number (§13's original P4 entry: p50 ≈ 8.98s)
    to **p50 ≈ 7.11s / p90 ≈ 8.49s** through the real `CodexCLICopilotLLM` →
    `CodexCLIGeneralProcessGenerator` path (~21-22% faster). Tests added
    (`tests/MeetGistKitTests/CopilotLLMAdapterTests.swift`,
    `CodexUserConfiguredModelTests`, 5 tests): quoted/single-quoted model
    line, `model_reasoning_effort` line correctly ignored (must not be
    mistaken for `model`), trailing-comment stripping, missing config file →
    nil, empty value → nil — all via a scratch `$CODEX_HOME` so nothing
    touches the real `~/.codex`.

  See the updated measurement table and Codex latency section at the end of
  §13 for the full real numbers from this pass (ASR/Codex/end-to-end
  p50/p90, all directly measured, none estimated).

- 2026-09-27 — **P4b added mic-track echo preprocessing**, separate from
  Live Copilot. Removed on 2026-10-03 at the user's request because it did
  not work satisfactorily. Cloud/offline transcription now reads canonical
  audio directly and no longer applies transcript echo deduplication.
  Live Copilot's existing live turn filter is unchanged.

- 2026-09-28 — **P5/P6 landed** (V2 "Live Assistant": Suggest Answer, Ask
  Meet Gist, manual project context, plus validation + real measurements).
  Full detail — architecture, prompt contracts, all files changed across
  every phase, every measured number, UX examples, known limitations, V3/V4
  extension points — is in the **§13 FINAL REPORT** section at the end of
  this document; this entry is the dated summary.

  **§7.1 Suggested Answer**: `LiveCopilotEngine.suggestAnswer(questionID:contextProvider:)`
  — one `CopilotLLM` request (the active question + ≤8 bounded recent turns
  + compact state + optional context), on its own scheduling slot separate
  from V1's semantic scheduler (own in-flight task/seq/generation guard —
  reuses the engine's shared `generation` so `stop()`/`setLLM()` still
  invalidate it). `questionID` must match the *current* question or the call
  is a silent no-op (stale-press protection). New V2 request (either kind)
  always cancels whichever V2 request was in flight.

  **§7.2 Ask Meet Gist**: `LiveCopilotEngine.ask(_:contextProvider:)` — free
  text, context = a time-bounded turn window (default last 10 minutes, ≤8k
  chars; the engine keeps a separate, larger, time-filtered turn history
  — `askTurnHistory`, capped at 200 turns — since `LiveMeetingState.recentTurns`
  is capped at 8 for the V1 prompt and isn't enough for a 10-minute Ask
  window) + compact state + optional context. Same output shape as Suggest
  Answer. Last 5 Ask Q&A kept in `LiveAssistSnapshot.v2AskHistory`;
  everything persists to `live/assist.jsonl` (question, answer, provider,
  latency, confidence, context **file name only**).

  **§7.3 Manual project context**: `ManualFileContextProvider` (new file,
  `Sources/MeetGistKit/LiveCopilot/ManualFileContextProvider.swift`)
  implements the `LiveContextProvider` seam reserved in P1/P2 — one
  `.md`/`.txt` file picked via `NSOpenPanel` (`AppState.pickLiveContextFile()`),
  read once, capped at 24k chars (`truncated` flag), in memory only, cleared
  when a new recording starts. Sent only with Suggest/Ask, never with the
  per-turn semantic call. No embeddings/indexing/vector DB — exactly the
  plan's V3 seam, still unimplemented.

  **Output contract**: `{answer, known_from_meeting, from_context,
  assumptions, confidence}`, parsed tolerantly by `LiveAssistAnswerParser`
  (new file, `LiveAssistAnswer.swift`) the same way `SemanticResultParser`
  parses V1's schema. Post-check (`LiveAssistAnswerPostCheck`): a
  `known_from_meeting` claim with **zero token overlap** against the
  turns/state pool it was given is moved to `assumptions` before the answer
  is ever published — deterministic, independent of the LLM, same spirit as
  `LiveMeetingState`'s evidence guards. Both new JSON schemas
  (`answerJSONSchema` alongside the existing `semanticJSONSchema`) satisfy
  OpenAI's strict-mode rules (`additionalProperties: false`, every property
  in `required`) — a new generic recursive validator
  (`LiveCopilotSchemaStrictModeTests`) checks *every* schema this codebase
  ships against those rules, not just the new one, so a future schema change
  can't silently reintroduce P4's HTTP 400.

  **Scheduling deviation from a literal reading of §5.5's Codex timeout
  table**: this phase's coordinator instruction said explicitly to keep
  Codex reasoning effort **"none"** for V2 too (not the provider's
  configured notes effort) "unless measurements show 'low' is needed for
  acceptable answers — measure before changing." P6's real measurements
  (10 Suggest Answer + 10 Ask Meet Gist real Codex CLI calls, §13) found
  "none" answers already short, sayable aloud, and correctly hedged/flagged
  as assumptions when the meeting didn't actually say something — so `"low"`
  was **not** adopted; `CodexCLICopilotLLM` forces `"none"` for all three
  `CopilotPurpose` cases (`.semantic`, `.suggestAnswer`, `.ask`) via one
  `reasoningEffort(for:configured:)` helper, documented as the place to
  revisit this per-purpose if a later measurement disagrees.

  **`liveAutoSuggest`** (default **off**, plan §7.1): `AppState` presses
  "Suggest Answer" automatically the moment a genuinely new question is
  detected (tracked by question id, fires at most once per question) — a
  thin convenience wrapper around the same manual call, added in
  `AppState+LiveAssist.swift` (`maybeAutoSuggest`), not in the Kit engine
  (the engine has no notion of "auto"; it only ever does what it's told).

  **UI** (`app/Sources/LiveAssist/LiveAssistPanel.swift`): a "Suggest Answer"
  button appears only while a question is active, shows a spinner + "Đang
  tạo câu trả lời…"/"Generating answer…" while in flight (user priority:
  never leave the panel looking stuck given Codex's ~6-8s p50), then the
  answer with "Dựa trên"/"Based on" (known), "Từ tài liệu tham khảo"/"From
  your context file", and "Suy luận — cần xác nhận"/"Inferred — please
  confirm" (assumptions) lines. An "Ask Meet Gist" text field + submit
  button, and a context row ("Context: none" / the picked file's name +
  a truncation warning icon + "Choose file…"/"Clear"). New content-language
  strings added to `LiveAssistLabels.swift` (Vietnamese/English, following
  `notesLanguage` like every other V1 label); new app-chrome strings
  (auto-suggest Settings toggle, context picker button labels) added to
  `L10n.swift` (English/Chinese, like every other app-chrome string).

  **Tests**: `make test` **281 Swift Testing tests (49 suites)** + **42
  Python unittest tests** (1 pre-existing, unrelated skip — `numpy` not on
  this Python), all green. Before this phase: 240 Swift tests (44 suites).
  **40 new always-run Swift tests, 5 new suites** (zero pre-existing tests
  changed or broken), plus **1 new env-gated benchmark test**
  (`suggestAnswerAndAskMeetGistBenchmark`, `MEETGIST_LIVE_BENCH=1`, excluded
  from `make test`/the 281 count's "always green" claim the same way the
  other 3 benchmark tests already were). New suites: `LiveCopilotV2PromptTests`,
  `LiveAssistAnswerParserTests`, `LiveAssistAnswerPostCheckTests`,
  `ManualFileContextProviderTests`, `LiveCopilotSchemaStrictModeTests` (all
  in the new `tests/MeetGistKitTests/LiveCopilotV2Tests.swift`). New tests
  added to existing suites: 11 in `LiveCopilotEngineTests` (manual Suggest
  Answer, stale questionID no-op, Ask with/without context, unsupported
  known-claim → assumptions, supported claim stays known, new-request-cancels-old,
  stale-answer-ignored, V2-in-flight-doesn't-delay-V1, stop cancels V2,
  assist.jsonl line shape), 1 in `CopilotLLMAdapterTests` (V2 purposes also
  force effort "none"), 6 in `AppStateLiveAssistTests` (auto-suggest default
  off, suggest/ask no-ops with no session, auto-suggest fires/doesn't fire,
  context forwarded to Ask, context cleared on a new recording — the last
  three drive a *real* fake-audio → endpointer → ASR → engine pipeline, not
  just engine-level fakes). `swift build` and `swift build --target
  MeetGistApp` both green, no new warnings.

  **Measurements** (this machine, same as P4/P4-fix): 10/10 Suggest Answer
  and 10/10 Ask Meet Gist real Codex CLI requests succeeded (100% each).
  Suggest Answer p50/p90 **6.01s / 8.68s**; Ask Meet Gist p50/p90 **6.37s /
  19.17s** (two of ten Ask calls ran 15-19s under real system load — the
  same kind of tail P4-fix already observed for the semantic path; median
  stayed in the same ~6s band as Suggest Answer). Full per-call numbers,
  quality spot-check, and 15 real (not invented) synthetic UX examples are
  in §13.

  **Known gaps**: no Gemini/OpenAI V2 measurements (no Keychain key on this
  machine, same policy as V1); no real end-to-end manual-panel verification
  (this environment can't run a GUI `MeetGistApp`/grant OS permissions,
  same §11 blocker as every prior phase) — the auto-suggest/context-forwarding
  tests instead drive the real Kit pipeline (fake audio → real endpointer →
  fake ASR → real engine → real Codex-shaped fakes) as far as a headless
  test can.

---

## 1. Goal

MeetGist today: `recording → transcript → post-meeting notes`.
Target: add, **in parallel and fully isolated**, a live path that helps the
user understand a meeting while it happens:

- *Họ đang nói gì?* — what the other person actually means (not a literal
  translation).
- *Họ đang hỏi gì?* — whether a real question is waiting for the user, and what
  it is.
- *Live Notes* — key points, decisions, action items, open questions.
- V2: *Suggested Answer* (on demand) and *Ask Meet Gist* (free-form question
  about the meeting so far, optionally with a manually selected context file).

Semantic output language = the existing **Notes language** setting
(`AppState.notesLanguage`, default `Vietnamese`). Technical terms, names,
identifiers, product names and code stay in their original form.

## 2. Facts found while inspecting the repo (2026-09-27)

These drove the deviations in §3. Re-check them if the code has moved on.

1. **There is no Claude/Anthropic provider** in MeetGist. Cloud notes styles
   are `NotesStyle.gemini`, `.chat` (OpenAI-compatible: OpenAI, Groq,
   DeepSeek, Moonshot, xAI, custom base URL) and `.codexCLI` (user's own
   `codex` CLI, ChatGPT login). On-device styles: `.apple`, `.qwenMLX`.
   (`Sources/MeetGistKit/Provider.swift`, `Pipeline.swift`.)
2. Provider selection = `AppState.notesProviderID` + per-provider model
   override keys `model.<providerID>.<slot>` (`ProviderModelSlot`), keys in
   Keychain via `AppState.key(for:)`. `AppState.effective(_:)` applies
   overrides.
3. **Microphone is recorded with `AVAudioRecorder`** (`Recorder.swift`,
   `MicRecorder`) — no PCM access at all. System audio comes from
   ScreenCaptureKit (`SystemAudioRecorder`) as Float32 48 kHz stereo
   `CMSampleBuffer`s on `audioQueue`, which is also the writer queue.
4. Qwen3-ASR already runs through `mlx-audio 0.5.6`
   (`offline_worker_qwen.py`, `mlx_audio.stt.utils.load_model`,
   `model.generate(audio, language=, hotwords=)`), with an app-managed runtime
   built by `ManagedOfflineRuntime` + `OfflineRuntimeConfig`
   (`OfflineRuntimeManager.swift`). The installed offline model is
   `Qwen3-ASR-1.7B-4bit`. The worker is one-shot per job (loads the model per
   job) — unsuitable for per-turn realtime use as is.
5. HF has `mlx-community/Qwen3-ASR-0.6B-4bit` (rev
   `313d850181767edf09f00a9c289becca70e58cd0`, 712,781,279 bytes) and
   `mlx-community/Qwen3-ASR-0.6B-8bit` (rev
   `89e96d92ba34aca20b3e29fb10cc284097d1219f`, 1,010,773,761 bytes).
   Verify revisions/sizes again with the HF API before pinning.
6. `codex exec` (0.157.1 on the dev machine) supports `--output-schema <FILE>`,
   `--ephemeral`, `--sandbox read-only`, `-o/--output-last-message`, `-m`.
   `CodexCLIProcessGenerator` (private in `CodexCLINotes.swift`) hardcodes a
   120 s timeout and does not set the working directory.
7. `OpenAIHTTP.chat` and `GeminiHTTP.generate` return plain text, no usage,
   no JSON mode, and retry via `HTTPRetry` policy `.modelCall`.
8. `ChildProcess.run` is run-to-completion only (no streaming stdin/stdout for
   a long-lived worker).
9. UI localization is `LStr(en:zh:)` only (no Vietnamese UI strings).
10. Dev machine: Apple M1 Pro, 16 GB. `codex` installed at
    `~/.local/bin/codex`.

## 3. Decisions and deviations from the original brief

| Brief said | Decision | Why |
| --- | --- | --- |
| Use "existing Claude API + Codex CLI" providers | **Reuse the existing cloud notes providers: Gemini, OpenAI-compatible chat, Codex CLI.** No new Anthropic client. | No Claude provider exists and the user confirmed it is not needed. Claude can still be used later without code via a custom OpenAI-compatible provider if Anthropic's compatibility endpoint is acceptable — not part of this work. |
| `CopilotLLM ├ Claude └ Codex` | `CopilotLLM` protocol with adapters for `.gemini`, `.chat`, `.codexCLI`. `.apple` / `.qwenMLX` are rejected with a clear message ("Live Assist needs a cloud provider"). | Brief forbids a local LLM for live work. |
| Provider config | New setting `liveAssistProviderID` (empty = "same as Notes provider when that is a cloud provider"). Model override uses the existing per-provider override mechanism with a new slot `ProviderModelSlot.live` (key `model.<id>.live`). Keys come from the existing Keychain path. | Reuse, no duplicate AI config system. |
| Output language fixed Vietnamese | Use `notesLanguage` (default Vietnamese). JSON keys are language-neutral (`meaning`, `question`). | Same knob the app already has. |
| Mic PCM | Add a **separate, optional** `LiveMicTap` (`AVAudioEngine` input tap) started only when Live Assist is on, *after* recording has started. `MicRecorder` is not changed. | Recording must not depend on Live Assist. Coexistence of AVAudioEngine + AVAudioRecorder must be verified manually (§11 risk R1). |
| System PCM | Add an optional, non-blocking PCM sink hook to `SystemAudioRecorder` (copy samples, hand off to another queue). | Smallest change to capture code. |
| Realtime ASR | New **persistent** per-recording worker `live_asr_worker.py` (loads Qwen3-ASR 0.6B once, JSON-lines over stdin/stdout). Runtime = a new `OfflineRuntimeConfig` (`MeetGist/LiveASR/Qwen3-ASR-0.6B/v1`) reusing the Qwen lockfile and `ManagedOfflineRuntime` installer. | The one-shot offline worker reloads the model per job. The worker lives only while recording with Live Assist on — it is a child process, not a daemon. |
| Semantic analysis of all speech | Default: analyze **system-track ("Speaker") turns**; mic ("Me") turns are transcribed and kept as context only. Setting `liveAnalyzeMic` (default off) for in-person meetings. | The questions/meaning are about *other* people; halves API calls. |
| Cancel stale requests | At most **one in-flight** semantic request; newer turns **coalesce** into one pending batch (bounded). Late/stale responses are discarded by sequence number. | Bounded cost, no backlog, no lost notes. |

## 4. Architecture

```text
                      ┌───────────────────────────────────────────┐
SCStream (system) ────┤ existing: system.m4a writer               │
AVAudioRecorder (mic) ┤ existing: mic.m4a → transcript → notes    │  (unchanged)
                      └───────────────────────────────────────────┘
        │ optional PCM sink (copy, non-blocking)
        ▼
 LiveAudioFeed (per track: resample → 16 kHz mono Float32)
        │  LiveMicTap (AVAudioEngine) feeds the mic track
        ▼
 SpeechEndpointer (energy VAD + hangover + soft/hard max) ── per track
        │  finalized utterance audio + absolute meeting timestamps
        ▼
 RealtimeTranscriber (protocol)  ← QwenLiveTranscriber (live_asr_worker.py, persistent)
        │  LiveTranscriptTurn {id, track, startedAt, endedAt, text, timings}
        ▼
 LiveTurnFilter (empty / noise / filler / duplicate / mic-echo)
        ▼
 LiveCopilotEngine (actor)
   ├─ scheduler: 1 in-flight, coalesced pending batch, timeout, seq/stale guard,
   │             circuit breaker
   ├─ SemanticAnalyzer → CopilotLLM (Gemini | OpenAI-compatible | Codex CLI)
   │             ← only: current turn(s) + 2–5 recent turns + compact state
   ├─ LiveMeetingState (incremental, dedup, evidence guards)
   └─ LiveMetrics (per-turn timings, usage)
        ▼
 AppState+LiveAssist (@MainActor, @Published LiveAssistSnapshot)
        ▼
 LiveAssistPanel (floating NSPanel) — V1 sections + V2 Suggest Answer / Ask
```

V2:

```text
question (detected, or typed by the user)
  → recent turns (bounded) + LiveMeetingState (compact)
  → optional manually selected project context (bounded, user-chosen file)
  → CopilotLLM (same provider selection)
  → Suggested Answer / Ask Meet Gist answer (with known-vs-inferred marking)
```

Isolation rule: everything below `LiveAudioFeed` runs off the capture queues,
owns its own tasks, and can crash, stall or be disabled without affecting
`SessionRecorder`, the `.m4a` files, `capture_timing.json`, the offline/cloud
transcription or the notes stage.

## 5. Components (new unless marked "changed")

All Kit types live in `Sources/MeetGistKit/LiveCopilot/` (SPM picks up
subfolders). App code in `app/Sources/LiveAssist/` and
`app/Sources/AppState/AppState+LiveAssist.swift`.

### 5.1 `LiveAudioFeed` + `SpeechEndpointer`
- `LiveAudioFeed`: accepts `(samples: [Float], sampleRate, channels, hostTimeNs)`
  from a tap, downmixes to mono, resamples to 16 kHz (`AVAudioConverter`),
  forwards 30 ms frames to the endpointer on its own serial queue. Never called
  on / never blocks `audioQueue` beyond a copy.
- `SpeechEndpointer` (pure, synchronous, fully unit-testable). Start values
  (make them a `LiveEndpointerConfig` struct):
  - frame 30 ms; RMS in dBFS; adaptive noise floor (slow EMA of quiet frames).
  - speech frame: `rms > max(floor + 10 dB, -50 dBFS)`.
  - start: ≥ 150 ms speech within 300 ms; keep 300 ms pre-roll.
  - end: ≥ 600 ms continuous silence (hangover), trailing silence trimmed.
  - soft max 15 s: after that, end at the first ≥ 250 ms pause.
  - hard max 30 s: force-cut (never cut a speaker merely to hit ~20 s).
  - discard turns with < 500 ms voiced audio.
  - outputs `SpeechSegment {track, startedAt, endedAt, samples16k}` with
    **absolute meeting time** = seconds since the recording anchor
    (`SessionRecorder` start host time), derived from buffer host time.
  - **Superseded 2026-09-27 (latency-first decision, coordinator-directed):**
    hangover/soft-max/hard-max are shorter than originally specified (was
    800 ms / 25 s+300 ms / 45 s) — shorter live turns reach the semantic LLM
    sooner, at the cost of occasionally splitting a long utterance into two
    turns. `LiveEndpointerConfig`'s stored defaults are the numbers above;
    every other rule (150 ms/300 ms start, 500 ms min voiced, adaptive
    dBFS floor) is unchanged from the original plan.
- Pause: while recording is paused, feeds drop audio and the endpointer
  finalizes any open segment.

### 5.2 `LiveTranscriptTurn` and `RealtimeTranscriber`
```swift
public enum LiveTrack: String, Codable, Sendable { case speaker, me }   // system, mic
public struct LiveTranscriptTurn: Codable, Sendable, Identifiable, Equatable {
    public let id: Int            // monotonic per meeting
    public let track: LiveTrack
    public let startedAt: Double  // seconds since recording start
    public let endedAt: Double
    public let text: String
    public var timings: LiveTurnTimings   // speechEnd, asrStart, asrEnd (host ns)
}
public protocol RealtimeTranscriber: Sendable {
    var label: String { get }
    func prepare() async throws                       // load model once
    func transcribe(_ segment: SpeechSegment) async throws -> String
    func shutdown() async
}
```
Nothing outside `QwenLiveTranscriber` may know about Qwen.

### 5.3 `live_asr_worker.py` (new resource) + `QwenLiveTranscriber`
- Persistent process: `python live_asr_worker.py --model-dir <dir> [--language X] [--hotwords-file f]`.
- Protocol, one JSON object per line:
  - worker → `{"type":"ready","load_ms":…,"peak_memory_mb":…}` after load.
  - app → `{"type":"transcribe","id":N,"pcm_path":"…/N.f32","sample_rate":16000}`
    (raw little-endian Float32 mono file in a private temp dir; the app deletes
    it after the reply).
  - worker → `{"type":"result","id":N,"text":"…","asr_ms":…,"audio_seconds":…,"peak_memory_mb":…}`
    or `{"type":"error","id":N,"message":"…"}`.
  - app → `{"type":"shutdown"}`; SIGTERM also exits cleanly.
- Reuse `offline_worker_qwen.py`'s transcriber approach (`load_model`,
  `generate(language=, hotwords=)`). Language/hotwords come from the existing
  `offlineLanguage` / `offlineVocabulary` settings.
- Swift side (`QwenLiveTranscriber`, actor): owns the `Process`, reads stdout
  lines, matches replies by id, per-request timeout (10 s), terminate-then-kill
  on shutdown using the same policy as `ChildProcess` (SIGTERM to the process
  group, SIGKILL after 2 s). Drain stderr into a capped ring buffer; write it to
  `<session>/live/asr-worker.log` on exit.
- Bounded ASR queue: max 4 pending segments; on overflow drop the **oldest
  mic** segment first, else the oldest segment, and count it in metrics.
- Worker crash → transcriber state `failed`; engine reports
  "Live transcription unavailable"; at most 1 automatic restart per recording.
- Python unit tests for the protocol with a fake transcriber (pattern:
  `tests/test_offline_worker.py`).

### 5.4 Live ASR runtime
- `LiveASRRuntimeManager: ManagedOfflineRuntime` with config
  `rootPath "MeetGist/LiveASR/Qwen3-ASR-0.6B/v1"`, `lockResource
  "offline-requirements-qwen"` (same pinned mlx-audio stack), model
  `mlx-community/Qwen3-ASR-0.6B-{4bit|8bit}` at an exact revision.
- **Superseded 2026-09-27 (latency-first decision, coordinator-directed):**
  the original plan said prefer 8bit unless measurement showed otherwise.
  Instead, **4bit is now the pinned default** (`LiveASRRuntimeManager
  .qwen0_6BConfig`) — the post-meeting offline/cloud pipeline is already the
  accuracy backstop for the canonical transcript, so Live Assist optimizes for
  latency/memory instead. The 8bit config (`qwen0_6B8BitConfig`) stays fully
  pinned/documented as a one-line alternative; P4 still measures both and may
  record a different final recommendation in §13.
- Settings shows install/remove like the other local engines. Live Assist with
  the runtime missing → status "Install Live ASR in Settings"; recording
  unaffected.

### 5.5 `CopilotLLM` (provider adapter)
```swift
public struct CopilotLLMRequest: Sendable {
    public var system: String
    public var user: String
    public var jsonSchema: String?        // JSON Schema text; nil = free text
    public var maxOutputTokens: Int
    public var timeout: TimeInterval
    public var purpose: CopilotPurpose    // .semantic, .suggestAnswer, .ask
}
public struct CopilotLLMResponse: Sendable {
    public let text: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latency: TimeInterval
    public let providerLabel: String       // e.g. "Gemini · gemini-flash-latest", "Codex CLI"
}
public protocol CopilotLLM: Sendable {
    var label: String { get }
    var providerKind: String { get }       // "gemini" | "chat" | "codex-cli"
    func complete(_ request: CopilotLLMRequest) async throws -> CopilotLLMResponse
}
public enum CopilotLLMs {
    public static func make(provider: Provider, key: String?) throws -> any CopilotLLM
}
```
- `.gemini`: new `GeminiHTTP.generateJSON` (or an options parameter) using
  `generationConfig.responseMimeType = "application/json"`, low temperature,
  `maxOutputTokens`, reading `usageMetadata.promptTokenCount/candidatesTokenCount`.
- `.chat`: new `OpenAIHTTP` call returning text + `usage.prompt_tokens/completion_tokens`,
  `response_format: {"type":"json_object"}` when a schema is given (fall back
  to no `response_format` if the provider returns 400 for it, once per
  session), `max_tokens`.
- `.codexCLI`: generalize the private process generator to accept `timeout`,
  optional `--output-schema` file, `-c model_reasoning_effort=none`, and set
  `currentDirectoryURL` to the empty private temp dir (Codex must not see the
  user's project files). **The notes path keeps its exact current arguments
  and 120 s timeout.** Codex exposes no token usage → `nil`.
- No `HTTPRetry` retries for `.semantic` (latency > completeness; the next
  turn will carry the context). V2 requests may use a single retry on 429/5xx.
- Timeouts (start values, tune from measurements): HTTP semantic **8 s**
  (superseded 2026-09-27, latency-first decision — was 12 s), HTTP answer/ask
  20 s (unimplemented until P5, value unchanged); Codex semantic 45 s, Codex
  answer/ask 60 s. Codex semantic calls always run at
  `model_reasoning_effort=none` regardless of the provider's configured notes
  effort (same 2026-09-27 decision).
- Never log prompts, keys or responses outside the meeting's own `live/`
  folder. Metrics record provider, sizes, token counts and timings only.

### 5.6 Semantic contract (`LiveCopilotPrompts`)
System prompt (keep it short, in English, output in LANGUAGE):
- You help the user follow a live meeting. Explain what the latest speaker
  **means** (intent, not a literal translation), in LANGUAGE, 1–2 short
  sentences. Keep technical terms, names, identifiers, product names and code
  verbatim.
- Classify `speech_act`: `question` (a real question expecting an answer from
  the listeners), `request`, `rhetorical_question`, `self_answered_question`,
  `statement`, `filler`. `is_question` is true only for `question` / `request`
  that still needs an answer.
- Return only **new** facts not already in STATE. Decisions only when
  explicitly made/confirmed. Action items only when explicitly agreed or
  clearly assigned. **Never invent owners, deadlines, commitments or
  decisions** — use null when not stated. Each decision/action item must carry a
  short verbatim `evidence` quote from the TURNS.
- Output JSON only, matching the schema.

User content (bounded; target < 2,500 tokens):
```
LANGUAGE: <notesLanguage>
STATE: {topic, key_points[id,text] (last 12), open_questions[id,text], decisions[text], action_items[text,owner,deadline]}
RECENT TURNS (context, do not re-analyze): [mm:ss] Speaker|Me: text   (previous 2–5 turns, ≤ 1,500 chars)
CURRENT TURNS (analyze these): [mm:ss] Speaker: text   (1–3 coalesced turns)
```
**Superseded 2026-09-27 (latency-first decision, coordinator-directed):**
shipped defaults are tighter than the numbers above — `compactView`'s
key-points window is **last 6**, not last 12 (callers may still pass
`maxKeyPoints:` explicitly for the original 12); `RECENT TURNS` is
**2–3 turns, ≤ 900 chars**, not 2–5/1,500; the semantic call's
`maxOutputTokens` is **350**, not implied-uncapped. `CURRENT TURNS` (1–3
coalesced turns) is unchanged.
Response schema:
```json
{
  "meaning": "string",
  "speech_act": "question|request|rhetorical_question|self_answered_question|statement|filler",
  "is_question": true,
  "question": "string or empty",
  "topic": "string or empty",
  "key_points": ["string"],
  "decisions": [{"text": "string", "evidence": "string"}],
  "action_items": [{"text": "string", "owner": "string|null", "deadline": "string|null", "evidence": "string"}],
  "open_questions": ["string"],
  "resolved_open_question_ids": ["string"]
}
```
Parsing: strip code fences, take the outermost `{…}`, decode tolerantly
(missing arrays = empty, unknown `speech_act` = `statement`). A decode failure
is a `malformed` error: counted, surfaced as a subtle status, **no state
change**.

### 5.7 `LiveMeetingState`
```text
topic, keyPoints[LiveItem], questions[LiveQuestion (open/answered, turnID)],
decisions[LiveItem], actionItems[LiveActionItem(owner?, deadline?)],
openQuestions[LiveItem], recentTurns (ring buffer, 8), lastMeaning, lastQuestion,
version (monotonic)
```
- Incremental `apply(result, forTurns:)`; pure value type → unit-testable.
- Dedup (deliberately simple): normalize (lowercase, strip Vietnamese
  diacritics via `folding(options: [.diacriticInsensitive, .caseInsensitive])`,
  punctuation, stop-words), then treat as duplicate if token-set Jaccard ≥ 0.6
  or one normalized string contains the other. Merge keeps the earlier item.
- Evidence guards (deterministic, independent of the LLM):
  - decision/action item dropped when its `evidence` is not found (normalized,
    ≥ 70 % of evidence tokens) in the current + recent turn text;
  - `owner` / `deadline` set to nil unless the value (normalized) appears in
    those turns.
- `resolved_open_question_ids` marks open questions answered.
- Caps: key points 40, decisions 20, action items 30, open questions 15
  (oldest trimmed from the compact prompt view first, never from disk).
- It is **not** the transcript and never feeds the notes stage.

### 5.8 `LiveCopilotEngine` (actor) — scheduling, cancellation, stale guard
- `ingest(turn)` → filter → append to `recentTurns` → if analyzable, add to the
  pending batch.
- Filter (`LiveTurnFilter`): skip empty/whitespace; < 2 words and < 0.8 s;
  filler set (vi/en: "ừ", "ừm", "vâng", "dạ", "ok", "okay", "yeah", "uh huh",
  "mm", "right", "yes"…); duplicate of one of the last 3 turns on the same
  track (normalized equal or Jaccard ≥ 0.9); mic turn that duplicates a
  system turn overlapping within ±3 s (speaker echo into the mic).
- Scheduler: at most **one** in-flight semantic request. Turns arriving while
  one is in flight coalesce into the pending batch (max 3 turns; older ones
  stay in RECENT TURNS as context). When the in-flight request finishes,
  the pending batch starts immediately.
- Every request gets `seq`; a response is applied only if `seq >` last applied
  seq and the engine generation (bumped on stop / disable / provider change)
  matches. Cancelled tasks never publish.
- Timeout → cancel request task (Codex: kill the process via `ChildProcess`).
- Circuit breaker: 3 consecutive failures → pause semantic calls for 30 s,
  status "Provider unavailable — retrying…", then try again with the next turn.
- Engine publishes immutable `LiveAssistSnapshot` values via an
  `AsyncStream`/callback; the app hops to the main actor.

### 5.9 `LiveMetrics`
Per turn: `speech_end`, `asr_start`, `asr_end`, `llm_start`, `llm_end`,
`ui_update` (host ns → ms), provider label, input/output tokens, skipped
reason. Derived: ASR latency, LLM latency, speech-end → UI latency. V2:
`suggest_pressed → answer_visible`, `ask_submitted → answer_visible`.
Session summary: request count per provider, token totals, p50/p90 latencies,
worker load ms, peak worker memory. Written to `<session>/live/metrics.jsonl`
+ `live/metrics-summary.json` at stop. `ui_update` is stamped by the app when
the snapshot is rendered (callback from the app side).

### 5.10 Audio taps (changed capture code — keep minimal)
- `SystemAudioRecorder` (changed): `public func setLivePCMSink(_ sink: (@Sendable (LivePCMChunk) -> Void)?)`
  stored on `audioQueue`; in the sample handler, after the existing append
  logic and only if a sink is set and not paused, copy Float32 samples into a
  `LivePCMChunk` and call the sink (the sink immediately dispatches to the
  feed's queue). No throwing, no allocation-heavy work, no locks shared with
  the writer.
- `LiveMicTap` (new): `AVAudioEngine` input-node tap (bufferSize ~4096, input
  format), started after `SessionRecorder.start()` succeeded, stopped before
  `SessionRecorder.stop()`. No voice processing. Any failure → mic live track
  unavailable, logged once, recording untouched.
- `SessionRecorder` (changed): expose `recordingAnchorHostNs` and a
  pass-through `setLiveSystemSink`. Nothing else.

### 5.11 `AppState+LiveAssist` (app)
- Settings (UserDefaults, same pattern as others): `liveAssistEnabled`
  (default **false**), `liveAssistProviderID` (default ""), `liveAnalyzeMic`
  (default false). Model override via `ProviderModelSlot.live`.
- `startLiveAssistIfEnabled(recorder:sessionDir:)` called from
  `startRecording()` **after** `rec.start()` succeeded and state is
  `.recording`, inside its own `Task` — any throw only sets
  `liveAssist.status`. `stopLiveAssist()` called at the very beginning of
  `stopRecording()` with a hard 2 s cap (never delays saving audio), and on
  toggle-off. Pause/resume forwarded.
- Toggle mid-recording starts/stops live assist without touching recording.
- Stop live worker before the offline/cloud processing begins (frees memory
  for Qwen 1.7B / Whisper).
- Test seams (like `pipelineFactory`): `liveTranscriberFactory`,
  `copilotLLMFactory`, `liveAudioSourceFactory` so AppState tests can run
  without audio/Python/network.

### 5.12 UI — `LiveAssistPanel`
- Floating non-activating `NSPanel` (pattern: `MiniController`), ~360 pt wide,
  movable, collapsible, visible only while recording/paused **and** Live
  Assist enabled. Toggle in the menu-bar popover and Settings.
- Sections (Vietnamese labels when the notes language is Vietnamese, else
  English `LStr`; keep a tiny `LiveAssistLabels` table):
  ```
  LIVE ASSIST                       ● Listening | Transcribing… | Analyzing… | Provider unavailable
  Họ đang nói      <meaning of latest analyzed Speaker turn>   · 12:41
  Họ đang hỏi      <question>  |  "Hiện không có câu hỏi nào chờ bạn trả lời."
                   [Gợi ý trả lời]                                        (V2)
  Live Notes       • key points (latest 6) · Decisions · Action items
  Hỏi Meet Gist    [ text field ]  [Context: none ▾]                      (V2)
  ```
- Update only on applied semantic results (never partial words); keep previous
  content until a new useful result arrives; a small muted line may show the
  latest finalized transcript turn. Subtle fade on change, no flashing.
- Privacy note in Settings: "Live Assist sends transcribed text (not audio) of
  recent turns to <provider>."

### 5.13 Persistence (minimal, non-canonical)
`<session>/live/`:
- `turns.jsonl` — finalized live turns (append).
- `state.json` — latest `LiveMeetingState` (atomic write, throttled ≤ 1/2 s).
- `assist.jsonl` — V2 suggested answers / Ask Q&A (question, answer, provider,
  latency; context **file name only**, not its content).
- `metrics.jsonl`, `metrics-summary.json`, `asr-worker.log`.
Nothing reads these for transcription or notes. Regenerate is unaffected.
Check `MeetingStore`/`Exporter`/delete flows still behave with the extra folder.

### 5.14 Failure isolation (mandatory)
| Failure | Behavior |
| --- | --- |
| Live ASR runtime missing / worker crash / timeout | status "Live transcription unavailable"; one restart attempt; recording continues |
| LLM timeout / network / 4xx / 5xx / rate limit | status "Provider unavailable — retrying…"; circuit breaker; recording continues |
| Malformed JSON | ignored result, counter++, no state change |
| Codex CLI missing / not logged in | status "Codex CLI unavailable" |
| Local notes provider selected and no live provider | status "Choose a cloud provider for Live Assist" |
| AVAudioEngine mic tap fails | Speaker track only; status note |
| Anything throws in live code | caught at the `AppState+LiveAssist` boundary; never sets `state = .error`, never touches `recorder`, `processTask`, `processGeneration` |

## 6. Privacy boundary (document in code + ARCHITECTURE.md)
- Audio never leaves the machine for Live Assist: PCM goes only to the local
  worker via a private temp file that is deleted after use.
- Sent to the selected cloud provider: current turn(s), 2–5 recent turns,
  compact state; for V2 additionally the selected context file content
  (bounded, e.g. ≤ 24 k chars, user-chosen, never auto-discovered).
- Never sent: raw audio, whole-meeting history, unrelated files.
- Codex runs with `--sandbox read-only --ephemeral` in an empty temp dir.

## 7. V2 — Live Assistant

**Status: implemented (P5/P6, 2026-09-28).** Every sub-section below is
implemented as designed, with two documented decisions: (1) V2's `askTurnHistory`
is a new, separate, time-bounded turn buffer (not literally
`LiveMeetingState.recentTurns`, which stays capped at 8 for the V1 prompt) —
needed so Ask Meet Gist's "last 10 minutes" window can actually see more than
8 turns; (2) Codex reasoning effort for V2 is **"none"** (same as V1's
semantic calls), per the coordinator's explicit "measure before changing" —
P6's real measurements found "none" answers already acceptable, so this was
not changed to "low". See the dated 2026-09-28 progress entry (§0) and §13's
FINAL REPORT for full detail, measurements, and UX examples.

### 7.1 Suggested Answer (on demand)
- Button appears when `lastQuestion` is active. Press →
  `LiveCopilotEngine.suggestAnswer(questionID)` → one `CopilotLLM` request with
  question + recent turns (≤ 8, bounded) + compact state + optional context.
- Output schema:
  ```json
  {"answer": "1–3 short sentences the user can say aloud, in LANGUAGE",
   "known_from_meeting": ["facts from transcript/state used"],
   "from_context": ["facts from the selected context used"],
   "assumptions": ["anything inferred / unverified"],
   "confidence": "high|medium|low"}
  ```
- UI shows the answer, then small "Dựa trên" (known) / "Suy luận — cần xác
  nhận" (assumptions) lines. Unsupported claims must go to `assumptions`;
  post-check: an item in `known_from_meeting` that has no token overlap with
  turns/state is moved to `assumptions`.
- Optional setting `liveAutoSuggest` (default **off**). Cancel the previous
  suggestion request when a new one is triggered.

### 7.2 Ask Meet Gist
- Text field in the panel; free-form question (e.g. "Ý James vừa nói là gì?",
  "Tóm tắt 5 phút vừa rồi", "Có action item nào giao cho tôi không?").
- Context = turns from the last N minutes (default 10, parse "5 phút" style
  hints only if trivial; otherwise fixed window with a char cap ≈ 8 k) +
  compact state + optional selected context. Same known/inferred output shape
  (`answer`, `known_from_meeting`, `from_context`, `assumptions`).
- Not a chat history system: keep only the last 5 Q&A in memory for the panel;
  persist to `assist.jsonl`.

### 7.3 Manual project context
- "Context" picker: choose one Markdown/text file (`NSOpenPanel`,
  `.md/.txt`), per meeting, remembered only in memory (and its file name in
  `live/assist.jsonl`). Read once, cap size (≈ 24 k chars, warn when cut).
- Sent only with Suggest Answer / Ask requests, never with per-turn semantic
  analysis.
- No embeddings, no indexing, no vector DB.

## 8. Tests (Swift Testing + Python unittest; mock every external call)

Kit (`tests/MeetGistKitTests/LiveCopilot*Tests.swift`):
- Endpointer: finalized turn; multiple fragments with short gaps → one turn;
  silence endpointing; soft/hard max; short noise discarded; pause finalizes.
- Turn filter: duplicate ASR output; empty/noise; filler; mic echo duplicate.
- Prompt builder: bounded context (only 2–5 recent turns, char caps), state
  compaction, language propagation.
- Parser: valid JSON; fenced JSON; malformed → error; unknown speech_act.
- Semantic fixtures via fake LLM returning canned JSON: normal statement,
  direct question, indirect question ("I'm wondering whether…"), rhetorical /
  self-answered, long rambling question, mixed English/Vietnamese, technical
  terminology preserved in output passed through untouched.
- LiveMeetingState: add key point; dedup ("ERP must be checked" / "Need to
  check ERP" / "Verify ERP"); explicit decision kept; decision without evidence
  dropped (no invented decision); action item kept; invented owner removed;
  invented deadline removed; unresolved question stays open; resolved id closes.
- Engine/provider: fake Codex-style and HTTP-style LLM success; timeout;
  malformed output; provider failure → circuit breaker; cancellation (stop
  while in flight → no publish); stale response (seq older) ignored; rapid
  consecutive turns → ≤ 1 in flight, coalesced batch, bounded.
- Adapters: request construction for Gemini JSON mode / OpenAI JSON mode /
  Codex args (`--output-schema`, cwd, effort) using injected transport /
  generator fakes; usage parsing.
- V2: manual Suggest Answer; Ask Meet Gist; with and without context; context
  cap; unsupported "known" claim moved to assumptions; auto-suggest off by
  default.

App (`tests/MeetGistAppTests/AppStateLiveAssistTests.swift`):
- Live Assist disabled → recording path identical (no factories called).
- Live transcriber/LLM factories throw → `state` stays `.recording`, recording
  stop and processing proceed normally (isolation).
- Stop recording while live request in flight → no state mutation afterwards.

Python (`tests/test_live_asr_worker.py`): ready message, transcribe request
with fake model, error reply, shutdown, bad PCM path.

Run `make test` and `swift build`. Never claim a test ran unless it ran.

## 9. Measurement plan (real numbers, not estimates)
- Build a small local benchmark (script under `scripts/` or an env-gated test,
  e.g. `MEETGIST_LIVE_BENCH=1`) — excluded from normal `make test`.
- Audio fixtures: synthesize with macOS `say` (English voices; a Vietnamese
  voice if installed, e.g. `say -v Linh`), mixed EN/VI sentences, 5–20 s.
  Do not commit private meeting audio.
- Measure on this machine (M1 Pro 16 GB):
  - ASR: model load ms, per-turn ASR ms vs audio seconds (RTF), peak memory
    (worker-reported + `ps -o rss`), for 0.6B-4bit and 0.6B-8bit.
  - Semantic LLM latency per provider actually available: Codex CLI (logged in
    on this machine), Gemini/OpenAI only if a key exists in the Keychain — do
    not read or print keys; if unavailable, say "not measured".
  - speech-end → UI latency (engine-level with ASR + LLM, UI stamp from app if
    run manually).
  - Suggested-answer latency per provider.
- Report p50/p90 over ≥ 10 turns where possible. Record in §13.

## 10. Phase acceptance criteria
- P1/P2: Kit compiles; all Kit + Python tests green; no change in existing test
  results; public API documented with short doc comments.
- P3: app compiles (`swift build`); Live Assist off = zero behavior change;
  toggle works mid-recording; isolation tests green; manual checklist written
  in §11 for what cannot be automated (permissions, real audio, AVAudioEngine
  coexistence).
- P4: measurements recorded in §13; ARCHITECTURE.md + AGENTS.md component table
  updated (Live Copilot row, invariant "Live Assist must never affect
  recording/transcription/notes").
- P5/P6: V2 tests green; measurements; final report (§13).

## 11. Risks / manual verification
- R1: `AVAudioEngine` input tap concurrently with `AVAudioRecorder` on the same
  device — verify `mic.m4a` stays intact (length, level) with Live Assist on.
  If it breaks recording, fall back to Speaker-track-only live mode and note it.
- R2: Codex CLI latency (process start + auth) may be several seconds per
  call; measure; if too slow recommend Gemini Flash for Live Assist in UI copy.
- R3: Memory: 0.6B worker (~1 GB) during recording; must be stopped before the
  post-meeting offline Qwen 1.7B/Whisper run.
- R4: Mic picks up speaker audio without headphones → echo turns; mitigated by
  Live Assist's live turn filter, not eliminated. The separate post-meeting
  mic-track echo preprocessing was removed on 2026-10-03.
- R5: Live timestamps are wall-clock offsets from recording start; they can
  drift from final-transcript timestamps (pause handling differs).
- R6: Endpointing is energy-based; noisy rooms may produce long turns. Silero
  VAD (already in mlx-audio) is a possible later upgrade behind the same
  endpointer interface.

Manual checklist (fill in results): record 5 min with Live Assist on/off,
compare `mic.m4a`/`system.m4a` durations and levels; kill the live worker mid
meeting; disconnect network mid meeting; toggle Live Assist during recording;
stop recording while a Codex request runs.

**Results (2026-09-27, P4): every item below is unverified** — this pass
had no way to drive a real Google Meet/Teams call, grant Screen Recording/
Microphone permissions interactively, or run `MeetGistApp` as a GUI app
headlessly. What *was* verified instead, and what's still open:

| Item | Status | Notes |
| --- | --- | --- |
| R1 `AVAudioEngine` (`LiveMicTap`) + `AVAudioRecorder` (`MicRecorder`) coexistence | **unverified** | `LiveMicTap.start()`/`stop()` compile and are exercised with a fake `LiveAudioSource` in `LiveAssistSessionTests`; never run against a real mic in a real recording. Needs a manual 5-minute recording with Live Assist on, comparing `mic.m4a` duration/level to a Live-Assist-off baseline. |
| Record 5 min on/off, compare `mic.m4a`/`system.m4a` | **unverified** | Same blocker — needs the real `MeetGistApp` (Xcode build) and OS permission grants (Microphone, Screen Recording) this environment can't grant interactively. |
| Kill the live worker mid-meeting | **partially verified** | `LiveAssistSessionTests.asrFailureDegradesStatusAndOneRestartIsAttempted` covers the engine/session-level behavior (status degrades, exactly one automatic restart) with a fake transcriber; P4's real benchmark separately confirmed the real worker process starts/stops cleanly (`ChildProcess`-style terminate-then-kill) under `QwenLiveTranscriber.shutdown()`. Not verified: actually `kill -9`-ing the real subprocess mid-recording in the full app. |
| Disconnect network mid-meeting | **unverified** | No network-flakiness harness was built; `LiveCopilotEngineTests`/`CopilotLLMAdapterTests` (P1/P2) cover timeout/failure/circuit-breaker with fakes, which is the mechanism this would exercise, but not with a real dropped connection. |
| Toggle Live Assist during recording | **unverified for real recording**; `AppState.toggleLiveAssist()` itself is exercised only indirectly (no dedicated app test) since it requires a live `recorder`/`SessionRecorder.start()`, which can't run in this environment. |
| Stop recording while a Codex request runs | **verified at the session level** | `LiveAssistSessionTests.stopWhileTranscriptionInFlightNeverPublishes` covers "stop while an in-flight async call is running never publishes" for the ASR call; the same guard (`isRunning` re-checked after every `await`) applies structurally to the semantic path inside `LiveCopilotEngine` (P1/P2's own `stopWhileInFlightNeverPublishes`-equivalent tests, e.g. `cancellationOnStopSuppressesAnyLatePublish` in `LiveCopilotEngineTests`). Not verified: stopping recording while a *real* Codex CLI subprocess is running, in the real app. |
| System-level meter (`SystemAudioRecorder.updateSystemPeak`) with non-interleaved SCStream audio | **unverified, suspected pre-existing bug (P4-fix, F2)** | `updateSystemPeak` uses the exact single-buffer-sized `AudioBufferList` pattern `pcmChunk` had before this pass's fix (see the P4-fix progress entry) — it was deliberately **not** changed (out of this task's scope), but the same reasoning suggests it may silently read the system audio level as digital silence whenever ScreenCaptureKit delivers non-interleaved Float32 audio. Needs a real recording session (Screen Recording permission, which this environment cannot grant) with real system audio playing, comparing the menu-bar/Settings system level meter against actually-audible sound. |

None of the above gaps are new risk introduced by this work beyond what
§11 already flagged before P3/P4 — they're exactly the manual-verification
items the plan always expected to need a real running app + OS permissions
for, which this environment cannot provide.

## 12. Future extension points (do NOT implement now)
- **V3 Meeting Memory / RAG:** add a `LiveContextProvider` protocol whose V2
  implementation is `ManualFileContextProvider`. A V3 `MeetingMemoryProvider`
  could later retrieve evidence from previous `transcript.md`/`summary.md`,
  project docs, decision records, tickets, and return the same
  `[ContextSnippet {source, text}]` into the Suggest/Ask prompt. The answer
  schema already separates `from_context` (evidence) from `assumptions`.
  Persisted `live/state.json` decisions/action items are a natural input for a
  cross-meeting decision log. No vector DB / embeddings / indexing now.
- **V4 Proactive Copilot:** `LiveMeetingState.apply` is the single place new
  items arrive; a future `ProactiveRule` pass (contradiction with a prior
  decision, action item without owner/deadline, unanswered question for N
  minutes) can run after `apply` and emit `LiveAlert`s into the snapshot. Not
  now.

## 13. Results (V1, P4 — measured 2026-09-27 on this machine, Apple M1 Pro 16GB)

### Model / runtime

- Shipped default: `mlx-community/Qwen3-ASR-0.6B-4bit`, revision
  `313d850181767edf09f00a9c289becca70e58cd0`, installed for real via
  `LiveASRRuntimeManager.install()` into
  `~/Library/Application Support/MeetGist/LiveASR/Qwen3-ASR-0.6B/v1`
  (pinned CPython 3.11.16, `mlx-audio` 0.5.6 from the existing
  `offline-requirements-qwen` lockfile — same runtime family as the offline
  Qwen3-ASR engine, separate root).
- Alternative measured, not shipped: `mlx-community/Qwen3-ASR-0.6B-8bit`,
  revision `89e96d92ba34aca20b3e29fb10cc284097d1219f`, downloaded with the
  same runtime's Python (`ManagedPython.downloadModel`, i.e.
  `huggingface_hub.snapshot_download` at the pinned revision — no bypass of
  hash/revision pinning) into a scratch directory under
  `/private/tmp/claude-501/`, deleted after the benchmark run.

### ASR measurements (12 synthesized turns, mixed EN/VI + technical terms,
3.5–14.5s each, via macOS `say` — "Samantha" for English, "Linh" for
Vietnamese; real `live_asr_worker.py` process, direct JSON-lines protocol,
worker-reported numbers cross-checked against `ps -o rss`)

| | 4-bit (shipped) | 8-bit |
| --- | --- | --- |
| Worker load time | 4023.8 ms | 1297.6 ms* |
| ASR latency p50 / p90 | 323.7 ms / 483.6 ms | 350.0 ms / 596.9 ms |
| RTF (ASR ms ÷ audio ms) p50 / p90 | 0.042 / 0.060 | 0.045 / 0.058 |
| Peak memory (worker `peak_memory_mb`) | 735.5 MB | 1132.4 MB |
| Peak memory (`ps -o rss`, sampled per turn) | 138.1 MB | 976.1 MB |

\* The 8-bit load time being *lower* than 4-bit's is very likely a disk/page-
cache warm-start artifact (8-bit ran second, right after the 4-bit weights
had just been read once already) rather than a real property of the model —
not a claim that 8-bit loads faster in general; re-measure cold-cache if this
ever matters. The `peak_memory_mb` (worker-reported, from Python
`resource.getrusage().ru_maxrss`) vs `ps -o rss` gap — especially 4-bit's
138 MB vs 735 MB — is a known limitation of this measurement: `ps` was
sampled once right after each turn's reply, not continuously, and MLX's
unified-memory/Metal allocations aren't fully reflected in a single-sample
`ps` snapshot the way `ru_maxrss` reflects the process's true peak. Treat
`peak_memory_mb` as the more reliable number for both engines.

**Both quantizations garbled the same hardest sentence** (Vietnamese speech
with an embedded English tech phrase — "deploy phiên bản mới của API gateway
lên production") comparably badly; every other turn (plain English, plain
Vietnamese, or lighter code-switching) was transcribed close to verbatim by
both. Given 8-bit is ~1.5–7× the memory for latency that is if anything
slightly *worse* on the p90 tail, and no clear accuracy win on the one turn
where either model actually struggled, this measurement **confirms the
4-bit default** (plan §5.4's latency-first decision) rather than overturning
it.

Model choice/decision: **kept 4-bit** — real numbers support it, no change.

### Bug found and fixed by this measurement pass

Running ≥10 *real* Codex CLI semantic requests (not fakes) immediately
surfaced a genuine defect: **every single one failed** with HTTP 400
`invalid_json_schema` ("'additionalProperties' is required to be supplied
and to be false"). `LiveCopilotPrompts.semanticJSONSchema` was missing
`"additionalProperties": false` on the top-level object and both array-item
object schemas (`decisions`/`action_items`), and `action_items`' optional
`owner`/`deadline` fields weren't listed in `required` (OpenAI's strict
structured-output mode — which Codex CLI's `--output-schema` uses under the
hood — requires both). Fixed in `LiveCopilotPrompts.swift` (see its own
doc comment for the exact diff rationale); Gemini/`.chat` JSON mode were
unaffected either way since neither validates the schema this strictly.
**Without this fix, Live Assist's Codex CLI provider would never have
produced a single successful semantic result in real use** — this is the
single most important thing this measurement pass found, well above the
latency numbers themselves.

### Semantic LLM latency

- **Codex CLI** (`reasoning_effort=none`, real `~/.local/bin/codex`, logged
  in via ChatGPT subscription): before the schema fix, 0/12 real requests
  from the automated benchmark (`LiveCopilotBenchmarkTests`) succeeded (see
  the bug above). After the fix, the automated harness itself twice ran far
  longer than expected under real system load on this machine (once >5 min
  including the ASR benchmark; a second run was killed after 13 minutes
  with no output past the ASR section — see "Known limitations" below) and
  did not finish within a practical time budget for this session, so its
  aggregate wasn't captured. To still get **real** semantic-latency numbers
  rather than none, 10 real `codex exec` calls were run directly with the
  exact same command-line contract `CodexCLIGeneralProcessGenerator` builds
  (`exec --skip-git-repo-check --sandbox read-only --ephemeral -c
  model_reasoning_effort=none --output-schema <the fixed schema>
  --output-last-message <file> -`), using realistic EN/VI meeting-turn
  prompts built the same way `LiveCopilotPrompts.semanticUserContent` does.
  All 10 succeeded and returned valid, schema-conforming JSON:
  **p50 ≈ 8.98s, p90 ≈ 10.91s** (raw seconds, sorted:
  7.27, 7.80, 7.93, 7.94, 7.94, 8.98, 9.07, 9.26, 10.55, 10.91). This
  confirms R2 ("Codex CLI latency may be several seconds per call") is real
  and on the higher end — 9–11 seconds per semantic call is close to the
  45s Codex timeout's ceiling being reasonable, but **far above the ~0.3s
  ASR latency**, meaning Codex CLI is by far the dominant cost in the live
  pipeline's total latency when it's the selected provider. This is measured
  directly (equivalent CLI invocation), not through the Swift
  `CodexCLICopilotLLM` wrapper in this specific run — the wrapper itself is
  unit-tested (`CopilotLLMAdapterTests`) and was exercised successfully
  through the automated harness before it stalled, so the two are expected
  to match; re-running the harness under lighter system load would confirm
  this with the wrapper directly and add the coalesced-batch/circuit-breaker
  behavior the raw CLI calls above don't exercise.
- **Gemini / OpenAI**: not measured — no key for either provider existed in
  this machine's Keychain. Per plan, these were checked only through
  `Keychain.get`/`Provider.keyAccount`, never printed, and no key was
  entered to force a measurement.

### End-to-end (synthetic audio → endpointer → ASR → Codex semantic →
snapshot)

Not captured as a single automated measurement — both automated harness
runs stalled before reaching this section (see "Known limitations"). As an
analytical estimate (not a direct measurement): ASR p50 (≈0.32s, from the
table above) + Codex p50 (≈8.98s, above) ≈ **9.3s** speech-end-to-snapshot
when Codex CLI is the provider, dominated almost entirely by Codex's own
latency. This estimate ignores scheduling/queueing overhead the real
`LiveCopilotEngine`/`LiveAssistSession` add (which should be small — under
a few ms — based on the unit tests' timing assertions), and does not
account for real-time audio delivery pacing; treat it as directional, not
authoritative. A follow-up with a lighter machine load should re-run
`MEETGIST_LIVE_BENCH=1` to get the real, directly-measured number.

### Files changed (P3 + P4)

See the dated 2026-09-27 P3 progress-log entry above for the full list.
Summary: new Kit orchestrator (`LiveAssistSession`, `LiveAudioSources`,
`LivePCMChunk`/`LiveAudioSource` seam), new app integration
(`AppState+LiveAssist.swift`, `LiveAssist/` UI), minimal additive changes to
`Recorder.swift`/`SessionRecorder.swift` (opt-in PCM tap, byte-for-byte
identical when unused) and to four P1/P2 Kit files
(`LiveCopilotEngine`/`LiveMetrics`/`LiveAssistSnapshot` — small additive
public seams; `LiveCopilotPrompts` — the schema bug fix above). New tests:
`LiveAssistSessionTests.swift` (5), `AppStateLiveAssistTests.swift` (5), one
added to `MeetingStoreTests.swift`, plus the env-gated
`LiveCopilotBenchmarkTests.swift` that produced this section's numbers.

### Known limitations

- No real-microphone/real-meeting verification in this pass (§11's manual
  checklist) — this environment cannot grant OS permissions or run the
  packaged `MeetGistApp` interactively.
- `peak_memory_mb` vs `ps -o rss` disagree substantially for 4-bit (see
  above) — worker-reported is the more trustworthy number.
- The end-to-end latency number is an analytical estimate (ASR p50 + Codex
  p50), not a direct measurement — the automated harness never reached that
  section successfully (see below).
- `tests/MeetGistKitTests/LiveCopilotBenchmarkTests.swift`
  (`MEETGIST_LIVE_BENCH=1`) ran successfully through the ASR sections twice
  (both runs' 4-bit/8-bit numbers agree closely — 318–324ms vs 320–350ms
  p50 ASR latency, RTF ~0.04–0.06 both times), confirming that part of the
  harness is reliable. The Codex CLI + end-to-end sections did not finish
  within a practical time budget on this machine on either attempt: the
  first run (pre-schema-fix) took 328s total, mostly spent on 12 real
  Codex calls that each failed fast (~10s) with the 400 error, plus 3×60s
  of e2e timeouts (Codex never producing a usable result to unblock them).
  The second run (post-fix) got through both ASR benchmarks quickly again
  but then produced no further output for 13 minutes before being killed;
  system load at the time was high (Spotlight/`mds`-style indexing was
  independently observed consuming significant CPU during this session, per
  `top`), which is the leading suspect, but this was not root-caused —
  worth a dedicated re-run under a quiet system, or splitting the benchmark
  into separate ASR-only and Codex-only env-gated tests so a slow section
  can't block the other's results.
- Only one machine (M1 Pro, 16 GB) was measured; no Intel Mac or lower-RAM
  Apple Silicon data exists.
- Codex CLI semantic latency (p50 ≈ 9s, p90 ≈ 11s) was measured via direct
  `codex exec` invocations using the same command-line contract as
  `CodexCLICopilotLLM`, not by exercising that Swift type itself end to end
  in this run (see above) — expected to match, not independently confirmed
  here.

### P4-fix results (2026-09-27, findings F1-F4 — measured on the same machine)

The stall described above (13 minutes, no output) is now root-caused: no
deadlock exists in `QwenLiveTranscriber`/`ChildProcess`/`LiveCopilotEngine`
(all independently re-inspected — see the P4-fix progress-log entry in §0
for what was checked in each). It is fully explained by (a) `print()` being
block-buffered on non-terminal stdout, hiding real progress, and (b) one
monolithic `@Test` summing many real, individually-bounded Codex CLI calls
with no section-level cap. Fixed by splitting the benchmark into 3
independent, individually-deadlined `@Test`s (`asrOnlyBenchmark`,
`codexSemanticOnlyBenchmark`, `endToEndBenchmark`) and line-buffering
stdout. All 3 were then **actually run** for real, back to back, on this
machine — no stall reproduced; combined wall time ≈ 4 minutes total, each
section finishing well inside its own hard deadline (240-300s).

This pass also applied and measured the F4 Codex CLI latency fix
(`CodexCLIGeneralProcessGenerator` now adds `--ignore-user-config -m
<the user's own configured model>` when that model can be read back from
`~/.codex/config.toml`, with automatic one-time fallback to the original
arguments on any failure — see the P4-fix progress-log entry in §0 for the
full investigation, including why `--output-schema` isn't the cost,
`-c plugins={}` doesn't reduce it, `resume` was rejected for growing
context, and `exec-server`/`app-server` (persistent modes) were not
adopted).

| Section | Metric | Result (this pass, post-fix) | Prior P4 number | Notes |
| --- | --- | --- | --- | --- |
| ASR (4-bit, shipped default) | load_ms | 1939.9 | 4023.8 | likely warm disk/page cache this run (model already installed); not a claim 4-bit loads faster in general |
| ASR (4-bit) | asr_ms p50 / p90 | 290.6 / 478.2 | 323.7 / 483.6 | consistent within measurement noise |
| ASR (4-bit) | RTF p50 / p90 | 0.040 / 0.052 | 0.042 / 0.060 | consistent |
| ASR (4-bit) | peak_memory_mb (worker) / (ps rss) | 847.4 / 448.7 | 735.5 / 138.1 | worker-reported remains the trustworthy number (see caveat above) |
| Codex CLI semantic (real `CodexCLICopilotLLM`, 12/12 succeeded, F4 fix applied) | p50 / p90 seconds | **7.11 / 8.49** | 8.98 / 10.91 (raw CLI, no fix, pre-schema-fix era) | **~21-22% faster**, measured through the real Swift wrapper this time, not just an equivalent raw CLI call |
| End-to-end (audio → endpointer → ASR → Codex semantic → snapshot, 10/10 completed, real — not estimated) | p50 / p90 seconds | **8.03 / 13.27** | ≈9.3 (analytical estimate only) | first-ever **directly measured** end-to-end number for this path |

8-bit ASR quantization was not re-measured this pass (unchanged from the
original P4 table above; F3/F4 are about the stall and Codex latency, not
re-litigating the already-confirmed 4-bit-vs-8-bit decision). Gemini/OpenAI
remain unmeasured (no Keychain key on this machine, per the same policy as
before — checked, never printed).

**Revised latency picture**: end-to-end speech-end → snapshot latency with
Codex CLI as the provider is now **~8s at p50** (previously an *estimated*
~9.3s) — still dominated almost entirely by Codex's own per-call latency
(ASR is ~0.3-0.9s of that, negligible next to Codex's ~7-11s). The F4 fix
narrows this by roughly a second at p50, but Codex CLI process/network
overhead remains the dominant cost for "realtime" Live Assist by a wide
margin; see the P4-fix progress-log entry's F4 write-up for the persistent-
Codex-mode recommendation if this needs to go further.

---

## P6 FINAL REPORT (V1 + V2, measured 2026-09-28 on this machine, Apple M1 Pro 16GB)

This is the single closing summary for the whole Live Meeting Copilot effort
(P1–P6), written at the end of P6 per this phase's task instructions. It
duplicates a little of §13's earlier P4/P4-fix material by design (so this
section is readable on its own) but the earlier material remains the
detailed record of *how* those numbers were produced.

### Current architecture reused

Nothing about the existing product was redesigned for Live Copilot. It reuses,
unchanged:
- The existing cloud provider catalog and Keychain-backed key storage
  (`Provider`, `ProviderCatalog`, `Keychain`) — `CopilotLLMs.make` just picks
  an adapter per `notesStyle`, the same enum every other provider path uses.
- `ChildProcess` (timeout/kill/pipe-draining) for every subprocess Live
  Copilot spawns (the live ASR worker, Codex CLI).
- `ManagedOfflineRuntime`/`OfflineRuntimeConfig` (the same app-managed,
  hash-pinned runtime installer every local engine uses) for the Live ASR
  runtime — a new root, not a new mechanism.
- The existing per-provider model-override mechanism (`ProviderModelSlot`,
  now with a `.live` case) and `AppState.key(for:)`/`effective(_:)`.
- The existing `AppState.init` test-injection pattern (`pipelineFactory`-style
  seams) for `liveTranscriberFactory`/`copilotLLMFactory`/`liveAudioSourceFactory`.

Nothing recording/transcription/notes-related was changed to make room for
this feature beyond two small, additive, byte-for-byte-safe-when-unused hooks
(`SystemAudioRecorder.setLivePCMSink`, `SessionRecorder.recordingAnchorHostNs`/
`setLiveSystemSink`).

### Final V1 architecture (unchanged since P4-fix)

```text
SystemAudioRecorder's live PCM sink ─┐
                                     ├─ LiveAudioFeed (per track: mono, 16kHz)
LiveMicTap (AVAudioEngine, no VP) ───┘        │
                                       SpeechEndpointer (energy VAD)
                                               │  finalized SpeechSegment
                                       RealtimeTranscriber
                                       (QwenLiveTranscriber ↔ live_asr_worker.py,
                                        persistent per-recording process)
                                               │  LiveTranscriptTurn
                                       LiveCopilotEngine (actor)
                                         ├─ LiveTurnFilter (junk/dup/echo)
                                         ├─ V1 scheduler (≤1 in-flight, coalesced,
                                         │   seq/generation-guarded, circuit breaker)
                                         ├─ CopilotLLM (Gemini | OpenAI-compatible | Codex CLI)
                                         └─ LiveMeetingState (dedup + evidence guards)
                                               │  LiveAssistSnapshot
                                       AppState+LiveAssist (@MainActor) → LiveAssistPanel
```

### Final V2 architecture (this phase)

```text
"Suggest Answer" press (questionID) ──┐         "Ask Meet Gist" submit (question) ──┐
                                       ▼                                            ▼
                          LiveCopilotEngine.suggestAnswer(questionID:contextProvider:)
                          LiveCopilotEngine.ask(_:contextProvider:)
                            │
                            ├─ SEPARATE scheduling slot from V1 above:
                            │     v2InFlightTask / v2NextSeq / v2LastAppliedSeq
                            │     (shares only the engine's `generation` counter,
                            │      so stop()/setLLM() still invalidate a V2 request
                            │      exactly like a V1 one) — V1's own inFlight/seq are
                            │      untouched, so a V2 request can never delay a V1
                            │      per-turn analysis and vice versa.
                            │     at most 1 V2 request in flight; a new one
                            │     (either kind) cancels whichever was in flight.
                            │
                            ├─ bounded context:
                            │     Suggest Answer: state.recentTurns.suffix(8)
                            │       (same 8-turn ring buffer V1 already keeps)
                            │     Ask: askTurnHistory (new, time-bounded, cap
                            │       200 turns) filtered to the last
                            │       askWindowMinutes (10), ≤8k chars
                            │     + state.compactView() (same compact STATE V1 sends)
                            │     + optional ManualFileContextProvider snippet
                            │       (0 or 1 snippet, ≤24k chars, in memory only)
                            │
                            ├─ CopilotLLM.complete(purpose: .suggestAnswer | .ask)
                            │     (same provider selection as V1; Codex CLI forces
                            │      reasoning effort "none", same as V1's .semantic —
                            │      see the 2026-09-28 progress entry for why "low"
                            │      was measured and not adopted; timeouts: Codex 60s,
                            │      HTTP 20s)
                            │
                            ├─ LiveAssistAnswerParser (tolerant JSON decode,
                            │     same tolerance policy as SemanticResultParser)
                            ├─ LiveAssistAnswerPostCheck (a known_from_meeting
                            │     claim with zero token overlap vs. the turns/state
                            │     it was given → moved to assumptions)
                            └─ LiveMetrics.recordV2Success/Failure (provider,
                                latency, per-kind p50/p90) + LiveCopilotPersistence
                                .appendAssist (question/answer/provider/latency/
                                confidence/context-FILE-NAME-only → live/assist.jsonl)
                                  │
                                  ▼
                          LiveAssistSnapshot.v2AnswerInFlight / v2Kind / v2Question /
                          v2Answer / v2Error / v2AskHistory (≤5)
                                  │
                          AppState+LiveAssist:
                            liveAutoSuggest (default off) — presses Suggest Answer
                              automatically at most once per newly detected question
                            pickLiveContextFile()/clearLiveContextFile() — NSOpenPanel,
                              .md/.txt, in-memory ManualFileContextProvider,
                              cleared on every new recording
                                  │
                          LiveAssistPanel: "Suggest Answer" button (question-gated,
                          spinner while in flight) → answer + "Dựa trên"/"Từ tài liệu
                          tham khảo"/"Suy luận — cần xác nhận" lines; "Ask Meet Gist"
                          field + context row ("Context: none" / filename + truncation
                          warning + Choose/Clear)
```

### Files changed (grouped, all phases)

**P1/P2 (Kit core, no app code)** — `Sources/MeetGistKit/LiveCopilot/`:
`LiveTypes.swift`, `LiveTextNormalize.swift`, `SpeechEndpointer.swift`,
`LiveAudioFeed.swift`, `LiveTurnFilter.swift`, `CopilotLLM.swift`,
`CopilotLLMAdapters.swift`, `LiveCopilotPrompts.swift`, `SemanticResult.swift`,
`LiveMeetingState.swift`, `LiveMetrics.swift`, `LiveCopilotPersistence.swift`,
`LiveAssistSnapshot.swift`, `LiveCopilotEngine.swift`, `QwenLiveTranscriber.swift`,
`LiveASRRuntimeManager.swift`; `Sources/MeetGistKit/Resources/live_asr_worker.py`.

**P3 (app integration)** — `Sources/MeetGistKit/LiveCopilot/LiveAssistSession.swift`,
`LiveAudioSources.swift`; `app/Sources/AppState/AppState+LiveAssist.swift`
(new file); `app/Sources/LiveAssist/LiveAssistPanel.swift`,
`LiveAssistSettingsView.swift`, `LiveAssistLabels.swift` (new files); changed:
`Sources/MeetGistKit/Recorder.swift`, `SessionRecorder.swift`,
`app/Sources/AppState/AppState.swift`, `AppState+Recording.swift`,
`AppState+Providers.swift`, `AppState+Runtimes.swift`,
`app/Sources/MenuBar/MenuBarPopover.swift`, `SettingsView.swift`, `L10n.swift`,
`MeetGistApp.swift`.

**P4/P4-fix/P4b (V1 validation + real bugs found and fixed)** — schema fix in
`LiveCopilotPrompts.swift`; `LiveAssistSession.swift` frame-ordering fix (F1);
`Recorder.swift` non-interleaved-audio fix (F2); `CopilotLLMAdapters.swift`
Codex fast-path (F4); mic-track echo fix (P4b, subsequently removed on
2026-10-03); test files: `LiveAssistSessionTests.swift`,
`AppStateLiveAssistTests.swift`, `SystemAudioPCMExtractionTests.swift`,
`CopilotLLMAdapterTests.swift` (`CodexUserConfiguredModelTests`),
`LiveCopilotBenchmarkTests.swift` (3 sections at that point).

**P5/P6 (this phase — V2 + validation)**:
- New: `Sources/MeetGistKit/LiveCopilot/LiveAssistAnswer.swift`
  (`LiveAssistV2Kind`, `LiveAssistAnswer`, `LiveAssistQAEntry`,
  `LiveAssistAnswerParser`, `LiveAssistAnswerPostCheck`,
  `LiveAssistAssistLogEntry`), `ManualFileContextProvider.swift`.
- Changed (Kit): `LiveCopilotPrompts.swift` (+`answerSystemPrompt`,
  `answerJSONSchema`, `answerUserContent`), `LiveCopilotEngine.swift`
  (+V2 Config fields, +`suggestAnswer`/`ask` public API, +V2 scheduling
  private state/methods), `LiveAssistSnapshot.swift` (+`v2*` fields,
  +`LiveAssistV2State`), `LiveMetrics.swift` (+V2 entry field/methods/summary
  fields), `LiveCopilotPersistence.swift` (+`appendAssist`),
  `LiveAssistSession.swift` (+`suggestAnswer`/`ask` pass-throughs),
  `CopilotLLMAdapters.swift` (Codex effort-"none" now covers all 3
  `CopilotPurpose` cases via one `reasoningEffort(for:configured:)` helper).
- Changed (app): `AppState.swift` (+`liveAutoSuggest` setting),
  `AppState+LiveAssist.swift` (+`LiveAssistState.contextProvider`/
  `lastAutoSuggestedQuestionID`, +`suggestAnswer()`/`askMeetGist(_:)`/
  `pickLiveContextFile()`/`clearLiveContextFile()`, +`maybeAutoSuggest`,
  context cleared in `startLiveAssistIfEnabled`), `LiveAssistPanel.swift`
  (+Suggest Answer button/in-progress state/answer section/Ask field/context
  row), `LiveAssistSettingsView.swift` (+auto-suggest toggle),
  `LiveAssistLabels.swift` (+9 V2 content-language functions), `L10n.swift`
  (+4 V2 app-chrome strings).
- New tests: `tests/MeetGistKitTests/LiveCopilotV2Tests.swift`
  (`LiveCopilotV2PromptTests`, `LiveAssistAnswerParserTests`,
  `LiveAssistAnswerPostCheckTests`, `ManualFileContextProviderTests`,
  `LiveCopilotSchemaStrictModeTests`); 11 new tests in
  `LiveCopilotEngineTests.swift`; 1 new test in `CopilotLLMAdapterTests.swift`;
  6 new tests in `AppStateLiveAssistTests.swift`; 1 new env-gated benchmark
  test (`suggestAnswerAndAskMeetGistBenchmark`) in
  `LiveCopilotBenchmarkTests.swift`.
- Docs: this file, `docs/ARCHITECTURE.md`, `AGENTS.md`.

### Models / providers

- **Realtime ASR**: `mlx-community/Qwen3-ASR-0.6B-4bit`, revision
  `313d850181767edf09f00a9c289becca70e58cd0`, via `mlx-audio` 0.5.6 (same
  pinned stack as the one-shot offline Qwen3-ASR engine), running as a
  **persistent per-recording process** (`live_asr_worker.py`) under a
  separate app-managed runtime root
  (`~/Library/Application Support/MeetGist/LiveASR/Qwen3-ASR-0.6B/v1`,
  pinned CPython 3.11.16, hash-locked requirements). 8-bit alternative
  (`mlx-community/Qwen3-ASR-0.6B-8bit`, revision
  `89e96d92ba34aca20b3e29fb10cc284097d1219f`) measured and not shipped (§13's
  original P4 table). V2 does not touch ASR at all — it only ever consumes
  already-transcribed `LiveTranscriptTurn`s.
- **Semantic LLM providers** (V1 and V2 both): `.gemini` (Gemini API, JSON
  mode via `responseMimeType`), `.chat` (any OpenAI-compatible endpoint, JSON
  mode via `response_format`, with a once-per-session fallback to no JSON
  mode on a 400), `.codexCLI` (the user's own `codex` CLI, ChatGPT-account
  login, `--output-schema` for structured output). **No Claude/Anthropic
  provider** — confirmed not needed (plan §3); `.apple`/`.qwenMLX` (on-device)
  are explicitly rejected for Live Assist with a clear message.
- **Provider selection rule** (unchanged by V2): `liveAssistProviderID` if
  set, else the Notes provider *only if* it's already a cloud provider —
  never a silent fallback from an on-device Notes provider to some cloud
  provider Live Assist never asked for. V2 reuses exactly this resolution
  (`resolveLiveLLM()`); there is no separate "V2 provider" setting.
- **In practice on this machine**: Codex CLI is the only provider with real
  measurements (no Gemini/OpenAI key in this machine's Keychain, checked via
  `Keychain.get` only, never printed) — matches the task's stated priority
  ("Codex CLI is currently the ONLY live LLM provider in practice").

### LLM prompt contracts

- **Semantic** (V1, per turn): system prompt is short and fixed; user
  content = `LANGUAGE` + a compact `STATE` (topic, ≤6 key points, open
  questions, decisions, action items) + `RECENT TURNS` (2-3 turns, ≤900
  chars, context only) + `CURRENT TURNS` (1-3 coalesced turns, never
  truncated). Output: `{meaning, speech_act, is_question, question, topic,
  key_points[], decisions[{text,evidence}], action_items[{text,owner,deadline,evidence}],
  open_questions[], resolved_open_question_ids[]}` — `semanticJSONSchema`.
- **Suggested Answer** (V2, on demand): system prompt instructs the model to
  answer one question in 1-3 short, sayable sentences, separating
  known-from-meeting vs. from-context vs. assumptions, and to say "not
  enough information" rather than guess. User content = `LANGUAGE` +
  `QUESTION` + compact `STATE` + `TURNS` (≤8 recent turns, generous char cap)
  + optional `CONTEXT` (the picked file's name + its capped text). Output:
  `{answer, known_from_meeting[], from_context[], assumptions[], confidence}`
  — `answerJSONSchema`.
- **Ask Meet Gist** (V2, free-form): identical system prompt and output
  schema to Suggested Answer; only the `TURNS` window differs (last
  `askWindowMinutes` = 10 minutes of turns from a separate, larger,
  time-bounded buffer, ≤8k chars) and there's no `questionID` gate (any
  non-empty typed question is accepted).
- All three schemas are OpenAI strict-mode-safe (`additionalProperties:
  false` on every object, every property in `required`) — verified by a
  generic recursive test (`LiveCopilotSchemaStrictModeTests`) that walks
  every schema this codebase ships, not hand-checked per schema.

### Performance — every number measured across P4/P4-fix/P6, clearly marked

| What | p50 | p90 | Success rate | Phase / notes |
| --- | --- | --- | --- | --- |
| ASR, 4-bit (shipped) — asr_ms | 290.6 ms | 478.2 ms | n/a | P4-fix, real worker |
| ASR, 4-bit — RTF (asr/audio) | 0.040 | 0.052 | n/a | P4-fix, real worker |
| ASR, 4-bit — peak memory (worker-reported) | 847.4 MB | — | n/a | P4-fix; `ps -o rss` disagrees, see caveat in §13 above |
| ASR, 8-bit — asr_ms | 350.0 ms | 596.9 ms | n/a | original P4 only, not re-measured in P4-fix/P6 |
| Codex CLI semantic (V1, real `CodexCLICopilotLLM`) | 7.11 s | 8.49 s | 12/12 | P4-fix, post-F4-fix |
| End-to-end (audio → …→ snapshot, Codex) | 8.03 s | 13.27 s | 10/10 | P4-fix, real (not estimated) |
| **Suggest Answer (V2, real Codex CLI)** | **6.01 s** | **8.68 s** | **10/10 (100%)** | **P6, this phase** |
| **Ask Meet Gist (V2, real Codex CLI)** | **6.37 s** | **19.17 s** | **10/10 (100%)** | **P6, this phase — 2 of 10 calls ran 15-19s under real system load, same kind of tail P4-fix saw on the semantic path; median stayed ~6s** |
| Gemini / OpenAI (any purpose) | — | — | **not measured** | no Keychain key on this machine, any phase |

V2's Suggest Answer/Ask latencies (~6s p50) are *lower* than V1's semantic
p50 (7.11s) despite a larger prompt (more turns, a longer system prompt) —
consistent with F4's finding that Codex CLI's latency is dominated by fixed
per-call overhead (process start, remote session creation) rather than
prompt size; this is a repeat, not a new, confirmation of that model.

### Failure behavior (V2, additive to V1's table in §5.14)

| Failure | Behavior |
| --- | --- |
| No cloud provider configured | `v2Error` = "Choose a cloud provider for Live Assist."; no request made |
| `questionID` doesn't match the current question | Silent no-op (stale press) |
| Timeout / network / 4xx / 5xx / Codex unavailable | `v2Error` set to a clear message; `v2AnswerInFlight` cleared; V1's circuit breaker is untouched (V2 has no circuit breaker of its own — a single failed V2 request just leaves an error message, since V2 is always user-initiated, never a background loop) |
| Malformed JSON | `v2Error` set; no state mutation, same "never guess" policy as V1's malformed handling |
| A new V2 request arrives while one is in flight | The old one is cancelled; if it still completes afterward (a race), a seq/generation guard (`finishV2InFlight(seq:)`, `seq == v2NextSeq`) stops it from ever touching state the newer request already owns |
| `stop()`/`setLLM()` while a V2 request is in flight | Cancelled, generation bump guarantees it can never publish afterward — mirrors V1's exact mechanism |
| Manual context file can't be read | `pickLiveContextFile` surfaces the read error into `v2Error`; the session continues with no context |
| Manual context file too long | Silently capped at ~24k chars; `truncated` flag shown in the panel — never a hard failure |

### Tests

`make test`: **281 Swift Testing tests (49 suites)** + **42 Python unittest
tests** (1 pre-existing, unrelated skip), all green. Baseline before P5/P6:
240 Swift tests (44 suites). **This phase added 40 new always-run Swift
tests across 5 new suites** (`LiveCopilotV2PromptTests`,
`LiveAssistAnswerParserTests`, `LiveAssistAnswerPostCheckTests`,
`ManualFileContextProviderTests`, `LiveCopilotSchemaStrictModeTests`) **plus
11/1/6 new tests in the existing `LiveCopilotEngineTests`/
`CopilotLLMAdapterTests`/`AppStateLiveAssistTests` suites**, and **1 new
env-gated benchmark test** — zero pre-existing tests changed or broken.
`swift build` and `swift build --target MeetGistApp` both green, no new
warnings. See the 2026-09-28 progress-log entry (§0) for the full breakdown
of which test covers which required case (manual Suggest Answer, Ask with/
without context, context cap/truncation, unsupported-claim-to-assumptions,
auto-suggest default-off, new-request-cancels-old, stale-answer-ignored,
V2-doesn't-delay-V1, schema strict-mode).

### UX examples (Vietnamese, from the real pipeline on synthetic meeting content — P6, this phase)

All of the following are **real Codex CLI output** (`gpt-6-luna`, reasoning
effort "none") on a fully synthetic meeting (a fake sprint/roadmap
discussion — API gateway deploy, OAuth/SAML, a database migration, a
payments feature deadline, a pricing-model approval), never real user data.

**Họ đang nói (meaning):**
1. "Người nói muốn xác nhận lịch chuyển đổi cơ sở dữ liệu là thứ Sáu này hay
   cần dời sang tuần sau."
2. "Người nói muốn xác nhận liệu tính năng thanh toán có phải hoàn thành
   trước cuối tháng này hay không."
3. "Người nói muốn biết khách hàng đã duyệt mô hình giá mới chưa hay vẫn
   chờ bộ phận pháp lý xem xét."

**Họ đang hỏi (detected question):**
1. "Việc chuyển đổi cơ sở dữ liệu được lên lịch vào thứ Sáu này hay nên dời
   sang tuần sau?"
2. "Thời hạn hoàn thành tính năng thanh toán có phải trước cuối tháng này
   không?"
3. "Khách hàng đã duyệt mô hình giá mới chưa, hay vẫn đang chờ pháp lý xem
   xét?"

**Live Notes (real accumulated state after 6 turns):**
1. Key point: "Dịch vụ xác thực mới cần hỗ trợ OAuth 2.0 và SAML cho khách
   hàng enterprise trong quý này."
2. Action item: "Deploy phiên bản mới của API gateway lên production trước
   release ngày mai."
3. Open question: "Việc chuyển đổi cơ sở dữ liệu được lên lịch vào thứ Sáu
   này hay nên dời sang tuần sau?"

**Suggested Answer:**
1. Q: "Is the database migration confirmed for this Friday?" → A: "Chưa,
   lịch chuyển đổi cơ sở dữ liệu vẫn đang cần xác nhận; cuộc họp chưa chốt
   là thứ Sáu này hay tuần sau." — Dựa trên: "Có người hỏi liệu chuyển đổi
   cơ sở dữ liệu sẽ diễn ra thứ Sáu này hay dời sang tuần sau." — không có
   suy luận nào bị gắn nhãn "cần xác nhận" (mô hình không đoán mò).
2. Q: "Liệu bản demo thanh toán có sẵn sàng trước cuối tuần không?" → A:
   "Trong phần cuộc họp hiện có, chưa thấy thông tin liệu bản demo thanh
   toán có sẵn sàng trước cuối tuần hay không; chỉ có câu hỏi mở về thời hạn
   hoàn thành tính năng thanh toán trước cuối tháng." (đúng: model từ chối
   đoán khi không có dữ kiện).
3. Q: "Should we increase headcount on the platform team next sprint?" → A:
   "Trong phần thông tin cuộc họp hiện có, chưa có quyết định hay dữ kiện về
   nhu cầu tăng nhân sự cho nhóm platform ở sprint tới. Bạn có thể nói rằng
   cần thêm thông tin về khối lượng công việc và năng lực hiện tại trước khi
   quyết định." (một gợi ý người dùng có thể nói ngay, không bịa quyết định).

**Ask Meet Gist:**
1. Q: "Tóm tắt 5 phút vừa rồi giúp tôi." → A: "Vừa rồi, mọi người thống
   nhất xem lại việc tuần trước rồi bàn lộ trình, tập trung vào tiến độ dự
   án và các vấn đề tồn đọng. Dịch vụ xác thực cần hỗ trợ OAuth 2.0 và SAML
   trong quý này; cần xác nhận lịch chuyển đổi cơ sở dữ liệu và hạn tính
   năng thanh toán. Việc cần làm là deploy phiên bản mới của API gateway lên
   production trước release ngày mai." (15.4s — one of the two slow-tail
   calls; correct and complete despite the latency).
2. Q: "Có action item nào giao cho tôi không?" → A: "Có một action item:
   deploy phiên bản mới của API gateway lên production trước release ngày
   mai. Cuộc họp chưa nêu rõ người phụ trách, nên chưa xác nhận được là giao
   cho bạn." — Suy luận — cần xác nhận: "Chưa có thông tin xác nhận bạn là
   người phụ trách action item này." (correct use of `assumptions` — the
   model does not claim the item is the user's without evidence).
3. Q: "Có câu hỏi nào vẫn đang bỏ ngỏ chưa được trả lời không?" → A: "Có hai
   câu hỏi vẫn đang bỏ ngỏ: lịch chuyển đổi cơ sở dữ liệu là thứ Sáu này hay
   tuần sau, và tính năng thanh toán có phải hoàn thành trước cuối tháng này
   không." (19.2s — the other slow-tail call; both open questions correctly
   listed with no invented ones).

### Known limitations (V1 + V2, carried forward and new)

- No real-microphone/real-meeting/real-GUI-panel verification anywhere in
  P1–P6 — this environment cannot grant macOS permissions (Microphone,
  Screen Recording) or run a windowed `MeetGistApp`. Every claim above is
  either a headless unit/integration test (real Kit code, fake audio/ASR/
  transport where a real OS resource would be needed) or a real network/CLI
  call in isolation (real Codex CLI, real installed ASR model).
- Gemini/OpenAI-compatible providers remain completely unmeasured (V1 and
  V2 alike) — no Keychain key exists on this machine. The code path is
  identical in shape to Codex CLI's (same `CopilotLLM` protocol, same JSON
  schema), so it's expected to work, but "expected" is not "measured."
  Recommendation if this matters: measure Gemini/OpenAI once a key is
  available, since their JSON-mode/latency characteristics could differ
  meaningfully from Codex CLI's.
- No persistent/reusable Codex CLI process was adopted for V2 either (same
  F4 finding as V1: `codex exec resume` grows context — and therefore
  latency — every turn, and `exec-server`/`app-server` are undocumented
  experimental protocols) — every Suggest Answer/Ask request still pays a
  fresh `codex exec` process's full per-call overhead, so Codex CLI's ~6-9s
  p50 stays the dominant end-to-end cost for every live feature (semantic,
  Suggest Answer, Ask) on this provider.
- Ask Meet Gist's "last N minutes" window is approximate: it depends on
  `askTurnHistory`'s 200-turn cap actually covering `askWindowMinutes`
  worth of real speech, which holds for any realistic meeting pace but is
  not an exact time-based ring buffer with unlimited turns.
- The V2 answer's `confidence` field is passed through from the model
  as-is (not independently verified the way `known_from_meeting` is) — a
  model could claim "high" confidence for a wrong-but-plausible-sounding
  answer; the UI shows it as informational text, not a guarantee.
- `liveAutoSuggest` fires once per newly detected question id — if the same
  underlying question gets re-asked later in the meeting (a new, different
  `LiveMeetingState.lastQuestionID` even though the text is similar), it
  will auto-fire again; this matches the plan's "at most once per question"
  wording literally (by id, not by semantic similarity) and was a deliberate
  simplicity choice, not an oversight.

### Future V3/V4 extension points (confirmed still valid, not implemented)

- **V3 Meeting Memory / RAG**: a second `LiveContextProvider` conformer
  (e.g. `MeetingMemoryProvider`) can be built and swapped in wherever
  `ManualFileContextProvider` is used today — `LiveCopilotEngine.suggestAnswer`/
  `ask` only depend on the protocol, never the concrete type. The
  `from_context`/`assumptions` split in the answer schema already
  anticipates a provider whose evidence needs the same "grounded vs.
  inferred" separation. No embeddings/indexing/vector DB were added in V2,
  consistent with the plan.
- **V4 Proactive Copilot**: unchanged from the original plan — a
  `ProactiveRule` pass after `LiveMeetingState.apply` (contradiction
  detection, "action item with no owner" nudges, "question open for N
  minutes" alerts) remains the natural extension point; V2's `LiveAssistAnswer`
  schema (`known_from_meeting`/`assumptions`) is a reasonable template for
  how a future proactive alert would separate what it's sure of from what
  it's guessing, but no code for this exists yet.
