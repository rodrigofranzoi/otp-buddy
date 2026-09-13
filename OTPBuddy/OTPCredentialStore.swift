import Foundation
import Security

/// Keychain-backed storage for tracked IMAP accounts and app passwords.
///
/// Uses the standard macOS Keychain via Security.framework (app-sandbox scoped).
/// Account metadata and secrets both live here — never in UserDefaults or plain
/// Application Support files (legacy locations are migrated once, then deleted).
///
/// Note: `kSecUseDataProtectionKeychain` is intentionally **not** used on macOS —
/// it returns `errSecMissingEntitlement` (-34018) for this app configuration.
enum OTPCredentialStore {
    enum StoreError: LocalizedError {
        case missing
        case io(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return String(localized: "No saved password. Enter your app password and tap Save credentials.")
            case .io(let message):
                return message
            }
        }
    }

    private static let passwordService = "com.buddy.otp.imap"
    private static let accountsService = "com.buddy.otp.accounts"
    private static let accountsAccount = "roster"

    /// Older service IDs we may still need to read / delete.
    private static let legacyPasswordServices = [
        "com.buddy.otp.imap.dp",
        "com.buddy.otp.imap.v2",
        "com.buddy.otp.imap"
    ]
    private static let legacyAccountsServices = [
        "com.buddy.otp.accounts.dp",
        "com.buddy.otp.accounts"
    ]

    // MARK: - Account roster (Keychain)

    static func saveAccounts(_ accounts: [TrackedAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try saveData(data, account: accountsAccount, service: accountsService)
    }

    static func loadAccounts() throws -> [TrackedAccount] {
        if let data = try? loadData(account: accountsAccount, service: accountsService) {
            return try JSONDecoder().decode([TrackedAccount].self, from: data)
        }
        // Migrate roster from the old data-protection service name once.
        if let data = try? loadData(account: accountsAccount, service: "com.buddy.otp.accounts.dp") {
            let decoded = try JSONDecoder().decode([TrackedAccount].self, from: data)
            try saveAccounts(decoded)
            deleteItem(account: accountsAccount, service: "com.buddy.otp.accounts.dp")
            return decoded
        }
        throw StoreError.missing
    }

    static func deleteAccountsRoster() {
        for service in legacyAccountsServices {
            deleteItem(account: accountsAccount, service: service)
        }
    }

    // MARK: - App passwords (Keychain)

    static func save(password: String, account: String) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !account.isEmpty else { throw StoreError.missing }

        try saveData(Data(trimmed.utf8), account: account, service: passwordService)
        // Confirm round-trip without prompting the user.
        _ = try loadPasswordFromKeychain(account: account, service: passwordService)
        try? deleteFile(account: account)
        for service in legacyPasswordServices where service != passwordService {
            deleteItem(account: account, service: service)
        }
    }

    static func load(account: String) throws -> String {
        guard !account.isEmpty else { throw StoreError.missing }

        for service in [passwordService] + legacyPasswordServices {
            if let value = try? loadPasswordFromKeychain(account: account, service: service) {
                if service != passwordService {
                    try? save(password: value, account: account)
                }
                return value
            }
        }

        // One-shot migrate plain-file leftovers → Keychain, then delete the file.
        if let fromFile = try? loadFromFile(account: account) {
            try save(password: fromFile, account: account)
            return fromFile
        }

        throw StoreError.missing
    }

    static func delete(account: String) {
        try? deleteFile(account: account)
        for service in Set(legacyPasswordServices + [passwordService]) {
            deleteItem(account: account, service: service)
        }
    }

    static func purgeLegacyKeychainItems(account: String) {
        for service in legacyPasswordServices where service != passwordService {
            deleteItem(account: account, service: service)
        }
    }

    // MARK: - Keychain primitives

    private static func saveData(_ data: Data, account: String, service: String) throws {
        deleteItem(account: account, service: service)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrLabel as String: "OTP Buddy",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            // Avoid UI prompts when verifying the item we just wrote.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.io(
                String(localized: "Keychain save failed (\(status)). Try again after unlocking your Mac.")
            )
        }
    }

    private static func loadData(account: String, service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.missing
        }
        return data
    }

    private static func loadPasswordFromKeychain(account: String, service: String) throws -> String {
        let data = try loadData(account: account, service: service)
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw StoreError.missing
        }
        return value
    }

    private static func deleteItem(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Legacy file cleanup (read-once migration only)

    private static func loadFromFile(account: String) throws -> String {
        let url = try fileURL(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missing }
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw StoreError.missing
        }
        return value
    }

    private static func deleteFile(account: String) throws {
        let url = try fileURL(for: account)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func fileURL(for account: String) throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.io(String(localized: "Could not access Application Support."))
        }
        let folder = root.appendingPathComponent("OTPBuddy", isDirectory: true)
        let safe = account
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
        return folder.appendingPathComponent("imap-\(safe).credential")
    }

    static func legacyAccountsFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OTPBuddy", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    static func deleteLegacyAccountsFile() {
        guard let url = legacyAccountsFileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
