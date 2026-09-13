import SwiftUI
import BuddyCore
import BuddyUI

struct OTPDashboardView: View {
    @EnvironmentObject private var store: OTPStore
    @State private var showingAddAccount = false
    @State private var editingAccount: TrackedAccount?
    @State private var accountPendingRemoval: TrackedAccount?

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                emptyState
            } else {
                populatedSplit
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            OTPAccountEditorSheet(mode: .add) { _ in
                showingAddAccount = false
            }
            .environmentObject(store)
        }
        .sheet(item: $editingAccount) { account in
            OTPAccountEditorSheet(mode: .edit(account)) { _ in
                editingAccount = nil
            }
            .environmentObject(store)
        }
        .confirmationDialog(
            String(localized: "Remove this account?"),
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            presenting: accountPendingRemoval
        ) { account in
            Button(String(localized: "Remove Account"), role: .destructive) {
                store.removeAccount(id: account.id)
                accountPendingRemoval = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: { account in
            Text("OTP Buddy will stop watching \(account.displayName) and remove its saved credentials.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(String(localized: "Watch your inbox for codes"))
                .font(.title2.weight(.semibold))

            Text(String(localized: "Connect an email account and OTP Buddy will catch one-time codes as they arrive — ready to copy in one click."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                showingAddAccount = true
            } label: {
                Label(String(localized: "Add Email Account"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("dashboard-add-account-empty")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                BuddySettingsGearButton()
            }
        }
    }

    private var populatedSplit: some View {
        NavigationSplitView {
            accountsColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } content: {
            otpsColumn
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            emailBodyColumn
        }
    }

    private var accountsColumn: some View {
        List(selection: Binding(
            get: { store.selectedAccountID },
            set: { store.selectAccount($0) }
        )) {
            ForEach(store.accounts) { account in
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.accountStatusColor(for: account.id))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .lineLimit(1)
                        Text(account.listSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(account.id)
                .contextMenu {
                    Button(String(localized: "Edit Account…")) {
                        editingAccount = account
                    }
                    if store.connectedAccountIDs.contains(account.id) {
                        Button(String(localized: "Disconnect")) {
                            store.disconnect(accountID: account.id)
                        }
                    } else {
                        Button(String(localized: "Connect")) {
                            Task { await store.connect(accountID: account.id) }
                        }
                    }
                    Divider()
                    Button(String(localized: "Remove Account"), role: .destructive) {
                        accountPendingRemoval = account
                    }
                }
            }
            .onMove(perform: store.moveAccounts)
        }
        .navigationTitle(String(localized: "Accounts"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddAccount = true
                } label: {
                    Label(String(localized: "Add Email Account"), systemImage: "plus")
                }
                .accessibilityIdentifier("dashboard-add-account")
            }
            ToolbarItem(placement: .automatic) {
                BuddySettingsGearButton()
            }
        }
    }

    private var otpsColumn: some View {
        Group {
            if store.mailItemsForSelectedAccount.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "No codes yet"))
                        .font(.headline)
                    Text(String(localized: "New verification emails for this account will show up here. Codes aren’t stored on disk — they clear when you quit OTP Buddy."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { store.selectedMailID },
                    set: { store.selectMail($0) }
                )) {
                    ForEach(store.mailItemsForSelectedAccount) { item in
                        OTPMailRow(item: item) {
                            store.copyCode(item.code)
                        }
                        .tag(item.id)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Codes"))
    }

    private var emailBodyColumn: some View {
        Group {
            if let mail = store.selectedMail {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mail.subject)
                                .font(.title3.weight(.semibold))
                            Text(mail.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.copyCode(mail.code)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Copy"))
                        .accessibilityLabel(String(localized: "Copy"))
                        .disabled(mail.isExpired)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    Text(mail.code)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .strikethrough(mail.isExpired)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    Divider()

                    if mail.isHTML {
                        OTPHTMLEmailView(html: mail.body)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(mail.body)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Select a code"))
                        .font(.headline)
                    Text(String(localized: "Choose a verification code to read the email."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(String(localized: "Email"))
    }
}

struct OTPMailRow: View {
    let item: OTPMailItem
    var shortcutHint: String? = nil
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Code + countdown can tick; received time stays outside TimelineView so it
                // paints on the first frame (avoids “code only, time later”).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = item.secondsRemaining(at: context.date)
                    let expired = item.expiresAt != nil && (item.isExpired || (remaining ?? 0) <= 0)
                    Text(item.code)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .strikethrough(expired)
                        .foregroundStyle(expired ? .secondary : .primary)
                }

                Text(item.receivedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.expiresAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = item.secondsRemaining(at: context.date)
                        let expired = item.isExpired || (remaining ?? 0) <= 0
                        Text(statusText(expired: expired, remaining: remaining))
                            .font(.caption2)
                            .foregroundStyle(expired ? .red.opacity(0.9) : .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let shortcutHint {
                Text(shortcutHint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(BuddyTheme.BuddyColor.textSecondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(item.isExpired)
            .help(shortcutHint.map { String(localized: "Copy (\($0))") } ?? String(localized: "Copy"))
            .accessibilityLabel(String(localized: "Copy"))
        }
        .padding(.vertical, 2)
    }

    private func statusText(expired: Bool, remaining: TimeInterval?) -> String {
        if expired { return String(localized: "Expired") }
        guard let remaining, remaining > 0 else { return String(localized: "Active") }
        let total = max(0, Int(remaining.rounded()))
        let formatted = String(format: "%d:%02d", total / 60, total % 60)
        return String(localized: "Active · \(formatted) left")
    }
}
