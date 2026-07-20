import Foundation
import Security

protocol AIProviderCredentialStoring: Sendable {
    func primaryCredential(for profileID: UUID) async throws -> String?
    func setPrimaryCredential(_ value: String?, for profileID: UUID) async throws
    func secretHeaderValue(profileID: UUID, headerID: UUID) async throws -> String?
    func setSecretHeaderValue(_ value: String?, profileID: UUID, headerID: UUID) async throws
    func removeCredentials(profileID: UUID, headerIDs: [UUID]) async throws
    func legacyAnthropicCredential() async throws -> String?
    func removeLegacyAnthropicCredential() async throws
}

enum AIProviderCredentialError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Could not access provider credential (Keychain status \(status))."
        case .invalidStoredValue:
            "Stored provider credential is invalid."
        }
    }
}

actor AIProviderCredentialVault: AIProviderCredentialStoring {
    private static let service = "io.palmier.pro.ai-provider"

    func primaryCredential(for profileID: UUID) throws -> String? {
        try read(account: primaryAccount(profileID))
    }

    func setPrimaryCredential(_ value: String?, for profileID: UUID) throws {
        try write(value, account: primaryAccount(profileID))
    }

    func secretHeaderValue(profileID: UUID, headerID: UUID) throws -> String? {
        try read(account: headerAccount(profileID: profileID, headerID: headerID))
    }

    func setSecretHeaderValue(_ value: String?, profileID: UUID, headerID: UUID) throws {
        try write(value, account: headerAccount(profileID: profileID, headerID: headerID))
    }

    func removeCredentials(profileID: UUID, headerIDs: [UUID]) throws {
        try delete(account: primaryAccount(profileID))
        for headerID in headerIDs {
            try delete(account: headerAccount(profileID: profileID, headerID: headerID))
        }
    }

    func legacyAnthropicCredential() -> String? {
        KeychainStore.load(account: "anthropic-api-key")
    }

    func removeLegacyAnthropicCredential() {
        KeychainStore.delete(account: "anthropic-api-key")
    }

    private func primaryAccount(_ profileID: UUID) -> String {
        "provider.\(profileID.uuidString.lowercased()).primary"
    }

    private func headerAccount(profileID: UUID, headerID: UUID) -> String {
        "provider.\(profileID.uuidString.lowercased()).header.\(headerID.uuidString.lowercased())"
    }

    private func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AIProviderCredentialError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AIProviderCredentialError.invalidStoredValue
        }
        return value
    }

    private func write(_ rawValue: String?, account: String) throws {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIProviderCredentialError.unexpectedStatus(updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIProviderCredentialError.unexpectedStatus(addStatus)
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderCredentialError.unexpectedStatus(status)
        }
    }
}
