import SwiftUI
import BuddyCore
import BuddyUI

struct OTPSettingsView: View {
    @EnvironmentObject private var store: OTPStore

    private let brand = BuddyBrand.otpBuddy
    private let items: [BuddySettingsItem] = [
        .appearance,
        .preferences,
        .privacy
    ]

    var body: some View {
        BuddySettingsSidebarView(
            brand: brand,
            items: items,
            usesSettingsWindowSize: true,
            initialSelection: .preferences
        ) { item in
            switch item.id {
            case BuddySettingsItem.appearance.id:
                BuddyAppearanceSettingsSection(brand: brand)
            case BuddySettingsItem.preferences.id:
                Section(String(localized: "Behavior")) {
                    Toggle(String(localized: "Automatically copy OTP to clipboard"), isOn: $store.autoCopy)
                        .onChange(of: store.autoCopy) { _ in store.persistPreferences() }
                        .accessibilityIdentifier("auto-copy-toggle")
                    Toggle(String(localized: "Reconnect when opening the app"), isOn: $store.autoReconnectOnLaunch)
                        .onChange(of: store.autoReconnectOnLaunch) { _ in store.persistPreferences() }
                        .accessibilityIdentifier("auto-reconnect-toggle")
                }
                BuddyPauseSettingsSection()
                BuddyStartupSettingsSection()
            case BuddySettingsItem.privacy.id:
                BuddyLegalLinksSection(brand: brand)
            default:
                EmptyView()
            }
        }
        .accessibilityIdentifier("otp-settings")
    }
}

struct OTPPopoverView: View {
    @EnvironmentObject private var store: OTPStore
    @EnvironmentObject private var pause: BuddyPauseController
    @State private var isTogglingConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(popoverStatusColor)
                        .frame(width: 10, height: 10)
                    Text(connectionLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BuddyTheme.BuddyColor.textPrimary)
                    Spacer()
                    Button {
                        Task { await toggleAllConnections() }
                    } label: {
                        if isTogglingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(store.areAllAccountsConnected
                                  ? String(localized: "Disconnect")
                                  : String(localized: "Connect"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.accounts.isEmpty || isTogglingConnection)
                    .help(store.areAllAccountsConnected
                          ? String(localized: "Disconnect all accounts")
                          : String(localized: "Connect all accounts"))
                    .accessibilityIdentifier("popover-toggle-all-connections")
                }

                if store.mailItems.isEmpty {
                    Text(store.latestAnnouncement.isEmpty
                           ? String(localized: "Waiting for OTP emails… Codes aren’t saved when you quit.")
                           : store.latestAnnouncement)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Recent codes"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    let recent = Array(store.mailItems.prefix(3))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        OTPMailRow(
                            item: item,
                            shortcutHint: BuddyDigitCopyShortcutsModifier.hint(for: index)
                        ) {
                            store.copyCode(item.code)
                        }
                    }
                }
            }
            .padding([.horizontal, .top])

            Spacer(minLength: 8)
            BuddyMenuBarFooter {
                BuddyPauseControls(pause: pause)
                BuddyMenuBarAppControls(appName: "OTP Buddy", brand: .otpBuddy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque chrome so desktop/wallpaper blue doesn’t sit behind blue accent labels.
        // Apply after `.buddyAppearance` so label color wins over accent tint on body text.
        .buddyAppearance(brand: .otpBuddy)
        .background(BuddyTheme.BuddyColor.background)
        .foregroundStyle(BuddyTheme.BuddyColor.textPrimary)
        .buddyDigitCopyShortcuts(itemCount: min(store.mailItems.count, 3)) { index in
            copyRecentCode(at: index)
        }
    }

    private var connectionLabel: String {
        if store.accounts.isEmpty {
            return String(localized: "No accounts")
        }
        if !store.failedAccountIDs.isEmpty, !store.isConnected {
            return String(localized: "Connection error")
        }
        if store.areAllAccountsConnected {
            return String(localized: "Connected")
        }
        if store.isConnected {
            return store.failedAccountIDs.isEmpty
                ? String(localized: "Partially connected")
                : String(localized: "Connection error")
        }
        return String(localized: "Disconnected")
    }

    private var popoverStatusColor: Color {
        if !store.failedAccountIDs.isEmpty {
            return Color.red.opacity(0.85)
        }
        if store.isConnected {
            return .green
        }
        return Color.gray.opacity(0.55)
    }

    private func toggleAllConnections() async {
        isTogglingConnection = true
        defer { isTogglingConnection = false }
        if store.areAllAccountsConnected {
            store.disconnectAll()
        } else {
            _ = await store.connectAll(notifyOnPartialFailure: true)
        }
    }

    private func copyRecentCode(at index: Int) {
        let recent = Array(store.mailItems.prefix(3))
        guard recent.indices.contains(index) else { return }
        let item = recent[index]
        guard !item.isExpired else { return }
        store.copyCode(item.code)
    }
}
