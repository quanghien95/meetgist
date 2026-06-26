// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global start/stop recording. Default ⌥⌘K, user-customizable in Settings.
    static let toggleRecord = Self("toggleRecord",
                                   default: .init(.k, modifiers: [.option, .command]))
}
