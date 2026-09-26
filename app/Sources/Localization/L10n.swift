// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import SwiftUI

enum Lang: String, CaseIterable, Identifiable {
    case system, en, zh
    var id: String { rawValue }
}

/// One localized string in EN + 简体中文.
struct LStr: Sendable {
    let en: String
    let zh: String
}

/// Runtime localization — switching `lang` in Settings updates the UI instantly,
/// no restart. Injected as an EnvironmentObject; views call `loc.t(L.start)`.
@MainActor
final class Localization: ObservableObject {
    @Published var lang: Lang {
        didSet {
            UserDefaults.standard.set(lang.rawValue, forKey: Self.key)
            Theme.cjk = effective == .zh
        }
    }
    private static let key = "MeetGistLang"

    init() {
        lang = Lang(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "system") ?? .system
        Theme.cjk = effective == .zh   // didSet doesn't fire from init; set explicitly.
    }

    var effective: Lang {
        if lang != .system { return lang }
        let code = Locale.preferredLanguages.first ?? "en"
        return code.hasPrefix("zh") ? .zh : .en
    }

    func t(_ s: LStr) -> String { effective == .zh ? s.zh : s.en }
    /// Convenience: `loc(L.start)`.
    func callAsFunction(_ s: LStr) -> String { t(s) }

    func name(of lang: Lang) -> String {
        switch lang {
        case .system: return effective == .zh ? "跟随系统" : "Follow System"
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }
}

/// All UI strings, EN + 中文. Add cases here as the UI grows.
enum L {
    // Brand / tagline
    static let tagline   = LStr(en: "Get the gist. Skip the rest.", zh: "抓重点，去废话。")

    // Actions
    static let start     = LStr(en: "Start", zh: "开始")
    static let stop      = LStr(en: "Stop", zh: "停止")
    static let pause     = LStr(en: "Pause", zh: "暂停")
    static let resume    = LStr(en: "Resume", zh: "继续")
    static let settings  = LStr(en: "Settings", zh: "设置")
    static let done      = LStr(en: "Done", zh: "完成")
    static let cancel    = LStr(en: "Cancel", zh: "取消")
    static let retry     = LStr(en: "Retry", zh: "重试")
    static let install   = LStr(en: "Install", zh: "安装")
    static let remove    = LStr(en: "Remove", zh: "移除")
    static let rename    = LStr(en: "Rename", zh: "重命名")
    static let moveToTrash = LStr(en: "Move to Trash", zh: "移到废纸篓")
    static let renameMeeting = LStr(en: "Rename Meeting", zh: "重命名会议")
    static let deleteMeeting = LStr(en: "Delete Meeting?", zh: "删除会议？")
    static let meetingName = LStr(en: "Meeting name", zh: "会议名称")
    static let deleteMeetingWarning = LStr(
        en: "The meeting folder and its audio will be moved to Trash.",
        zh: "会议文件夹及其音频将被移到废纸篓。")
    static let generateMinutes = LStr(en: "Generate Minutes", zh: "生成纪要")
    static let regenerateMinutes = LStr(en: "Regenerate Minutes", zh: "重新生成纪要")
    static let export    = LStr(en: "Export", zh: "导出")
    static let regenerate = LStr(en: "Regenerate", zh: "重新生成")
    static let transcribe = LStr(en: "Transcribe", zh: "转录")
    static let retranscribe = LStr(en: "Re-transcribe", zh: "重新转录")
    static let retranscribeConfirmation = LStr(en: "Re-transcribe this meeting?", zh: "重新转录此会议？")
    static let retranscribeWarning = LStr(
        en: "This clears the generated transcript and saved transcription progress. Original audio is kept.",
        zh: "这会清除生成的转录文本和已保存的转录进度。原始音频会保留。")
    static let copy      = LStr(en: "Copy", zh: "复制")
    static let reveal    = LStr(en: "Reveal in Finder", zh: "在访达中显示")
    static let openApp   = LStr(en: "Open MeetGist", zh: "打开 MeetGist")
    static let transcribeLatest = LStr(en: "Transcribe latest recording", zh: "转录最近一次录音")
    static let quit      = LStr(en: "Quit MeetGist", zh: "退出 MeetGist")

