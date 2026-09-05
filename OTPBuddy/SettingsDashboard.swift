import SwiftUI
import BuddyCore

struct SettingsDashboard: View {
    @EnvironmentObject private var store: OTPStore
    @State private var password = ""

    var body: some View {
        Form {
            Section("IMAP account") {
                TextField("Host (e.g. imap.gmail.com)", text: $store.account.host)
                TextField("Port", value: $store.account.port, format: .number)
                TextField("Username / email", text: $store.account.username)
                SecureField("App password", text: $password)
                Toggle("Use TLS", isOn: $store.account.useTLS)
            }
            Section("Behavior") {
                Toggle("Automatically copy OTP to clipboard", isOn: $store.autoCopy)
                    .accessibilityIdentifier("auto-copy-toggle")
            }
            Section("Status") {
                Text(store.statusMessage)
                    .accessibilityIdentifier("status-message")
                if let otp = store.latestOTP {
                    Text("Latest code: \(otp)")
                        .accessibilityIdentifier("latest-otp")
                }
            }
            Section {
                Button("Save credentials") {
                    try? store.saveCredentials(password: password)
                }
                Button("Connect") {
                    Task { await store.connect() }
                }
                .accessibilityIdentifier("connect-button")
                Button("Demo: ingest sample OTP email") {
                    store.ingestDemoEmail("""
                    Subject: Your verification code
                    Use verification code 847291 to continue.
                    """)
                }
                .accessibilityIdentifier("demo-otp")
            }
        }
        .formStyle(.grouped)
        .padding()
        .accessibilityIdentifier("otp-settings")
    }
}

struct OTPPopoverView: View {
    @EnvironmentObject private var store: OTPStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.latestAnnouncement.isEmpty ? "Waiting for OTP emails…" : store.latestAnnouncement)
                .font(.headline)
                .accessibilityIdentifier("otp-announcement")
            if store.latestOTP != nil && !store.autoCopy {
                Button("Copy to Clipboard") {
                    store.copyLatest()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("copy-otp")
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
