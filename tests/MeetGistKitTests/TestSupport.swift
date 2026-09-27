// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation

/// Shared helpers for the MeetGistKit Swift Testing suites.
///
/// Swift Testing runs tests concurrently by default, so every test that
/// touches the filesystem gets its own uniquely-named temporary directory
/// (never a fixed path) and cleans up after itself with `defer`. None of the
/// code under test relies on shared/global mutable state (UserDefaults, a
/// fixed Application Support path, environment variables), so no suite here
/// needs `.serialized`.
enum TestSupport {
    /// A unique, not-yet-created temporary directory URL for a single test run.
    /// Callers create the directory (directly or via the API under test) and
    /// are responsible for removing it, typically with
    /// `defer { try? FileManager.default.removeItem(at: dir) }`.
    static func makeTempDirectoryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }
}
