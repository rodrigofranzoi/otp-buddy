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
            SettingsDashboard()
                .environmentObject(store)
                .frame(minWidth: 640, minHeight: 440)
                .background(BuddyMainWindowRegistrar())
                .buddyAppearance(brand: .otpBuddy)
        }
    }
}
