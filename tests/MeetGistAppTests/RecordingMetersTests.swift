// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Combine
@testable import MeetGistApp

/// The recording ticker updates the meters 10×/s. They live on their own
/// ObservableObject so those updates never invalidate every view that
/// observes AppState (library, detail, settings).
@MainActor
@Suite(.serialized) struct RecordingMetersTests {
    @Test func meterUpdatesDoNotFireAppStateObjectWillChange() throws {
        let (state, cleanup) = try AppStateTestSupport.makeAppState()
        defer { cleanup() }
        var appStateChanges = 0
        var meterChanges = 0
        let a = state.objectWillChange.sink { _ in appStateChanges += 1 }
        let m = state.meters.objectWillChange.sink { _ in meterChanges += 1 }
        defer { a.cancel(); m.cancel() }

        for i in 0..<10 {
            state.meters.elapsed = Double(i)
            state.meters.micLevel = Double(i) / 10
            state.meters.systemLevel = Double(i) / 10
        }

        #expect(appStateChanges == 0)
        #expect(meterChanges == 30)
    }
}
