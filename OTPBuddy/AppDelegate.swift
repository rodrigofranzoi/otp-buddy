import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = OTPStore.shared
        store.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "OTP Buddy")
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 180)
        popover.contentViewController = NSHostingController(
            rootView: OTPPopoverView().environmentObject(store)
        )
        self.popover = popover

        NotificationCenter.default.addObserver(
            forName: .otpReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPopover()
        }
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
}

extension Notification.Name {
    static let otpReceived = Notification.Name("buddy.otp.received")
}
