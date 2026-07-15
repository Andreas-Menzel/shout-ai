// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Security

/// Minimal Keychain wrapper for endpoint API keys, stored as generic passwords
/// under one service and keyed by the owning model entry's id — so secrets
/// never land in UserDefaults. Operations are best-effort and never throw: a
/// miss simply means "no key".
enum KeychainStore {
    private static let service = "com.shoutai.Shout.endpoint-key"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Use the modern data-protection keychain so kSecAttrAccessible is
            // honored with iOS-style semantics; must match the add below.
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Stores the key for `account`. A nil or empty value deletes it. Returns
    /// whether the store/delete succeeded.
    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        // Update an existing item in place; add it if none exists yet.
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // ThisDeviceOnly: the key never migrates to another Mac via backup
            // or Migration Assistant — it stays on the machine the user set it on.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func hasKey(account: String) -> Bool { get(account: account) != nil }
}
