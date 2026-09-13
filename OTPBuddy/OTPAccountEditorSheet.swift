import SwiftUI
import BuddyCore
import BuddyUI

enum OTPAccountEditorMode {
    case add
    case edit(TrackedAccount)

    var title: String {
        switch self {
        case .add: return String(localized: "Add Email Account")
        case .edit: return String(localized: "Edit Email Account")
        }
    }
}

struct OTPAccountEditorSheet: View {
    @EnvironmentObject private var store: OTPStore
    @Environment(\.dismiss) private var dismiss

    let mode: OTPAccountEditorMode
    var onFinished: (UUID) -> Void

    @State private var provider: IMAPProvider = .gmail
    @State private var accountTitle = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = 993
    @State private var useTLS = true
    @State private var showAdvanced = false
    @State private var showHelp = true
    @State private var status = ""
    @State private var isSaving = false
    @State private var accountID = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Email account")) {
                    TextField(String(localized: "Title"), text: $accountTitle)
                    Text(String(localized: "Optional — leave blank to use your email as the title."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(String(localized: "Provider"), selection: $provider) {
                        ForEach(IMAPProvider.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .onChange(of: provider) { newValue in
                        var imap = IMAPAccount(host: host, port: port, username: username, useTLS: useTLS)
                        newValue.apply(to: &imap)
                        host = imap.host
                        port = imap.port
                        useTLS = imap.useTLS
                        if newValue == .other {
                            showAdvanced = true
                        }
                    }

                    TextField(String(localized: "Username / email"), text: $username)
                    SecureField(String(localized: "App password"), text: $password)
                    if case .edit = mode {
                        Text(String(localized: "Leave blank to keep the saved app password."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if provider == .other {
                        TextField(String(localized: "IMAP host"), text: $host)
                    }
                }

                Section {
                    DisclosureGroup(String(localized: "How to create an app password"), isExpanded: $showHelp) {
                        Text(provider.appPasswordTutorial)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        if let url = provider.helpURL {
                            Link(provider.helpLinkTitle, destination: url)
                                .padding(.top, 6)
                        }
                    }
                }

                Section {
                    DisclosureGroup(String(localized: "Advanced"), isExpanded: $showAdvanced) {
                        if provider != .other {
                            TextField(String(localized: "IMAP host"), text: $host)
                        }
                        TextField(String(localized: "Port"), value: $port, format: .number)
                        Toggle(String(localized: "Use TLS"), isOn: $useTLS)
                    }
                }

                if !status.isEmpty {
                    Section {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(String(localized: "Save & Connect")) {
                            Task { await save() }
                        }
                    }
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.08)
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(String(localized: "Saving & connecting…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .ignoresSafeArea()
                }
            }
            .interactiveDismissDisabled(isSaving)
            .frame(minWidth: 480, minHeight: 420)
            .onAppear(perform: hydrate)
        }
    }

    private func hydrate() {
        switch mode {
        case .add:
            accountID = UUID()
            accountTitle = ""
            provider = .gmail
            var imap = IMAPAccount.empty
            provider.apply(to: &imap)
            host = imap.host
            port = imap.port
            useTLS = imap.useTLS
        case .edit(let account):
            accountID = account.id
            accountTitle = account.title
            provider = account.provider
            username = account.imap.username
            host = account.imap.host
            port = account.imap.port
            useTLS = account.imap.useTLS
            showAdvanced = provider == .other
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if provider != .other, let defaultHost = provider.defaultHost {
            host = defaultHost
        }
        let tracked = TrackedAccount(
            id: accountID,
            title: accountTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            imap: IMAPAccount(host: host, port: port, username: username, useTLS: useTLS)
        )
        do {
            let id = try await store.saveAccount(tracked, password: password, connectAfterSave: true)
            status = store.statusMessage
            onFinished(id)
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}
