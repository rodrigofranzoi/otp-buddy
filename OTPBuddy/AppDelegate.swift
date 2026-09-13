import AppKit
import SwiftUI
import BuddyCore
import BuddyUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BuddyAppearanceSettings.applyAppKitAppearance()
        OTPNotifier.configure()

        let store = OTPStore.shared
        let pause = BuddyPauseController.shared
        pause.onPauseChanged = { isPaused in
            if isPaused {
                store.stop()
            } else {
                store.start()
            }
        }
        pause.restorePersistedPauseIfNeeded()
        Task {
            if store.autoReconnectOnLaunch {
                await store.reconnectIfPossible()
            }
            if !pause.isPaused, store.isConnected {
                store.start()
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item
        updateStatusIcon()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: OTPPopoverView()
                .environmentObject(store)
                .environmentObject(pause)
        )
        self.popover = popover

        // Banner handles the alert; open the menu-bar popover only if the user taps the notification.
        NotificationCenter.default.addObserver(
            forName: .otpShowPopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showPopover()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .buddyPauseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .otpConnectionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .buddyDismissMenuBarPopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover?.performClose(nil)
            }
        }

        if BuddyMarketingCapture.isEnabled {
            NSApp.setActivationPolicy(.regular)
            OTPMarketingCaptureRunner.startIfNeeded(
                store: store,
                pause: pause,
                showPopover: { [weak self] in self?.showPopoverForCapture() }
            )
        } else {
            BuddyMainWindow.presentFirstLaunchExperienceIfNeeded(
                appDisplayName: BuddyBrand.otpBuddy.displayName
            )
        }
    }

    @discardableResult
    private func showPopoverForCapture() -> NSWindow? {
        showPopover()
        return popover?.contentViewController?.view.window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusIcon() {
        let paused = BuddyPauseController.shared.isPaused
        let connected = OTPStore.shared.isConnected
        let name: String
        if paused {
            name = "lock.shield.fill"
        } else if connected {
            name = "lock.shield.fill"
        } else {
            name = "lock.shield"
        }
        let description: String
        if paused {
            description = "OTP Buddy (paused)"
        } else if connected {
            description = "OTP Buddy (connected)"
        } else {
            description = "OTP Buddy (disconnected)"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        statusItem?.button?.appearsDisabled = paused || !connected
    }
}

extension Notification.Name {
    static let otpReceived = Notification.Name("buddy.otp.received")
}
