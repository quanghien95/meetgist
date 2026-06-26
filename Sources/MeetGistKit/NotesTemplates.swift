// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// A ready-made notes structure the user can preview and use as a starting point for
/// a custom template. `body` is a plain Markdown skeleton (headings + placeholders) —
/// NOT a generation prompt — so `Prompts.templatedNotes` can fill it section-for-section.
/// Name / description / body each carry both languages so the Settings UI can show the
/// variant matching the app language, keeping the result single-language.
public struct NotesTemplate: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let nameZh: String
    public let desc: String
    public let descZh: String
    public let body: String
    public let bodyZh: String

    public init(id: String, name: String, nameZh: String,
                desc: String, descZh: String, body: String, bodyZh: String) {
        self.id = id; self.name = name; self.nameZh = nameZh
        self.desc = desc; self.descZh = descZh
        self.body = body; self.bodyZh = bodyZh
    }

    public func localizedName(zh: Bool) -> String { zh ? nameZh : name }
    public func localizedDesc(zh: Bool) -> String { zh ? descZh : desc }
    public func localizedBody(zh: Bool) -> String { zh ? bodyZh : body }
}

public enum NotesTemplateCatalog {
    /// Built-in reference templates. The first mirrors the app's default minutes +
    /// summary structure (`Prompts.polished`) so users can see and tweak what they get.
    public static let builtIn: [NotesTemplate] = [
        NotesTemplate(
            id: "default",
            name: "Full minutes & summary",
            nameZh: "完整纪要 + 摘要",
            desc: "The default structure MeetGist generates — full minutes plus a decisions/action-items summary.",
            descZh: "MeetGist 默认生成的结构——完整纪要，加上含决定与行动项的摘要。",
            body: """
            # Meeting Minutes

            ## Summary
            - 2–3 sentence overview

            ## Recording Information
            - **Duration**:
            - **Participants**:
            - **Type**:

            ## Discussion
            ### [Topic]
            - **Speaker**: cleaned-up point

            ## Chapter Summary
            - [MM:SS] **Chapter** — what happened

            ## Selected Quotes
            - "…" (Speaker) — why it matters

            ## To-do Items
            - [ ] Owner — task

            ## Per-Speaker Stance
            - **Speaker**:
              - Argued:
              - Committed to:

            ## TL;DR
            - 2–4 sentences

            ## Key Decisions
            -

            ## Action Items
            - [ ] Owner — task (due: …)

            ## Open Questions
            -

            ## Notable Context
            -
            """,
            bodyZh: """
            # 会议纪要

            ## 摘要
            - 2–3 句概述

            ## 录制信息
            - **时长**：
            - **参会人**：
            - **类型**：

            ## 讨论
            ### [主题]
            - **发言人**：整理后的要点

            ## 章节摘要
            - [MM:SS] **章节** — 发生了什么

            ## 精选语录
            - “…”（发言人）— 为何重要

            ## 待办事项
            - [ ] 负责人 — 任务

            ## 各发言人立场
            - **发言人**：
              - 主张：
              - 承诺：

            ## 摘要要点（TL;DR）
            - 2–4 句

            ## 关键决定
            -

            ## 行动项
            - [ ] 负责人 — 任务（截止：…）

            ## 待解决问题
            -

            ## 补充背景
            -
            """),
        NotesTemplate(
            id: "actions",
            name: "Decisions & action items",
            nameZh: "决定与行动项",
            desc: "A lean recap: just the decisions made and who owns what next.",
            descZh: "精简版：只保留做出的决定，以及接下来谁负责什么。",
            body: """
            # [Meeting]

            ## TL;DR
            - 1–2 sentences

            ## Decisions
            -

            ## Action Items
            - [ ] Owner — task (due: …)

            ## Open Questions
            -
            """,
            bodyZh: """
            # [会议]

            ## 摘要要点（TL;DR）
            - 1–2 句

            ## 决定
            -

            ## 行动项
            - [ ] 负责人 — 任务（截止：…）

            ## 待解决问题
            -
            """),
        NotesTemplate(
            id: "oneonone",
            name: "1:1 / standup",
            nameZh: "1:1 / 站会",
            desc: "For recurring syncs: topics, wins, blockers, and follow-ups.",
            descZh: "用于例行同步：话题、进展、阻碍与后续跟进。",
            body: """
            # 1:1 — [Name] · [Date]

            ## Topics
            -

            ## Wins
            -

            ## Blockers
            -

            ## Action Items
            - [ ] Owner — task

            ## Follow-ups
            -
            """,
            bodyZh: """
            # 1:1 / 站会 — [姓名] · [日期]

            ## 讨论话题
            -

            ## 进展 / 亮点
            -

            ## 阻碍
            -

            ## 行动项
            - [ ] 负责人 — 任务

            ## 后续跟进
            -
            """),
    ]
}
