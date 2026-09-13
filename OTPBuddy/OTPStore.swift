import Foundation
import AppKit
import SwiftUI
import BuddyCore
import BuddyFirebase
import BuddyUI
import Combine

struct IMAPAccount: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var useTLS: Bool

    static let empty = IMAPAccount(host: "", port: 993, username: "", useTLS: true)
}

struct TrackedAccount: Identifiable, Codable, Equatable {
    var id: UUID
    /// Optional label shown in the account list. Empty → use the email address.
    var title: String
    var providerRaw: String
    var imap: IMAPAccount

    var provider: IMAPProvider {
        get { IMAPProvider(rawValue: providerRaw) ?? .other }
        set { providerRaw = newValue.rawValue }
    }

    var displayName: String {
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let user = imap.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? provider.title : user
    }

    /// Secondary line under the title: email when a custom title is set, otherwise the provider.
    var listSubtitle: String {
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = imap.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, !user.isEmpty { return user }
        return provider.title
    }

    init(id: UUID = UUID(), title: String = "", provider: IMAPProvider, imap: IMAPAccount) {
        self.id = id
        self.title = title
        self.providerRaw = provider.rawValue
        self.imap = imap
    }

    enum CodingKeys: String, CodingKey {
        case id, title, providerRaw, imap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        providerRaw = try container.decode(String.self, forKey: .providerRaw)
        imap = try container.decode(IMAPAccount.self, forKey: .imap)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(providerRaw, forKey: .providerRaw)
        try container.encode(imap, forKey: .imap)
    }
}

