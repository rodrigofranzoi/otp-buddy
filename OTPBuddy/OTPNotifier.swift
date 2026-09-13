import AppKit
import UserNotifications

/// macOS banners when an OTP is detected — code is the title; Copy is always available.
@MainActor
enum OTPNotifier {
    static let categoryOTP = "buddy.otp.code"
    static let actionCopy = "buddy.otp.copy"
    static let userInfoCodeKey = "otp.code"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        let copy = UNNotificationAction(
            identifier: actionCopy,
            title: String(localized: "Copy"),
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryOTP, actions: [copy], intentIdentifiers: [])
        ])
        center.delegate = OTPNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyOTP(code: String, autoCopied: Bool) {
        let content = UNMutableNotificationContent()
        // Title is rendered largest in macOS banners — put the code front and center.
        content.title = code
        content.subtitle = "OTP Buddy"
        content.sound = .default
        content.userInfo = [userInfoCodeKey: code]
        content.categoryIdentifier = categoryOTP
        content.body = autoCopied
            ? String(localized: "On your clipboard — tap Copy anytime")
            : String(localized: "Tap Copy to put it on the clipboard")

        let request = UNNotificationRequest(
            identifier: "buddy.otp.\(code).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyConnectionFailures(accounts: [TrackedAccount], statusMessage: String) {
        guard !accounts.isEmpty else { return }
        let names = accounts.prefix(3).map(\.displayName).joined(separator: ", ")
        let extra = accounts.count > 3 ? String(localized: " +\(accounts.count - 3) more") : ""

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Connection issue")
        content.subtitle = "OTP Buddy"
        content.sound = .default
        content.body = String(localized: "Couldn’t connect: \(names)\(extra). \(statusMessage)")

        let request = UNNotificationRequest(
            identifier: "buddy.otp.connect-failure.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func copyCode(_ code: String) {
        OTPStore.shared.copyCode(code)
    }
}

final class OTPNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OTPNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let code = userInfo[OTPNotifier.userInfoCodeKey] as? String
        let action = response.actionIdentifier

        DispatchQueue.main.async {
            switch action {
            case OTPNotifier.actionCopy:
                if let code {
                    OTPNotifier.copyCode(code)
                }
            case UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .otpShowPopover, object: nil)
            default:
                break
            }
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let otpShowPopover = Notification.Name("buddy.otp.showPopover")
}
