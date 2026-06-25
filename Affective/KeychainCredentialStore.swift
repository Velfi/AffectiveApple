//
//  KeychainCredentialStore.swift
//  Affective
//
//  Created by OpenAI on 6/24/26.
//

import Foundation
import Security

nonisolated enum ProviderCredentialKey: String, CaseIterable {
    case openAI = "openai_api_key"
    case anthropic = "anthropic_api_key"
    case google = "google_api_key"

    var account: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        }
    }

    var fieldLabel: String {
        "\(displayName) API key"
    }

    var creationURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .google: URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }
}

nonisolated struct KeychainCredentialStore {
    private let service = "com.zelda-built-this.AMBI.provider-credentials"

    func credential(for key: ProviderCredentialKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainCredentialError.invalidStoredData
        }
        return String(data: data, encoding: .utf8)
    }

    func saveCredential(_ credential: String, for key: ProviderCredentialKey) throws {
        let data = Data(credential.utf8)
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError.unhandledStatus(addStatus)
            }
            return
        }
        throw KeychainCredentialError.unhandledStatus(status)
    }

    func deleteCredential(for key: ProviderCredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unhandledStatus(status)
        }
    }

    private func baseQuery(for key: ProviderCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }
}

nonisolated enum KeychainCredentialError: LocalizedError {
    case invalidStoredData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            return "The stored credential could not be decoded."
        case .unhandledStatus(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}