    // Status
    static let idle       = LStr(en: "Idle", zh: "空闲")
    static let recording  = LStr(en: "Recording", zh: "录制中")
    static let paused     = LStr(en: "Paused", zh: "已暂停")
    static let processing = LStr(en: "Processing", zh: "处理中")
    static let error      = LStr(en: "Error", zh: "出错")
    static let ready      = LStr(en: "Ready", zh: "就绪")
    static let transcribing = LStr(en: "Transcribing", zh: "转录中")
    static let localTranscription = LStr(en: "Local transcription", zh: "本地转录")
    static let chunk      = LStr(en: "Chunk", zh: "分块")
    static let notInstalled = LStr(en: "Not Installed", zh: "未安装")
    static let summarizing  = LStr(en: "Summarizing", zh: "总结中")
    static let saved        = LStr(en: "Saved", zh: "已保存")

    // Library
    static let meetings   = LStr(en: "Meetings", zh: "会议记录")
    static let search     = LStr(en: "Search", zh: "搜索")
    static let noMeetings = LStr(en: "No meetings yet. Press Record (or ⌥⌘K) to start.",
                                 zh: "还没有记录。按下录制（或 ⌥⌘K）开始。")
    static let record     = LStr(en: "Record", zh: "录制")
    static let importAudio = LStr(en: "Import Audio…", zh: "导入音频…")
    static let loadingMeetings = LStr(en: "Loading meetings…", zh: "正在加载会议…")
    static let meetingsCount = LStr(en: "meetings", zh: "个会议")
    static let emptyHint  = LStr(
        en: "Press ⌥⌘K (or Record) to capture a meeting. MeetGist writes the transcript, polished minutes, and a summary with decisions & action items.",
        zh: "按 ⌥⌘K（或点「录制」）开始记录。结束后自动生成转录、精炼纪要，以及含关键决定与行动项的摘要。")

    // Detail sections
    static let summary      = LStr(en: "Summary", zh: "摘要")
    static let minutes      = LStr(en: "Minutes", zh: "纪要")
    static let keyDecisions = LStr(en: "Key decisions", zh: "关键决定")
    static let actionItems  = LStr(en: "Action items", zh: "行动项")
    static let transcript   = LStr(en: "Transcript", zh: "转录")
    static let timeline     = LStr(en: "Timeline", zh: "时间线")
    static let audioTracks  = LStr(en: "Audio tracks", zh: "音轨")
    static let notesSeparateStage = LStr(
        en: "The transcript is ready. Minutes and Summary are generated separately using your selected Notes provider.",
        zh: "转录已完成。纪要和摘要需要使用所选的笔记服务单独生成。")
    static let notesNeedProvider = LStr(
        en: "The transcript is ready. Select a Notes provider and add its API key in Settings to generate Minutes and Summary.",
        zh: "转录已完成。请在设置中选择笔记服务并添加 API 密钥，以生成纪要和摘要。")
    static let me           = LStr(en: "Me", zh: "我")
    static let system       = LStr(en: "System", zh: "对方")

