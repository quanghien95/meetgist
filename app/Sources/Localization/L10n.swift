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
    static let export    = LStr(en: "Export", zh: "导出")
    static let regenerate = LStr(en: "Regenerate", zh: "重新生成")
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
    static let summarizing  = LStr(en: "Summarizing", zh: "总结中")
    static let saved        = LStr(en: "Saved", zh: "已保存")

    // Library
    static let meetings   = LStr(en: "Meetings", zh: "会议记录")
    static let search     = LStr(en: "Search", zh: "搜索")
    static let noMeetings = LStr(en: "No meetings yet. Press Record (or ⌥⌘K) to start.",
                                 zh: "还没有记录。按下录制（或 ⌥⌘K）开始。")
    static let record     = LStr(en: "Record", zh: "录制")
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
}
