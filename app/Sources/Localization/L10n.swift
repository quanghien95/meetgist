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
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: Self.key) }
    }
    private static let key = "MeetGistLang"

    init() {
        lang = Lang(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "system") ?? .system
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