    // Settings sections
    static let general   = LStr(en: "General", zh: "通用")
    static let language  = LStr(en: "Language", zh: "语言")
    static let hotkey    = LStr(en: "Hotkey", zh: "快捷键")
    static let audio     = LStr(en: "Audio", zh: "音频")
    static let recordingSection = LStr(en: "Recording", zh: "录制")
    static let aiProvider = LStr(en: "AI Provider", zh: "AI 服务商")
    static let privacy   = LStr(en: "Privacy", zh: "隐私")
    static let about     = LStr(en: "About", zh: "关于")
    static let recordingPresence = LStr(en: "Recording presence", zh: "录制时的存在感")
    static let presenceMenuBar = LStr(en: "Menu bar only", zh: "仅菜单栏")
    static let presenceMini = LStr(en: "Mini floating controller", zh: "迷你浮窗")
    static let autoTranscribe = LStr(en: "Transcribe automatically after recording",
                                     zh: "录制结束后自动转录")
    static let autoGenerateNotes = LStr(en: "Generate Minutes & Summary automatically after transcription",
                                        zh: "转录完成后自动生成纪要和摘要")
    static let launchAtLogin = LStr(en: "Launch at login", zh: "登录时启动")
    static let microphone = LStr(en: "Microphone", zh: "麦克风")
    static let screenRecording = LStr(en: "Screen Recording (system audio)", zh: "屏幕录制（系统声音）")
    static let granted = LStr(en: "Granted", zh: "已授权")
    static let notGranted = LStr(en: "Not granted", zh: "未授权")
    static let openSystemSettings = LStr(en: "Open System Settings", zh: "打开系统设置")
    static let templateSection = LStr(en: "Notes template", zh: "笔记模板")
    static let useTemplateLabel = LStr(en: "Use a custom template for the notes", zh: "用自定义模板生成笔记")
    static let loadFromFile = LStr(en: "Load from file…", zh: "从文件载入…")
    static let templateHint = LStr(
        en: "When on, the Notes step fills your template from the transcript instead of the default minutes/summary. Paste any structure with headings (Markdown works).",
        zh: "开启后，笔记将按你的模板从转录中填充，而不是默认纪要/摘要。可粘贴任意带标题的结构（支持 Markdown）。")
    static let referenceTemplates = LStr(en: "Start from a reference", zh: "从参考模板开始")
    static let useAsStartingPoint = LStr(en: "Use", zh: "使用")

    // Messages
    static let needKey = LStr(en: "Add an API key in Settings to generate notes.",
                              zh: "在设置里添加 API Key 才能生成笔记。")
    static let recordedNoKey = LStr(en: "Recorded. Add an API key in Settings to generate notes.",
                                    zh: "已录制。在设置里添加 API Key 即可生成笔记。")
    static let privacyStatement = LStr(
        en: "Local-first. You control recording. No bot joins your call. Audio stays on your Mac; only transcription requests go to the provider whose key you supplied.",
        zh: "本地优先。录制由你主动控制。无需机器人入会。音频保存在你的 Mac 上；只有转录请求会发送到你填入 Key 的服务商。")
    static let aboutFree = LStr(
        en: "MeetGist is free and open source (AGPL-3.0). Provided as-is, no warranty or commercial support.",
        zh: "MeetGist 免费开源（AGPL-3.0）。按现状提供，无质保、无商业支持。")

    // MARK: - AppState status & messages
    // AppState is not a View and has no Localization of its own; these keys are
    // read through `AppState.tr(_:)`, which falls back to English if the
    // Localization instance hasn't been installed yet (see
    // AppState.installMiniController(loc:)).
    static let statusRecording = LStr(en: "Recording…", zh: "录制中…")
    static let statusFinishing = LStr(en: "Finishing…", zh: "正在结束…")
    static let couldNotStart = LStr(en: "Couldn't start", zh: "无法开始")
    static let recordedMessage = LStr(en: "Recorded.", zh: "已录制。")
    static let importedMessage = LStr(en: "Imported", zh: "已导入")
    static let installLocalEngineSuffix = LStr(
        en: "Install the local transcription engine in Settings to transcribe.",
        zh: "请在设置中安装本地转录引擎以开始转录。")
    static let statusTranscribing = LStr(en: "Transcribing…", zh: "转录中…")
    static let notesReadyMessage = LStr(en: "Notes ready.", zh: "纪要已生成。")
    static let transcriptReadyMessage = LStr(en: "Transcript ready.", zh: "转录已完成。")
    static let canceledMessage = LStr(en: "Canceled.", zh: "已取消。")
    static let notesFailedMessage = LStr(en: "Notes failed", zh: "纪要生成失败")
    static let transcriptSavedNotesFailed = LStr(
        en: "Transcript saved — notes failed", zh: "转录已保存——纪要生成失败")
    static let minutesReadyMessage = LStr(en: "Minutes ready.", zh: "纪要已生成。")
    static let minutesFailedMessage = LStr(en: "Minutes failed", zh: "纪要生成失败")
    static let failed = LStr(en: "Failed", zh: "失败")