struct OTPMailItem: Identifiable, Codable, Equatable {
    let id: UUID
    let accountId: UUID
    let uid: UInt32
    let code: String
    let subject: String
    let body: String
    let isHTML: Bool
    let receivedAt: Date
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    func secondsRemaining(at date: Date = Date()) -> TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSince(date)
    }

    enum CodingKeys: String, CodingKey {
        case id, accountId, uid, code, subject, body, isHTML, receivedAt, expiresAt
    }

    init(
        id: UUID = UUID(),
        accountId: UUID,
        uid: UInt32,
        code: String,
        subject: String,
        body: String,
        isHTML: Bool = false,
        receivedAt: Date,
        expiresAt: Date?
    ) {
        self.id = id
        self.accountId = accountId
        self.uid = uid
        self.code = code
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountId = try container.decode(UUID.self, forKey: .accountId)
        uid = try container.decode(UInt32.self, forKey: .uid)
        code = try container.decode(String.self, forKey: .code)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        isHTML = try container.decodeIfPresent(Bool.self, forKey: .isHTML) ?? false
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

enum IMAPProvider: String, CaseIterable, Identifiable, Equatable {
    case gmail
    case outlook
    case microsoft365
    case yahoo
    case icloud
    case aol
    case zoho
    case fastmail
    case gmx
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: return String(localized: "Gmail")
        case .outlook: return String(localized: "Outlook / Hotmail")
        case .microsoft365: return String(localized: "Microsoft 365")
        case .yahoo: return String(localized: "Yahoo")
        case .icloud: return String(localized: "iCloud")
        case .aol: return String(localized: "AOL")
        case .zoho: return String(localized: "Zoho Mail")
        case .fastmail: return String(localized: "Fastmail")
        case .gmx: return String(localized: "GMX")
        case .other: return String(localized: "Other")
        }
    }

    var defaultHost: String? {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .outlook: return "imap-mail.outlook.com"
        case .microsoft365: return "outlook.office365.com"
        case .yahoo: return "imap.mail.yahoo.com"
        case .icloud: return "imap.mail.me.com"
        case .aol: return "imap.aol.com"
        case .zoho: return "imap.zoho.com"
        case .fastmail: return "imap.fastmail.com"
        case .gmx: return "imap.gmx.com"
        case .other: return nil
        }
    }

    var helpURL: URL? {
        switch self {
        case .gmail:
            return URL(string: "https://myaccount.google.com/apppasswords")
        case .outlook, .microsoft365:
            return URL(string: "https://account.microsoft.com/security")
        case .yahoo:
            return URL(string: "https://login.yahoo.com/account/security")
        case .icloud:
            return URL(string: "https://account.apple.com/account/manage/section/security")
        case .aol:
            return URL(string: "https://login.aol.com/account/security")
        case .zoho:
            return URL(string: "https://accounts.zoho.com/home#security/security_pwd")
        case .fastmail:
            return URL(string: "https://www.fastmail.com/help/clients/apppassword.html")
        case .gmx:
            return URL(string: "https://www.gmx.com/")
        case .other:
            return nil
        }
    }

    var helpLinkTitle: String {
        switch self {
        case .gmail: return String(localized: "Open Google App Passwords")
        case .outlook, .microsoft365: return String(localized: "Open Microsoft Account Security")
        case .yahoo: return String(localized: "Open Yahoo Account Security")
        case .icloud: return String(localized: "Open Apple Account Security")
        case .aol: return String(localized: "Open AOL Account Security")
        case .zoho: return String(localized: "Open Zoho Security")
        case .fastmail: return String(localized: "Open Fastmail App Passwords help")
        case .gmx: return String(localized: "Open GMX")
        case .other: return ""
        }
    }

    var appPasswordTutorial: String {
        switch self {
        case .gmail:
            return String(localized: """
            Gmail does not accept your normal password here.

            1. Turn on 2-Step Verification in your Google Account.
            2. Open App Passwords and create one (e.g. “OTP Buddy”).
            3. Paste the 16-character code into App password below — spaces are fine.
            """)
        case .outlook, .microsoft365:
            return String(localized: """
            Outlook / Hotmail / Microsoft 365 need an app password when 2-Step Verification is on.

            1. Open Microsoft Account Security and turn on 2-Step Verification.
            2. Create an app password for Mail.
            3. Use your full email as username and paste the app password below.
            """)
        case .yahoo:
            return String(localized: """
            Yahoo needs an app password, not your regular login.

            1. Open Yahoo Account Security.
            2. Generate an app password for Mail.
            3. Paste that password below.
            """)
        case .icloud:
            return String(localized: """
            iCloud Mail needs an app-specific password.

            1. Sign in at account.apple.com.
            2. Sign-In and Security → App-Specific Passwords → Generate.
            3. Paste that password below (use your Apple ID email as username).
            """)
        case .aol:
            return String(localized: """
            AOL needs an app password for IMAP.

            1. Open AOL Account Security and enable verification if asked.
            2. Generate an app password for Mail.
            3. Paste it below with your full AOL address as username.
            """)
        case .zoho:
            return String(localized: """
            Zoho Mail needs an application-specific password for IMAP.

            1. Open Zoho Account Security.
            2. Create an application-specific password.
            3. Paste it below.
            """)
        case .fastmail:
            return String(localized: """
            Fastmail needs an app password for third-party IMAP apps.

            1. Open Fastmail settings → Password & Security.
            2. Create a new app password.
            3. Paste it below.
            """)
        case .gmx:
            return String(localized: """
            Enable IMAP in GMX settings, then use your GMX email and password (or app password if offered).

            Host is usually imap.gmx.com on port 993 with TLS.
            """)
        case .other:
            return String(localized: """
            Most providers need an app-specific password for IMAP (not your normal login).

            Check your provider’s security settings for “App password” or “App-specific password”, then paste it below. Host is usually something like imap.example.com; port 993 with TLS is typical.
            """)
        }
    }

    static func matching(host: String) -> IMAPProvider {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .gmail }
        return allCases.first { $0.defaultHost?.lowercased() == normalized } ?? .other
    }

    func apply(to account: inout IMAPAccount) {
        if let defaultHost {
            account.host = defaultHost
        } else if Self.matching(host: account.host) != .other {
            account.host = ""
        }
        account.port = 993
        account.useTLS = true
    }
}

