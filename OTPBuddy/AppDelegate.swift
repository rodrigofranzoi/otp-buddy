import AppKit
import SwiftUI
import BuddyCore
import BuddyUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BuddyLaunchAtLogin.enableByDefaultOnFirstInstall()
        BuddyAppearanceSettings.applyAppKitAppearance()

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
        if !pause.isPaused {
            store.start()
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
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: OTPPopoverView()
                .environmentObject(store)
                .environmentObject(pause)
        )
        self.popover = popover

        NotificationCenter.default.addObserver(
            forName: .otpReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard BuddyPauseController.shared.isPaused == false else { return }
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

        BuddyMainWindow.hideOnLaunchIfNeeded()
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
    }

    private func updateStatusIcon() {
        let paused = BuddyPauseController.shared.isPaused
        let name = paused ? "lock.shield.fill" : "lock.shield"
        let description = paused ? "OTP Buddy (paused)" : "OTP Buddy"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        statusItem?.button?.appearsDisabled = paused
    }
}

extension Notification.Name {
    static let otpReceived = Notification.Name("buddy.otp.received")
}