    static let localNotesWhileRecordingError = LStr(
        en: "Local Notes cannot run while recording.", zh: "录制过程中无法运行本地笔记。")
    static let localNotesWhileRecordingStatus = LStr(
        en: "Stop recording before using Local Notes.", zh: "请先停止录制，再使用本地笔记。")
    static let localTranscriptionWhileRecordingError = LStr(
        en: "Local transcription cannot run while recording.", zh: "录制过程中无法进行本地转录。")
    static let localTranscriptionWhileRecordingStatus = LStr(
        en: "Stop recording before starting local transcription.", zh: "请先停止录制，再开始本地转录。")
    static let stopRecordingBeforeGenerateNotes = LStr(
        en: "Stop recording before generating meeting notes.", zh: "请先停止录制，再生成会议纪要。")
    static let stopRecordingBeforeImport = LStr(
        en: "Stop recording before importing audio.", zh: "请先停止录制，再导入音频。")
    static let waitCurrentTaskBeforeImport = LStr(
        en: "Wait for the current task to finish before importing audio.",
        zh: "请先等待当前任务完成，再导入音频。")
    static let waitProcessingFinish = LStr(en: "Wait for processing to finish.", zh: "请等待处理完成。")
    static let anotherProcessingRunning = LStr(
        en: "Another processing task is already running.", zh: "另一项处理任务正在进行中。")

    static let addKeyTranscriptionProvider = LStr(
        en: "Add an API key for the Transcription provider.", zh: "请为转录服务添加 API 密钥。")
    static let addKeyNotesProvider = LStr(
        en: "Add an API key for the Notes provider.", zh: "请为笔记服务添加 API 密钥。")
    static let appleOnDeviceUnavailable = LStr(en: "Apple On-Device is unavailable.", zh: "Apple 本机处理不可用。")
    static let installLocalQwenNotesSettings = LStr(
        en: "Install Local Qwen Notes in Settings.", zh: "请在设置中安装本地 Qwen 笔记。")
    static let localQwenNotesNotInstalled = LStr(
        en: "Local Qwen Notes is not installed.", zh: "本地 Qwen 笔记尚未安装。")
    static let installQwen3InSettings = LStr(
        en: "Install Qwen3 4B in Settings → AI Provider.", zh: "请在设置 → AI 服务商中安装 Qwen3 4B。")
    static let installCodexCLILogin = LStr(
        en: "Install Codex CLI and run `codex login` in a terminal first.",
        zh: "请先安装 Codex CLI，并在终端中运行 `codex login`。")
    static let codexCLIUnavailable = LStr(en: "Codex CLI is not available.", zh: "Codex CLI 不可用。")

    static let localTranscriptionStarting = LStr(en: "Starting local transcription…", zh: "正在启动本地转录…")
    static let localTranscriptionAlreadyRunningThis = LStr(
        en: "Local transcription is already running.", zh: "本地转录正在进行中。")
    static let localTranscriptionAlreadyRunningOther = LStr(
        en: "Another local transcription is already running.", zh: "另一项本地转录正在进行中。")
    static let transcriptReadyAddNotesProvider = LStr(
        en: "Transcript ready. Add a Notes provider to generate minutes.",
        zh: "转录已完成。添加笔记服务后可生成纪要。")
    static let writingMinutesSummary = LStr(en: "Writing minutes & summary…", zh: "正在生成纪要与摘要…")
    static let localTranscriptionPaused = LStr(en: "Local transcription paused.", zh: "本地转录已暂停。")
    static let localTranscriptionCanceled = LStr(en: "Local transcription canceled.", zh: "本地转录已取消。")
    static let localTranscriptionFailed = LStr(en: "Local transcription failed", zh: "本地转录失败")
    static let localTranscriptionReadyToResume = LStr(
        en: "Local transcription ready to resume.", zh: "本地转录可以继续。")
    static func localTranscriptionPercent(_ percent: Int) -> LStr {
        LStr(en: "Local transcription \(percent)%", zh: "本地转录 \(percent)%")
    }

