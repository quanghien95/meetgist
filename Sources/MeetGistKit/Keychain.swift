// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Longfu Xu
import Foundation
import Security

/// A Keychain operation failed. Carries the raw `OSStatus` plus a readable
/// message (via `SecCopyErrorMessageString`) so a failed save can be surfaced
/// to the user instead of silently pretending to succeed. See P2-4.
public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(message)"
    }
}

/// Tiny Keychain wrapper for BYOK API keys. Stored as generic passwords under the
/// app's service; never written to disk in plaintext.
public enum Keychain {
    public static let service = "app.meetgist.keys"

    /// Throws `KeychainError` if the save (or the delete-before-save step)
    /// fails, rather than silently discarding the failure. An empty `value`
    /// only deletes the existing item, if any.
    public static func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(deleteStatus)
        }
        if value.isEmpty { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// `errSecItemNotFound` (nothing to remove) is treated as success.
    public static func remove(_ account: String) throws { try set("", for: account) }
}
