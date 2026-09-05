import SwiftUI
import BuddyFirebase

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
                .frame(minWidth: 520, minHeight: 400)
        }
    }
}
