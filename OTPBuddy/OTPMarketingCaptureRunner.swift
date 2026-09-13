import AppKit
import Foundation
import SwiftUI
import BuddyCore
import BuddyUI

@MainActor
enum OTPMarketingCaptureRunner {
    private static var hostedWindow: NSWindow?
    private static var settingsWindow: NSWindow?

    static func startIfNeeded(
        store: OTPStore,
        pause: BuddyPauseController,
        showPopover: @escaping () -> NSWindow?
    ) {
        guard BuddyMarketingCapture.isEnabled else { return }

        store.stop()
        pause.resume()
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(
            BuddyAppearanceSettings.ColorSchemePreference.light.rawValue,
            forKey: BuddySettingsKey.appearanceColorScheme
        )
        UserDefaults.standard.set(false, forKey: BuddySettingsKey.autoCopyOTP)

        Task { @MainActor in
            do {
                let out = try BuddyMarketingCapture.ensureOutputDirectory()
                await BuddyMarketingCapture.sleep(0.4)
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                try await captureConnect(store: store, out: out)
                store.installMarketingSeed()
                try await captureInbox(store: store, out: out)
                try await captureAlert(store: store, showPopover: showPopover, out: out)
                try await captureAutocopy(store: store, showPopover: showPopover, out: out)
                try await capturePause(store: store, pause: pause, showPopover: showPopover, out: out)
                pause.resume()
                try await captureSettings(store: store, out: out)

                print("[BuddyMarketing] OTP Buddy captures written to \(out.path)")
                NSApp.terminate(nil)
            } catch {
                fputs("[BuddyMarketing] ERROR: \(error)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    private static func makeDashboardWindow(store: OTPStore) -> NSWindow {
        if let hostedWindow {
            return hostedWindow
        }
        let root = OTPDashboardView()
            .environmentObject(store)
            .frame(minWidth: 900, minHeight: 560)
            .buddyAppearance(brand: .otpBuddy)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "OTP Buddy")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        hostedWindow = window
        BuddyMainWindow.register(window)
        return window
    }

    private static func captureConnect(store: OTPStore, out: URL) async throws {
        store.prepareMarketingEmptyState()
        let window = makeDashboardWindow(store: store)
        window.makeKeyAndOrderFront(nil)
        BuddyMarketingCapture.stage("connect")
        await BuddyMarketingCapture.sleep(1.0)
        try BuddyMarketingCapture.captureWindow(window, to: out.appendingPathComponent("connect.png"))
    }

    private static func captureInbox(store: OTPStore, out: URL) async throws {
        let window = makeDashboardWindow(store: store)
        window.makeKeyAndOrderFront(nil)
        store.objectWillChange.send()
        BuddyMarketingCapture.stage("inbox")
        await BuddyMarketingCapture.sleep(1.0)
        try BuddyMarketingCapture.captureWindow(window, to: out.appendingPathComponent("inbox.png"))
    }

    private static func captureAlert(
        store: OTPStore,
        showPopover: @escaping () -> NSWindow?,
        out: URL
    ) async throws {
        hostedWindow?.orderOut(nil)
        store.autoCopy = false
        store.latestAnnouncement = String(localized: "New OTP email received")
        store.statusMessage = store.latestAnnouncement
        await BuddyMarketingCapture.sleep(0.3)
        guard let popoverWindow = showPopover() else {
            throw BuddyMarketingCapture.CaptureError.missingPopoverWindow
        }
        BuddyMarketingCapture.stage("alert")
        await BuddyMarketingCapture.sleep(0.9)
        try BuddyMarketingCapture.captureWindow(popoverWindow, to: out.appendingPathComponent("alert.png"))
        popoverWindow.orderOut(nil)
    }

    private static func captureAutocopy(
        store: OTPStore,
        showPopover: @escaping () -> NSWindow?,
        out: URL
    ) async throws {
        store.autoCopy = true
        store.latestAnnouncement = String(localized: "New OTP is on your clipboard")
        store.statusMessage = store.latestAnnouncement
        if let code = store.latestOTP {
            store.copyCode(code)
        }
        await BuddyMarketingCapture.sleep(0.3)
        guard let popoverWindow = showPopover() else {
            throw BuddyMarketingCapture.CaptureError.missingPopoverWindow
        }
        BuddyMarketingCapture.stage("autocopy")
        await BuddyMarketingCapture.sleep(0.9)
        try BuddyMarketingCapture.captureWindow(popoverWindow, to: out.appendingPathComponent("autocopy.png"))
        popoverWindow.orderOut(nil)
        store.autoCopy = false
    }

    private static func capturePause(
        store: OTPStore,
        pause: BuddyPauseController,
        showPopover: @escaping () -> NSWindow?,
        out: URL
    ) async throws {
        pause.pauseUntilNextSession()
        await BuddyMarketingCapture.sleep(0.3)
        guard let popoverWindow = showPopover() else {
            throw BuddyMarketingCapture.CaptureError.missingPopoverWindow
        }
        BuddyMarketingCapture.stage("pause")
        await BuddyMarketingCapture.sleep(0.9)
        try BuddyMarketingCapture.captureWindow(popoverWindow, to: out.appendingPathComponent("pause.png"))
        popoverWindow.orderOut(nil)
    }

    private static func captureSettings(store: OTPStore, out: URL) async throws {
        hostedWindow?.orderOut(nil)
        let root = OTPSettingsView()
            .environmentObject(store)
            .frame(minWidth: 620, minHeight: 560)
            .buddyAppearance(brand: .otpBuddy)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
        BuddyMarketingCapture.stage("settings")
        await BuddyMarketingCapture.sleep(1.0)
        try BuddyMarketingCapture.captureWindow(window, to: out.appendingPathComponent("settings.png"))
        window.orderOut(nil)
    }
}
