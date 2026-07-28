// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Security

/// Minimal Keychain wrapper for endpoint API keys, stored as generic passwords
/// under one service and keyed by the owning model entry's id — so secrets
/// never land in UserDefaults. Operations are best-effort and never throw: a
/// miss simply means "no key".
///
/// Items go into the file-based login keychain, *not* the data-protection
/// keychain. The data-protection keychain requires an `application-identifier`
/// (or `keychain-access-groups`) entitlement, which only a real Team ID can
/// carry; Shout ships self-signed or ad-hoc, so every `SecItemAdd` there fails
/// with `errSecMissingEntitlement` (-34018) and the key would silently vanish.
/// The login keychain also keeps the documented uninstall step honest — items
/// are visible in Keychain Access and deletable with `security(1)`.
enum KeychainStore {
    private static let service = "de.menzelini.shout.endpoint-key"

    static func get(account: String) -> String? {
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
            // No kSecAttrAccessible here: it is a data-protection-keychain
            // attribute and is ignored by the login keychain, which unlocks
            // with the login session. Items are not synced to iCloud —
            // kSecAttrSynchronizable is off by default and never set.
            add[kSecAttrLabel as String] = "Shout — endpoint API key"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func hasKey(account: String) -> Bool { get(account: account) != nil }
}
