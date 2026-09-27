// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import MeetGistKit

/// P2-4 regression: `Keychain.set`/`remove` must surface failure instead of
/// silently discarding it. These exercise the real Keychain (as `get`/`set`
/// already did before this change), scoped to a unique test account so they
/// don't collide with a real provider's stored key.
@Suite struct KeychainTests {
    @Test func setThenGetRoundTripsAndRemoveClearsIt() throws {
        let account = "meetgist-test-\(UUID().uuidString)"
        defer { try? Keychain.remove(account) }

        try Keychain.set("a-test-key", for: account)
        #expect(Keychain.get(account) == "a-test-key")

        try Keychain.remove(account)
        #expect(Keychain.get(account) == nil)
    }

    /// `remove` on an account that was never set (or already removed) must
    /// succeed rather than throw — `errSecItemNotFound` is not a failure.
    @Test func removingAnAlreadyAbsentAccountSucceeds() throws {
        let account = "meetgist-test-absent-\(UUID().uuidString)"
        #expect(Keychain.get(account) == nil)
        try Keychain.remove(account)
    }

    @Test func keychainErrorDescribesTheOSStatus() {
        let error = KeychainError(errSecItemNotFound)
        #expect(error.errorDescription?.isEmpty == false)
    }
}
