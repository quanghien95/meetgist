// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Content-language labels for the Live Assist panel's per-turn sections
/// (plan §5.12). Deliberately separate from `L10n.swift`'s `LStr`/
/// `Localization` (the app's own UI chrome language, English/Chinese): these
/// labels follow `AppState.notesLanguage` instead, since that's the language
/// Live Assist's semantic output (`meaning`, `question`, notes) is actually
/// written in — showing "Họ đang nói" beside English UI chrome would be
/// backwards if the user picked Vietnamese as their *notes* language while
/// keeping the app UI in English, and vice versa.
enum LiveAssistLabels {
    private static func isVietnamese(_ notesLanguage: String) -> Bool { notesLanguage == "Vietnamese" }

    static func theyMean(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Họ đang nói" : "What they mean"
    }
    static func theyAsk(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Họ đang hỏi" : "What they're asking"
    }
    static func noActiveQuestion(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage)
            ? "Hiện không có câu hỏi nào chờ bạn trả lời."
            : "No question is waiting for you right now."
    }
    static func liveNotes(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Ghi chú trực tiếp" : "Live Notes"
    }
    static func decisions(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Quyết định" : "Decisions"
    }
    static func actionItems(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Việc cần làm" : "Action items"
    }

    // MARK: - V2 (Suggest Answer / Ask Meet Gist) — plan §7
    static func suggestAnswerButton(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Gợi ý trả lời" : "Suggest Answer"
    }
    static func generatingAnswer(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Đang tạo câu trả lời…" : "Generating answer…"
    }
    static func knownFromMeeting(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Dựa trên" : "Based on"
    }
    static func assumptions(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Suy luận — cần xác nhận" : "Inferred — please confirm"
    }
    static func fromContext(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Từ tài liệu tham khảo" : "From your context file"
    }
    static func askMeetGistTitle(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Hỏi Meet Gist" : "Ask Meet Gist"
    }
    static func askMeetGistPlaceholder(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Nhập câu hỏi…" : "Type a question…"
    }
    static func contextNone(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Ngữ cảnh: không có" : "Context: none"
    }
    static func contextTruncatedNote(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage)
            ? "Tệp quá dài — đã cắt bớt nội dung."
            : "File was too long — content was truncated."
    }
    static func answerErrorFallback(_ notesLanguage: String) -> String {
        isVietnamese(notesLanguage) ? "Không thể lấy câu trả lời — thử lại." : "Couldn't get an answer — try again."
    }
}