@MainActor
final class OTPStore: ObservableObject {
    static let shared = OTPStore()
    static let maxRecentOTPs = 50
    static let notifyIfReceivedWithin: TimeInterval = 5 * 60

    @Published var accounts: [TrackedAccount] = []
    @Published var mailItems: [OTPMailItem] = []
    @Published var selectedAccountID: UUID?
    @Published var selectedMailID: UUID?
    @Published var connectedAccountIDs: Set<UUID> = []
    /// Accounts that failed the last connect/poll attempt (shown as red on the account list).
    @Published var failedAccountIDs: Set<UUID> = []
    @Published var statusMessage: String = String(localized: "Not connected")
    @Published var latestOTP: String?
    @Published var latestAnnouncement: String = ""
    @Published var autoCopy: Bool = UserDefaults.standard.bool(forKey: BuddySettingsKey.autoCopyOTP)
    @Published var autoReconnectOnLaunch: Bool = {
        if UserDefaults.standard.object(forKey: BuddySettingsKey.otpAutoReconnectOnLaunch) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: BuddySettingsKey.otpAutoReconnectOnLaunch)
    }()

    var isConnected: Bool { !connectedAccountIDs.isEmpty }

    /// Sidebar / pin status dot: green connected, red failed/error, gray idle.
    func accountStatusColor(for accountID: UUID) -> Color {
        if connectedAccountIDs.contains(accountID) { return .green }
        if failedAccountIDs.contains(accountID) { return Color.red.opacity(0.85) }
        return Color.gray.opacity(0.45)
    }

    var selectedAccount: TrackedAccount? {
        guard let selectedAccountID else { return accounts.first }
        return accounts.first { $0.id == selectedAccountID }
    }

    var selectedMail: OTPMailItem? {
        guard let selectedMailID else { return mailItemsForSelectedAccount.first }
        return mailItems.first { $0.id == selectedMailID }
    }

    var mailItemsForSelectedAccount: [OTPMailItem] {
        guard let selectedAccountID else { return mailItems }
        return mailItems.filter { $0.accountId == selectedAccountID }
    }

    private let cache = EphemeralOTPCache()
    private let accountsKey = "otp.accounts"
    private let legacyAccountKey = "otp.account"
    private let mailItemsKey = "otp.mailItems"
    private let seenUIDsKey = "otp.seenUIDs"
    private let selectedAccountKey = "otp.selectedAccountID"
    private var timer: Timer?
    private var clients: [UUID: IMAPClient] = [:]
    private var seenUIDs: [UUID: Set<UInt32>] = [:]
    private var cachedPasswords: [UUID: String] = [:]
    private var idleTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingAccountIDs: Set<UUID> = []
    /// How long to stay in IMAP IDLE before refreshing (under Gmail’s ~29m limit).
    private static let idleTimeout: TimeInterval = 15 * 60
    /// Poll interval when the server does not support IDLE.
    private static let pollOnlyInterval: TimeInterval = 2
    private static let fetchLimit = 8

    init() {
        loadAccounts()
        purgePlaceholderAccountsIfNeeded()
        clearPersistedMailHistory()
        loadSeenUIDs()
        autoCopy = UserDefaults.standard.bool(forKey: BuddySettingsKey.autoCopyOTP)
        if selectedAccountID == nil {
            selectedAccountID = accounts.first?.id
        }
    }

    func reconnectIfPossible() async {
        guard autoReconnectOnLaunch else { return }
        _ = await connectAll(notifyOnPartialFailure: false)
    }

    /// Connect every tracked account. Returns the accounts that failed.
    @discardableResult
    func connectAll(notifyOnPartialFailure: Bool = true) async -> [TrackedAccount] {
        guard !accounts.isEmpty else {
            statusMessage = String(localized: "Add an email account first")
            return []
        }
        var failures: [TrackedAccount] = []
        for account in accounts {
            await connect(accountID: account.id)
            if !connectedAccountIDs.contains(account.id) {
                failures.append(account)
            }
        }
        if failures.isEmpty {
            statusMessage = String(localized: "Connected all accounts")
        } else if failures.count == accounts.count {
            statusMessage = String(localized: "Could not connect any account")
        } else {
            statusMessage = String(localized: "Connected with \(failures.count) failure(s)")
        }
        if notifyOnPartialFailure, !failures.isEmpty {
            OTPNotifier.notifyConnectionFailures(accounts: failures, statusMessage: statusMessage)
        }
        postConnectionChange()
        return failures
    }

    func disconnectAll() {
        for id in Array(connectedAccountIDs) {
            disconnect(accountID: id)
        }
        statusMessage = String(localized: "Disconnected")
        postConnectionChange()
    }

    /// True when every tracked account is currently connected (and at least one exists).
    var areAllAccountsConnected: Bool {
        !accounts.isEmpty && accounts.allSatisfy { connectedAccountIDs.contains($0.id) }
    }

    func start() {
        timer?.invalidate()
        timer = nil
        for id in connectedAccountIDs {
            startWatching(accountID: id)
        }
        Task { await pollAll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for id in Array(idleTasks.keys) {
            stopWatching(accountID: id)
        }
        // Unblock any in-flight IDLE so pause/disconnect takes effect immediately.
        for client in clients.values {
            Task { await client.interrupt() }
        }
    }

    private func startWatching(accountID: UUID) {
        stopWatching(accountID: accountID)
        idleTasks[accountID] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.connectedAccountIDs.contains(accountID) {
                if BuddyPauseController.shared.isPaused { break }
                guard let client = self.clients[accountID] else { break }

                var usedIdle = false
                if await client.prefersIdle() {
                    do {
                        // Near-push: server wakes us on new mail instead of waiting for a timer.
                        let changed = try await client.idleForChanges(timeout: Self.idleTimeout)
                        if changed {
                            print("[OTP] IDLE wake — mailbox changed, polling…")
                        }
                        usedIdle = true
                    } catch {
                        self.failedAccountIDs.insert(accountID)
                        self.statusMessage = String(localized: "Poll error: \(error.localizedDescription)")
                        print("[OTP] IDLE/session error: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }

                await self.poll(accountID: accountID)

                if Task.isCancelled { break }
                let prefersIdle = await client.prefersIdle()
                if !usedIdle || !prefersIdle {
                    try? await Task.sleep(nanoseconds: UInt64(Self.pollOnlyInterval * 1_000_000_000))
                }
            }
        }
    }

    private func stopWatching(accountID: UUID) {
        idleTasks[accountID]?.cancel()
        idleTasks[accountID] = nil
    }

    func persistPreferences() {
        UserDefaults.standard.set(autoCopy, forKey: BuddySettingsKey.autoCopyOTP)
        UserDefaults.standard.set(autoReconnectOnLaunch, forKey: BuddySettingsKey.otpAutoReconnectOnLaunch)
    }

    @discardableResult
    func saveAccount(
        _ draft: TrackedAccount,
        password: String,
        connectAfterSave: Bool = true
    ) async throws -> UUID {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.imap.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = String(localized: "Enter your email address first")
            throw OTPCredentialStore.StoreError.missing
        }
        guard !draft.imap.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = String(localized: "Enter an IMAP host")
            throw OTPCredentialStore.StoreError.missing
        }

        if trimmed.isEmpty {
            // Keep existing password when editing.
            _ = try loadPassword(for: draft)
        } else {
            try OTPCredentialStore.save(password: trimmed, account: credentialKey(for: draft))
            cachedPasswords[draft.id] = trimmed
        }

        if let index = accounts.firstIndex(where: { $0.id == draft.id }) {
            accounts[index] = draft
        } else {
            accounts.append(draft)
        }
        selectedAccountID = draft.id
        try persistAccounts()
        statusMessage = String(localized: "Credentials saved to Keychain")

        if connectAfterSave {
            await connect(accountID: draft.id)
        }
        return draft.id
    }

    func removeAccount(id: UUID) {
        disconnect(accountID: id)
        if let account = accounts.first(where: { $0.id == id }) {
            OTPCredentialStore.delete(account: credentialKey(for: account))
        }
        accounts.removeAll { $0.id == id }
        mailItems.removeAll { $0.accountId == id }
        seenUIDs[id] = nil
        cachedPasswords[id] = nil
        if selectedAccountID == id {
            selectedAccountID = accounts.first?.id
            selectedMailID = mailItemsForSelectedAccount.first?.id
        }
        persistAccountsIgnoringErrors()
        persistSeenUIDs()
        postConnectionChange()
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persistAccountsIgnoringErrors()
    }

    func connect(accountID: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        do {
            let password = try loadPassword(for: account)
            let client = IMAPClient(account: account.imap, password: password)
            try await client.connect()
            clients[accountID] = client
            connectedAccountIDs.insert(accountID)
            failedAccountIDs.remove(accountID)
            statusMessage = String(localized: "Connected to \(account.imap.host)")
            await poll(accountID: accountID)
            if !BuddyPauseController.shared.isPaused {
                start()
            }
            postConnectionChange()
        } catch let error as OTPCredentialStore.StoreError {
            connectedAccountIDs.remove(accountID)
            failedAccountIDs.insert(accountID)
            clients[accountID] = nil
            stopWatching(accountID: accountID)
            statusMessage = error.localizedDescription
            postConnectionChange()
        } catch {
            connectedAccountIDs.remove(accountID)
            failedAccountIDs.insert(accountID)
            clients[accountID] = nil
            stopWatching(accountID: accountID)
            statusMessage = String(localized: "Connection failed: \(error.localizedDescription)")
            postConnectionChange()
        }
    }

    func disconnect(accountID: UUID) {
        stopWatching(accountID: accountID)
        if let client = clients[accountID] {
            Task { await client.disconnect() }
        }
        clients[accountID] = nil
        connectedAccountIDs.remove(accountID)
        failedAccountIDs.remove(accountID)
        if connectedAccountIDs.isEmpty {
            stop()
            statusMessage = String(localized: "Disconnected")
        }
        postConnectionChange()
    }

    func pollAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in connectedAccountIDs {
                group.addTask { @MainActor in
                    await self.poll(accountID: id)
                }
            }
        }
    }

    func poll(accountID: UUID) async {
        guard connectedAccountIDs.contains(accountID), let client = clients[accountID] else { return }
        guard pollingAccountIDs.insert(accountID).inserted else { return }
        defer { pollingAccountIDs.remove(accountID) }

        do {
            var seen = seenUIDs[accountID] ?? []
            let afterUID = seen.max() ?? 0
            let messages = try await client.fetchRecentBodies(
                limit: Self.fetchLimit,
                excludingUIDs: seen,
                afterUID: afterUID
            )
            let cutoff = Date().addingTimeInterval(-Self.notifyIfReceivedWithin)
            for message in messages {
                if seen.contains(message.uid) { continue }
                seen.insert(message.uid)
                let detectStarted = Date()
                let match = OTPDetector.extract(from: message.scanText)
                let detectMs = Date().timeIntervalSince(detectStarted) * 1000
                guard let receivedAt = message.receivedAt, receivedAt >= cutoff else {
                    print(String(
                        format: "[OTP] skip uid=%u (too old or no date) detect=%.1fms",
                        message.uid,
                        detectMs
                    ))
                    continue
                }
                guard let match, match.confidence >= 0.75 else {
                    print(String(
                        format: "[OTP] skip uid=%u subject=\"%@\" no OTP (conf=%.2f) detect=%.1fms scanChars=%d",
                        message.uid,
                        String(message.subject.prefix(60)),
                        match?.confidence ?? 0,
                        detectMs,
                        message.scanText.count
                    ))
                    continue
                }
                print(String(
                    format: "[OTP] NEW email uid=%u code=%@ subject=\"%@\" detect=%.1fms scanChars=%d receivedAt=%@",
                    message.uid,
                    match.code,
                    String(message.subject.prefix(60)),
                    detectMs,
                    message.scanText.count,
                    receivedAt.description
                ))
                handleOTP(match, message: message, accountID: accountID, receivedAt: receivedAt)
            }
            seenUIDs[accountID] = seen
            persistSeenUIDs()
            failedAccountIDs.remove(accountID)
        } catch {
            failedAccountIDs.insert(accountID)
            statusMessage = String(localized: "Poll error: \(error.localizedDescription)")
        }
    }

    func ingestDemoEmail(_ body: String, accountID: UUID? = nil) {
        let targetID = accountID ?? selectedAccountID ?? accounts.first?.id
        guard let targetID else {
            statusMessage = String(localized: "Add an email account first")
            return
        }
        if let match = OTPDetector.extract(from: body) {
            let message = IMAPClient.Message(
                uid: UInt32.random(in: 1...UInt32.max),
                subject: String(localized: "Demo verification email"),
                body: body,
                isHTML: false,
                scanText: body,
                receivedAt: Date()
            )
            handleOTP(match, message: message, accountID: targetID, receivedAt: Date())
        } else {
            statusMessage = String(localized: "No OTP found in demo email")
        }
    }

    /// Seed demo accounts + OTP mail for App Store screenshot capture (no live IMAP).
    func installMarketingSeed() {
        stop()
        clients.removeAll()
        idleTasks.values.forEach { $0.cancel() }
        idleTasks.removeAll()
        pollingAccountIDs.removeAll()

        let workID = UUID()
        let personalID = UUID()
        let work = TrackedAccount(
            id: workID,
            title: "Work",
            provider: .gmail,
            imap: IMAPAccount(host: "imap.gmail.com", port: 993, username: "alex@company.com", useTLS: true)
        )
        let personal = TrackedAccount(
            id: personalID,
            title: "",
            provider: .icloud,
            imap: IMAPAccount(host: "imap.mail.me.com", port: 993, username: "alex@icloud.com", useTLS: true)
        )
        accounts = [work, personal]
        selectedAccountID = workID
        connectedAccountIDs = [workID, personalID]
        failedAccountIDs = []
        cachedPasswords[workID] = "marketing-demo"
        cachedPasswords[personalID] = "marketing-demo"

        let now = Date()
        let workBody = """
        From: security@company.com
        Subject: Your verification code

        Use verification code 482913 to sign in. This one-time passcode expires in 10 minutes.
        """
        let bankBody = """
        From: alerts@bank.example
        Subject: Confirm your transfer

        Your confirmation code is 719204. It expires in 5 minutes.
        """
        let personalBody = """
        From: no-reply@appleid.apple.com
        Subject: Your Apple Account code

        Your Apple Account code is 305871. Do not share it.
        """
        mailItems = [
            OTPMailItem(
                accountId: workID,
                uid: 1001,
                code: "482913",
                subject: "Your verification code",
                body: workBody,
                isHTML: false,
                receivedAt: now.addingTimeInterval(-90),
                expiresAt: now.addingTimeInterval(9 * 60)
            ),
            OTPMailItem(
                accountId: workID,
                uid: 1002,
                code: "719204",
                subject: "Confirm your transfer",
                body: bankBody,
                isHTML: false,
                receivedAt: now.addingTimeInterval(-8 * 60),
                expiresAt: now.addingTimeInterval(4 * 60)
            ),
            OTPMailItem(
                accountId: personalID,
                uid: 2001,
                code: "305871",
                subject: "Your Apple Account code",
                body: personalBody,
                isHTML: false,
                receivedAt: now.addingTimeInterval(-20 * 60),
                expiresAt: now.addingTimeInterval(40 * 60)
            )
        ]
        selectedMailID = mailItems.first?.id
        latestOTP = mailItems.first?.code
        latestAnnouncement = String(localized: "New OTP email received")
        statusMessage = String(localized: "Connected to \(work.imap.host)")
        autoCopy = false
        objectWillChange.send()
        postConnectionChange()
    }

    func prepareMarketingEmptyState() {
        stop()
        clients.removeAll()
        idleTasks.values.forEach { $0.cancel() }
        idleTasks.removeAll()
        accounts = []
        mailItems = []
        selectedAccountID = nil
        selectedMailID = nil
        connectedAccountIDs = []
        failedAccountIDs = []
        latestOTP = nil
        latestAnnouncement = ""
        statusMessage = String(localized: "Not connected")
        autoCopy = false
        objectWillChange.send()
        postConnectionChange()
    }

    func copyLatest() {
        guard let code = latestOTP ?? mailItems.first?.code ?? cache.current() else { return }
        copyCode(code)
    }

    func copyCode(_ code: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        latestAnnouncement = String(localized: "OTP copied to clipboard")
        statusMessage = latestAnnouncement
    }

    func selectAccount(_ id: UUID?) {
        selectedAccountID = id
        selectedMailID = mailItemsForSelectedAccount.first?.id
    }

    func selectMail(_ id: UUID?) {
        selectedMailID = id
    }

    // MARK: - Private

    private func handleOTP(
        _ match: OTPMatch,
        message: IMAPClient.Message,
        accountID: UUID,
        receivedAt: Date
    ) {
        let expiresAt: Date? = {
            guard let seconds = match.validitySeconds, seconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(seconds)
        }()

        let item = OTPMailItem(
            id: UUID(),
            accountId: accountID,
            uid: message.uid,
            code: match.code,
            subject: message.subject.isEmpty ? String(localized: "OTP email") : message.subject,
            body: message.body.isEmpty ? message.scanText : message.body,
            isHTML: message.isHTML,
            receivedAt: receivedAt,
            expiresAt: expiresAt
        )

        mailItems = Array(
            ([item] + mailItems.filter { !($0.accountId == accountID && $0.uid == message.uid) })
                .prefix(Self.maxRecentOTPs)
        )
        // Prefer the new code when the user opens the window themselves.
        selectedAccountID = accountID
        selectedMailID = item.id

        let ttl = expiresAt?.timeIntervalSinceNow ?? 90
        cache.store(match.code, ttl: max(ttl, 30))
        latestOTP = match.code
        BuddyFirebase.log(event: BuddyFirebase.Event.otpDetected)
        if autoCopy {
            copyCode(match.code)
            latestAnnouncement = String(localized: "New OTP is on your clipboard")
        } else {
            latestAnnouncement = String(localized: "New OTP email received")
        }
        OTPNotifier.notifyOTP(code: match.code, autoCopied: autoCopy)
        NotificationCenter.default.post(name: .otpReceived, object: nil)
        statusMessage = latestAnnouncement
    }

    private func credentialKey(for account: TrackedAccount) -> String {
        "\(account.id.uuidString).\(account.imap.username)"
    }

    private func loadPassword(for account: TrackedAccount) throws -> String {
        if let cached = cachedPasswords[account.id], !cached.isEmpty {
            return cached
        }
        let password = try OTPCredentialStore.load(account: credentialKey(for: account))
        cachedPasswords[account.id] = password
        return password
    }

    private func persistAccounts() throws {
        guard !isRunningUnderTests else { return }

        try OTPCredentialStore.saveAccounts(accounts)

        if let selectedAccountID {
            UserDefaults.standard.set(selectedAccountID.uuidString, forKey: selectedAccountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedAccountKey)
        }

        // Purge insecure legacy copies after a successful Keychain write.
        UserDefaults.standard.removeObject(forKey: accountsKey)
        UserDefaults.standard.removeObject(forKey: legacyAccountKey)
        OTPCredentialStore.deleteLegacyAccountsFile()
    }

    private func persistAccountsIgnoringErrors() {
        do {
            try persistAccounts()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadAccounts() {
        // 1) Keychain (canonical).
        if let decoded = try? OTPCredentialStore.loadAccounts() {
            accounts = decoded
            restoreSelectedAccountID()
            return
        }

        // 2) Migrate legacy Application Support / UserDefaults → Keychain once.
        var migrated: [TrackedAccount] = []

        if let url = OTPCredentialStore.legacyAccountsFileURL(),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([TrackedAccount].self, from: data) {
            migrated = decoded
        } else if let data = UserDefaults.standard.data(forKey: accountsKey),
                  let decoded = try? JSONDecoder().decode([TrackedAccount].self, from: data) {
            migrated = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyAccountKey),
                  let legacy = try? JSONDecoder().decode(IMAPAccount.self, from: data),
                  !legacy.username.isEmpty {
            let provider = IMAPProvider.matching(host: legacy.host)
            let tracked = TrackedAccount(provider: provider, imap: legacy)
            migrated = [tracked]
            if let password = try? OTPCredentialStore.load(account: legacy.username) {
                try? OTPCredentialStore.save(password: password, account: credentialKey(for: tracked))
                cachedPasswords[tracked.id] = password
            }
        }

        accounts = migrated
        restoreSelectedAccountID()

        let hadLegacyFile = OTPCredentialStore.legacyAccountsFileURL()
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hadLegacyDefaults = UserDefaults.standard.data(forKey: accountsKey) != nil
            || UserDefaults.standard.data(forKey: legacyAccountKey) != nil

        if !migrated.isEmpty || hadLegacyFile || hadLegacyDefaults {
            persistAccountsIgnoringErrors()
        }
    }

    private func restoreSelectedAccountID() {
        if let raw = UserDefaults.standard.string(forKey: selectedAccountKey),
           let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            selectedAccountID = id
        } else {
            selectedAccountID = accounts.first?.id
        }
    }

    /// Unit-test fixtures accidentally persisted into Keychain before tests were isolated.
    private func purgePlaceholderAccountsIfNeeded() {
        let placeholders: Set<String> = [
            "work@example.com",
            "demo@example.com",
            "personal@outlook.com"
        ]
        let before = accounts
        let kept = accounts.filter { account in
            let user = account.imap.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if placeholders.contains(user) { return false }
            if user.hasSuffix("@example.com") { return false }
            return true
        }
        guard kept.count != before.count else { return }
        for removed in before where !kept.contains(where: { $0.id == removed.id }) {
            OTPCredentialStore.delete(account: credentialKey(for: removed))
            mailItems.removeAll { $0.accountId == removed.id }
            seenUIDs[removed.id] = nil
            cachedPasswords[removed.id] = nil
            connectedAccountIDs.remove(removed.id)
            clients[removed.id] = nil
        }
        accounts = kept
        if let selectedAccountID, !accounts.contains(where: { $0.id == selectedAccountID }) {
            self.selectedAccountID = accounts.first?.id
        }
        persistAccountsIgnoringErrors()
        persistSeenUIDs()
    }

    /// Avoid clobbering the developer's real Keychain when unit tests construct OTPStore.
    private var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Codes/email bodies stay in memory for this session only — never written to disk.
    private func clearPersistedMailHistory() {
        UserDefaults.standard.removeObject(forKey: mailItemsKey)
        mailItems = []
        latestOTP = nil
        selectedMailID = nil
    }

    private func persistSeenUIDs() {
        let payload = seenUIDs.reduce(into: [String: [UInt32]]()) { result, entry in
            result[entry.key.uuidString] = Array(entry.value).sorted()
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: seenUIDsKey)
        }
    }

    private func loadSeenUIDs() {
        guard let data = UserDefaults.standard.data(forKey: seenUIDsKey),
              let decoded = try? JSONDecoder().decode([String: [UInt32]].self, from: data) else { return }
        var restored: [UUID: Set<UInt32>] = [:]
        for (key, values) in decoded {
            guard let id = UUID(uuidString: key) else { continue }
            restored[id] = Set(values)
        }
        seenUIDs = restored
    }

    private func postConnectionChange() {
        NotificationCenter.default.post(name: .otpConnectionDidChange, object: nil)
    }
}

extension Notification.Name {
    static let otpConnectionDidChange = Notification.Name("buddy.otp.connectionDidChange")
}
