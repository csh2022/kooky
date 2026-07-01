import Foundation
import Security

struct BrowserCredential: Equatable {
    var site: String
    var account: String
    var password: String
}

struct BrowserCredentialForm: Equatable {
    var site: String
    var account: String
    var password: String

    var canSave: Bool {
        !site.isEmpty && !account.isEmpty && !password.isEmpty
    }
}

@MainActor
protocol BrowserCredentialVault: AnyObject {
    func accounts(for site: String) -> [String]
    func credential(site: String, account: String) -> BrowserCredential?
    func save(_ credential: BrowserCredential) throws
    func delete(site: String, account: String) throws
}

enum BrowserCredentialVaultError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain error \(status)"
        case .invalidCredential:
            return "Credential is missing a site, account, or password"
        }
    }
}

@MainActor
final class KeychainBrowserCredentialVault: BrowserCredentialVault {
    static let shared = KeychainBrowserCredentialVault()

    private let service = "com.iamcorey.kooky.browser-credentials"

    func accounts(for site: String) -> [String] {
        let normalizedSite = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSite.isEmpty else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: normalizedSite.data(using: .utf8) as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let rows = result as? [[String: Any]]
        else { return [] }
        return rows
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func credential(site: String, account: String) -> BrowserCredential? {
        let normalizedSite = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSite.isEmpty, !normalizedAccount.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: normalizedSite.data(using: .utf8) as Any,
            kSecAttrAccount as String: normalizedAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return BrowserCredential(site: normalizedSite, account: normalizedAccount, password: password)
    }

    func save(_ credential: BrowserCredential) throws {
        let normalized = BrowserCredential(
            site: credential.site.trimmingCharacters(in: .whitespacesAndNewlines),
            account: credential.account.trimmingCharacters(in: .whitespacesAndNewlines),
            password: credential.password
        )
        guard !normalized.site.isEmpty, !normalized.account.isEmpty, !normalized.password.isEmpty else {
            throw BrowserCredentialVaultError.invalidCredential
        }
        let data = Data(normalized.password.utf8)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: normalized.site.data(using: .utf8) as Any,
            kSecAttrAccount as String: normalized.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Kooky Browser Password",
            kSecAttrDescription as String: normalized.site,
        ]
        let addQuery = key.merging(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw BrowserCredentialVaultError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw BrowserCredentialVaultError.keychain(status)
        }
    }

    func delete(site: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: site.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) as Any,
            kSecAttrAccount as String: account.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BrowserCredentialVaultError.keychain(status)
        }
    }
}