    static let addPythonCodeFirst = LStr(
        en: "Add Python code in Settings first.", zh: "请先在设置中添加 Python 代码。")
    static let runningPostProcessScript = LStr(en: "Running post-process script…", zh: "正在运行后处理脚本…")
    static let postProcessScriptFinished = LStr(en: "Post-process script finished.", zh: "后处理脚本已完成。")
    static let postProcessScriptFailed = LStr(en: "Post-process script failed.", zh: "后处理脚本失败。")

    static let importingMessage = LStr(en: "Importing…", zh: "正在导入…")
    static let importFailedMessage = LStr(en: "Import failed", zh: "导入失败")

    static let couldNotRenameMeeting = LStr(en: "Could not rename meeting.", zh: "无法重命名会议。")
    static let meetingInUse = LStr(en: "Meeting is in use.", zh: "会议正在使用中。")
    static let pauseOrCancelBeforeDelete = LStr(
        en: "Pause or cancel transcription before deleting this meeting.",
        zh: "删除此会议前，请先暂停或取消转录。")
    static let couldNotMoveToTrash = LStr(en: "Could not move meeting to Trash.", zh: "无法将会议移到废纸篓。")
    static let meetingMovedToTrash = LStr(en: "Meeting moved to Trash.", zh: "会议已移到废纸篓。")
    static let couldNotSaveAPIKey = LStr(en: "Could not save the API key.", zh: "无法保存 API 密钥。")

    // MARK: - Settings: recording section
    static let change = LStr(en: "Change…", zh: "更改…")
    static let detectMeetingsLabel = LStr(
        en: "Detect Google Meet and Microsoft Teams", zh: "自动检测 Google Meet 和 Microsoft Teams")

    // MARK: - Settings: AI provider slots
    static let transcriptionSlotTitle = LStr(en: "Transcription  ·  audio → text", zh: "转录　·　音频 → 文本")
    static let notesSlotTitle = LStr(en: "Notes  ·  text → minutes & summary", zh: "笔记　·　文本 → 纪要与摘要")
    static let provider = LStr(en: "Provider", zh: "服务商")
    static let apiKey = LStr(en: "API key", zh: "API 密钥")
    static let keySavedPasteToReplace = LStr(en: "Key saved — paste to replace", zh: "已保存密钥 — 粘贴以替换")
    static let save = LStr(en: "Save", zh: "保存")
    static let set = LStr(en: "Set", zh: "设置")
    static let noKeyYet = LStr(en: "No key yet.", zh: "尚未设置密钥。")
    static let getAKey = LStr(en: "Get a key ↗", zh: "获取密钥 ↗")
    static func modelDefaultLabel(_ model: String) -> LStr {
        LStr(en: "Model (default \(model))", zh: "模型（默认 \(model)）")
    }
    static func keySetModelLabel(_ model: String) -> LStr {
        LStr(en: "Key set · model: \(model)", zh: "已设置密钥 · 模型：\(model)")
    }

    // MARK: - Settings: notes language
    static let notesLanguageSection = LStr(en: "Notes language", zh: "笔记语言")
    static let outputLanguage = LStr(en: "Output language", zh: "输出语言")
    static let notesLanguageHint = LStr(
        en: "Applies to Meeting Minutes and Summary for every Notes provider. Chinese transcripts still generate Chinese output regardless of this setting.",
        zh: "适用于所有笔记服务生成的会议纪要和摘要。无论此设置如何，中文转录内容始终生成中文输出。")

    // MARK: - Settings: post-process script
    static let postProcessScriptSection = LStr(en: "Post-process script", zh: "后处理脚本")
    static let postProcessAutoRun = LStr(
        en: "Run automatically after Minutes are ready", zh: "纪要生成后自动运行")
    static let postProcessDescription = LStr(
        en: "Python runs locally with meeting values exposed as environment variables. Its stdout and stderr are saved with the meeting.",
        zh: "Python 在本地运行，会议数据以环境变量的形式提供。其标准输出和标准错误会与会议一起保存。")

