import SwiftUI
import BuddyCore
import BuddyFirebase
import BuddyUI

@main
struct OTPBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = OTPStore.shared

    init() {
        BuddyFirebase.configure()
        BuddyFirebase.log(event: BuddyFirebase.Event.appLaunch)
    }

    var body: some Scene {
        WindowGroup("OTP Buddy") {
            OTPDashboardView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .background(BuddyMainWindowRegistrar())
                .buddyAppearance(brand: .otpBuddy)
                .buddyAskForReviewOccasionally(brand: .otpBuddy)
        }

        Settings {
            OTPSettingsView()
                .environmentObject(store)
                .buddyAppearance(brand: .otpBuddy)
        }
    }
}
