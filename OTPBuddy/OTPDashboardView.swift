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
                        .fill(store.connectedAccountIDs.contains(account.id) ? Color.green : Color.gray.opacity(0.45))
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
                    Text(String(localized: "New verification emails for this account will show up here."))
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mail.subject)
                                    .font(.title3.weight(.semibold))
                                Text(mail.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "Copy")) {
                                store.copyCode(mail.code)
                            }
                            .disabled(mail.isExpired)
                        }

                        Text(mail.code)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .strikethrough(mail.isExpired)

                        Divider()

                        Text(displayBody(mail.body))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
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

    private func displayBody(_ raw: String) -> String {
        // Prefer readable plain text; collapse huge HTML blobs to a short note.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("<!DOCTYPE") || trimmed.localizedCaseInsensitiveContains("<html") {
            if let plainStart = trimmed.range(of: "Your PIN code:")
                ?? trimmed.range(of: "verification code", options: .caseInsensitive) {
                return String(trimmed[plainStart.lowerBound...].prefix(1200))
            }
            return String(localized: "This message is HTML-only. The code is shown above.")
        }
        return trimmed
    }
}

struct OTPMailRow: View {
    let item: OTPMailItem
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = item.secondsRemaining(at: context.date)
            let hasLifetime = item.expiresAt != nil
            let expired = hasLifetime && (item.isExpired || (remaining ?? 0) <= 0)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.code)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .strikethrough(expired)
                        .foregroundStyle(expired ? .secondary : .primary)

                    Text(item.receivedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if hasLifetime {
                        Text(statusText(expired: expired, remaining: remaining))
                            .font(.caption2)
                            .foregroundStyle(expired ? .red.opacity(0.9) : .secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(String(localized: "Copy"), action: onCopy)
                    .controlSize(.small)
                    .disabled(expired)
            }
            .padding(.vertical, 2)
        }
    }

    private func statusText(expired: Bool, remaining: TimeInterval?) -> String {
        if expired { return String(localized: "Expired") }
        guard let remaining, remaining > 0 else { return String(localized: "Active") }
        let total = max(0, Int(remaining.rounded()))
        let formatted = String(format: "%d:%02d", total / 60, total % 60)
        return String(localized: "Active · \(formatted) left")
    }
}