    // MARK: - Settings: offline transcription engines (Whisper / Qwen3-ASR)
    static func modelDownloadApprox(_ size: String) -> LStr {
        LStr(en: "Model download: approximately \(size). Python runtime and packages need additional space.",
             zh: "模型下载：约 \(size)。Python 运行环境和依赖包还需额外空间。")
    }
    static let offlineWhisperRequiresAppleSilicon = LStr(
        en: "Offline Local Whisper requires Apple Silicon.", zh: "离线本地 Whisper 需要 Apple 芯片。")
    static let offlineQwenASRRequiresAppleSilicon = LStr(
        en: "Offline Local Qwen3-ASR requires Apple Silicon.", zh: "离线本地 Qwen3-ASR 需要 Apple 芯片。")
    static let qwenASRNoTimestampsNote = LStr(
        en: "Qwen3-ASR has no per-sentence timestamps: each 5-minute chunk becomes one transcript line instead of one per sentence.",
        zh: "Qwen3-ASR 没有逐句时间戳：每个 5 分钟分块只生成一行转录，而不是逐句一行。")
    static let hotwordsPlaceholder = LStr(en: "Hotwords / context keywords", zh: "热词 / 上下文关键词")
    static let preset = LStr(en: "Preset", zh: "预设")
    static let hotwordsHint = LStr(
        en: "Comma-separated terms to bias transcription toward — jargon, product/client names, acronyms. Works with both Whisper and Qwen3-ASR. Pick a preset to replace the list, then edit freely. One local job and one five-minute chunk run at a time.",
        zh: "用逗号分隔的词条，用于让转录偏向这些内容——术语、产品/客户名称、缩写。对 Whisper 和 Qwen3-ASR 均适用。选择预设可替换列表，之后可自由编辑。同一时间只运行一个本地任务、一个五分钟分块。")

    // MARK: - Settings: notes providers (Apple / Local Qwen / Codex CLI)
    static let appleOnDeviceDescription = LStr(
        en: "Apple Intelligence processes the transcript on-device. The system model is managed by macOS; MeetGist does not download a separate model.",
        zh: "Apple Intelligence 会在设备本机处理转录内容。系统模型由 macOS 管理；MeetGist 不会另外下载模型。")
    static let localQwenRequiresAppleSilicon = LStr(
        en: "Local Qwen Notes requires Apple Silicon.", zh: "本地 Qwen 笔记需要 Apple 芯片。")
    static let qwenNotesRunsOfflineDescription = LStr(
        en: "Runs fully offline after setup. Most meetings are processed directly; only very long transcripts are summarized in local chunks and reduced before final Meeting Minutes generation. No cloud fallback.",
        zh: "设置完成后完全离线运行。大多数会议会直接处理；只有非常长的转录才会先在本地分块摘要、归并，再生成最终会议纪要。没有云端回退。")
    static let lastRunMetrics = LStr(en: "Last run metrics…", zh: "上次运行指标…")
    static let localQwenLastRunMetricsTitle = LStr(
        en: "Local Qwen · Last run metrics", zh: "本地 Qwen · 上次运行指标")
    static let metricsFileUnavailable = LStr(
        en: "Metrics file is no longer available.", zh: "指标文件已不存在。")
    static let reasoningEffort = LStr(en: "Reasoning effort", zh: "推理强度")
    static let effortNone = LStr(en: "None (fastest, recommended)", zh: "无（最快，推荐）")
    static let effortLow = LStr(en: "Low", zh: "低")
    static let effortMedium = LStr(en: "Medium", zh: "中")
    static let effortHigh = LStr(en: "High", zh: "高")
    static let effortExtraHigh = LStr(en: "Extra high", zh: "超高")
    static let effortMax = LStr(en: "Max", zh: "最高")
    static let viaChatGPTSubscription = LStr(en: "via your ChatGPT subscription", zh: "通过你的 ChatGPT 订阅")
    static let codexCLIDescription = LStr(
        en: "Runs the codex CLI already installed and logged in on this Mac (`codex login`). This is a cloud provider: the transcript is sent to OpenAI over your ChatGPT subscription session, the same as any other cloud Notes provider — it is not processed locally. Requires no API key.",
        zh: "运行你在本机已安装并登录的 codex CLI（`codex login`）。这是一个云端服务商：转录内容会通过你的 ChatGPT 订阅会话发送给 OpenAI，和其他云端笔记服务商一样——不会在本地处理。无需 API 密钥。")
    static let codexCLIBenchmarkNote = LStr(
        en: "Benchmarked for meeting minutes: \"None\" gives the same factual accuracy as higher effort levels but is faster and cheaper — higher levels mainly spend extra reasoning tokens without improving this task's output.",
        zh: "针对会议纪要的实测：「无」档位的事实准确度与更高档位相同，但速度更快、成本更低——更高档位主要只是多花推理 token，并不会提升本任务的输出质量。")
    static let codexCLIFound = LStr(en: "Codex CLI found", zh: "已找到 Codex CLI")
    static let codexCLINotFound = LStr(
        en: "Codex CLI not found — install it and run `codex login`",
        zh: "未找到 Codex CLI — 请安装后运行 `codex login`")

