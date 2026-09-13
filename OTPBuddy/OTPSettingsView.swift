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
                BuddyRateAppSettingsSection(brand: brand)
                Section(String(localized: "Status")) {
                    Text(store.statusMessage)
                        .accessibilityIdentifier("status-message")
                }
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
                        .fill(store.isConnected ? Color.green : Color.gray.opacity(0.55))
                        .frame(width: 10, height: 10)
                    Text(connectionLabel)
                        .font(.subheadline.weight(.medium))
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
                           ? String(localized: "Waiting for OTP emails…")
                           : store.latestAnnouncement)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Recent codes"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.mailItems.prefix(3)) { item in
                        OTPMailRow(item: item) {
                            store.copyCode(item.code)
                        }
                    }
                }
            }
            .padding([.horizontal, .top])

            Spacer(minLength: 8)
            BuddyPauseControls(pause: pause)
            BuddyMenuBarAppControls(appName: "OTP Buddy", brand: .otpBuddy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .buddyAppearance(brand: .otpBuddy)
    }

    private var connectionLabel: String {
        if store.accounts.isEmpty {
            return String(localized: "No accounts")
        }
        if store.areAllAccountsConnected {
            return String(localized: "Connected")
        }
        if store.isConnected {
            return String(localized: "Partially connected")
        }
        return String(localized: "Disconnected")
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
}
