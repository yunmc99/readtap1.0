//
//  DeviceIdentifier.swift
//  readtap
//
//  Persistent device identifier stored in Keychain.
//  Survives app uninstall/reinstall on the same device.
//  Used for trial abuse prevention (one trial per device).
//

import Foundation
import Security
import UIKit

enum DeviceIdentifier {

    private static let service = "com.realtap.readtap.device"
    private static let account = "device_id"

    /// Returns a stable device ID. Reads from Keychain first;
    /// if not found, generates one from IDFV (or UUID fallback) and persists it.
    static func current() -> String {
        if let existing = readFromKeychain() {
            return existing
        }
        let newId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        saveToKeychain(newId)
        return newId
    }

    // MARK: - Keychain helpers

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:       service,
            kSecAttrAccount as String:       account,
            kSecValueData as String:         data,
            kSecAttrAccessible as String:    kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