    // MARK: - Settings: custom providers
    static let customProvidersSection = LStr(
        en: "Custom providers (OpenAI-compatible · for Notes)", zh: "自定义服务商（兼容 OpenAI · 用于笔记）")
    static let addCustomProvider = LStr(en: "Add custom provider", zh: "添加自定义服务商")
    static let customProvidersHint = LStr(
        en: "Add any OpenAI-compatible chat API — DeepSeek, Moonshot/Kimi, a local server, etc. They appear in the Notes picker above.",
        zh: "添加任意兼容 OpenAI 的对话 API — DeepSeek、Moonshot/Kimi、本地服务器等。它们会出现在上方的笔记服务商列表中。")
    static let nameField = LStr(en: "Name", zh: "名称")
    static let baseURLPlaceholder = LStr(
        en: "Base URL (e.g. https://api.deepseek.com/v1)", zh: "Base URL（例如 https://api.deepseek.com/v1）")
    static let modelPlaceholder = LStr(
        en: "Model (e.g. deepseek-v4-pro)", zh: "模型（例如 deepseek-v4-pro）")
    static func savedProviderName(_ name: String) -> LStr {
        LStr(en: "Saved \(name).", zh: "已保存 \(name)。")
    }

    // MARK: - Language names (offline transcription language + notes output language pickers)
    static let langAuto = LStr(en: "Auto-detect", zh: "自动检测")
    static let langEnglish = LStr(en: "English", zh: "英语")
    static let langChinese = LStr(en: "Chinese", zh: "中文")
    static let langSpanish = LStr(en: "Spanish", zh: "西班牙语")
    static let langFrench = LStr(en: "French", zh: "法语")
    static let langGerman = LStr(en: "German", zh: "德语")
    static let langJapanese = LStr(en: "Japanese", zh: "日语")
    static let langKorean = LStr(en: "Korean", zh: "韩语")
    static let langVietnamese = LStr(en: "Vietnamese", zh: "越南语")

    // MARK: - Meeting detail
    static let runPostProcessScript = LStr(en: "Run post-process script", zh: "运行后处理脚本")
    static let postProcessTab = LStr(en: "Post-process", zh: "后处理")
    static let completedLabel = LStr(en: "Completed", zh: "已完成")
    static let skippedLabel = LStr(en: "Skipped", zh: "已跳过")
    static let localTranscriptNotReady = LStr(en: "Local transcript is not ready.", zh: "本地转录尚未就绪。")
    static func statsWordsChars(words: Int, characters: Int) -> LStr {
        LStr(en: "· \(words) words · \(characters) chars", zh: "· \(words) 词 · \(characters) 字符")
    }
    static let etaLabel = LStr(en: "ETA", zh: "预计剩余")
    static let etaLessThanMinute = LStr(en: "< 1 min", zh: "< 1 分钟")
    static func etaMinutes(_ minutes: Int) -> LStr {
        LStr(en: "\(minutes) min", zh: "\(minutes) 分钟")
    }

    // MARK: - Library
    static let oneMeeting = LStr(en: "1 meeting", zh: "1 个会议")
}
