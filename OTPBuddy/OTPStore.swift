import Foundation
import AppKit
import BuddyCore
import BuddyFirebase
import Combine

struct IMAPAccount: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var useTLS: Bool

    static let empty = IMAPAccount(host: "", port: 993, username: "", useTLS: true)
}

@MainActor
final class OTPStore: ObservableObject {
    static let shared = OTPStore()

    @Published var account: IMAPAccount = .empty
    @Published var isConnected: Bool = false
    @Published var statusMessage: String = "Not connected"
    @Published var latestOTP: String?
    @Published var latestAnnouncement: String = ""
    @Published var autoCopy: Bool = UserDefaults.standard.bool(forKey: BuddySettingsKey.autoCopyOTP)

    private let cache = EphemeralOTPCache()
    private let keychainService = "com.buddy.otp.imap"
    private let accountKey = "otp.account"
    private var timer: Timer?
    private var client: IMAPClient?
    private var seenUIDs = Set<UInt32>()

    init() {
        loadAccount()
        autoCopy = UserDefaults.standard.bool(forKey: BuddySettingsKey.autoCopyOTP)
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    func saveCredentials(password: String) throws {
        try BuddyKeychain.set(password, account: account.username, service: keychainService)
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
        }
        UserDefaults.standard.set(autoCopy, forKey: BuddySettingsKey.autoCopyOTP)
        statusMessage = "Credentials saved"
    }

    func connect() async {
        do {
            let password = try BuddyKeychain.get(account: account.username, service: keychainService)
            let client = IMAPClient(account: account, password: password)
            try await client.connect()
            self.client = client
            isConnected = true
            statusMessage = "Connected to \(account.host)"
            await poll()
        } catch {
            isConnected = false
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func poll() async {
        guard let client else { return }
        do {
            let messages = try await client.fetchRecentBodies(limit: 5)
            for message in messages {
                if seenUIDs.contains(message.uid) { continue }
                seenUIDs.insert(message.uid)
                if let match = OTPDetector.extract(from: message.body) {
                    handleOTP(match.code)
                    break
                }
            }
        } catch {
            statusMessage = "Poll error: \(error.localizedDescription)"
        }
    }

    /// Inject a synthetic email body for tests / demo without IMAP.
    func ingestDemoEmail(_ body: String) {
        if let match = OTPDetector.extract(from: body) {
            handleOTP(match.code)
        } else {
            statusMessage = "No OTP found in demo email"
        }
    }

    func copyLatest() {
        guard let code = latestOTP ?? cache.current() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        latestAnnouncement = "OTP copied to clipboard"
    }

    private func handleOTP(_ code: String) {
        cache.store(code, ttl: 90)
        latestOTP = code
        BuddyFirebase.log(event: BuddyFirebase.Event.otpDetected)
        if autoCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code, forType: .string)
            latestAnnouncement = "New OTP is on your clipboard"
        } else {
            latestAnnouncement = "New OTP email received"
        }
        NotificationCenter.default.post(name: .otpReceived, object: nil)
        statusMessage = latestAnnouncement
    }

    private func loadAccount() {
        if let data = UserDefaults.standard.data(forKey: accountKey),
           let decoded = try? JSONDecoder().decode(IMAPAccount.self, from: data) {
            account = decoded
        }
    }
}
