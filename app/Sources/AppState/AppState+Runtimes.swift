// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import MeetGistKit

// MARK: - Local runtimes (install / remove)
extension AppState {
    func installOfflineRuntime() { Task { await offlineRuntime.install(); refreshKeyFlag() } }
    func removeOfflineRuntime() {
        Task {
            await offlineCoordinator.cancel()
            do { try offlineRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func installQwenASRRuntime() { Task { await qwenASRRuntime.install(); refreshKeyFlag() } }
    func removeQwenASRRuntime() {
        Task {
            await qwenASRCoordinator.cancel()
            do { try qwenASRRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
    func installLocalNotesRuntime() {
        Task { await localNotesRuntime.install(); refreshKeyFlag() }
    }
    func removeLocalNotesRuntime() {
        processTask?.cancel()
        Task {
            await processTask?.value
            do { try localNotesRuntime.remove(); refreshKeyFlag() }
            catch { lastError = error.localizedDescription }
        }
    }
}
