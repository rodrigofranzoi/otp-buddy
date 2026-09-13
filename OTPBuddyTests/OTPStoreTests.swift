import XCTest
@testable import OTPBuddy
import BuddyTesting

final class OTPStoreTests: XCTestCase {
    @MainActor
    func testIngestDemoEmailRequiresAccount() {
        let store = OTPStore()
        store.autoCopy = false
        store.accounts = [
            TrackedAccount(
                provider: .gmail,
                imap: IMAPAccount(host: "imap.gmail.com", port: 993, username: "demo@example.com", useTLS: true)
            )
        ]
        store.selectedAccountID = store.accounts.first?.id
        store.ingestDemoEmail(BuddyFixtures.otpEmail)
        XCTAssertEqual(store.latestOTP, "482913")
        XCTAssertFalse(store.mailItems.isEmpty)
    }

    func testIMAPProviderMatchingAndDefaults() {
        XCTAssertEqual(IMAPProvider.matching(host: "imap.gmail.com"), .gmail)
        XCTAssertEqual(IMAPProvider.matching(host: "imap.mail.yahoo.com"), .yahoo)
        XCTAssertEqual(IMAPProvider.matching(host: "imap.mail.me.com"), .icloud)
        XCTAssertEqual(IMAPProvider.matching(host: "imap-mail.outlook.com"), .outlook)
        XCTAssertEqual(IMAPProvider.matching(host: "outlook.office365.com"), .microsoft365)
        XCTAssertEqual(IMAPProvider.matching(host: "imap.custom.example"), .other)

        var account = IMAPAccount.empty
        IMAPProvider.outlook.apply(to: &account)
        XCTAssertEqual(account.host, "imap-mail.outlook.com")
        XCTAssertEqual(account.port, 993)
        XCTAssertTrue(account.useTLS)
    }

    @MainActor
    func testTrackedAccountTitleAndReorder() {
        let a = TrackedAccount(
            title: "Work",
            provider: .gmail,
            imap: IMAPAccount(host: "imap.gmail.com", port: 993, username: "work@otp-buddy.test", useTLS: true)
        )
        let b = TrackedAccount(
            provider: .outlook,
            imap: IMAPAccount(host: "imap-mail.outlook.com", port: 993, username: "personal@otp-buddy.test", useTLS: true)
        )
        XCTAssertEqual(a.displayName, "Work")
        XCTAssertEqual(a.listSubtitle, "work@otp-buddy.test")
        XCTAssertEqual(b.displayName, "personal@otp-buddy.test")
        XCTAssertEqual(b.listSubtitle, IMAPProvider.outlook.title)

        let store = OTPStore()
        store.accounts = [a, b]
        store.moveAccounts(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(store.accounts.map(\.id), [b.id, a.id])
    }

    func testMIMEExtractorPrefersHTMLFromFlyingBlueStyleMultipart() {
        let raw = """
        This is a multi-part message in MIME format.
        --7Vx82cHPUxfZ=_?:
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: 8bit

        %%=v(PASSWORD)=%% is your PIN code
        body { width: 100% !important; color: #051039; }
        --7Vx82cHPUxfZ=_?:
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: 8bit

        <table><tr><td>IMPORTANT</td></tr></table>
        <div>PIN code: 900752</div>
        --7Vx82cHPUxfZ=_?:--
        ) A78 OK Success [THROTTLED]
        """
        let parts = MIMEPartExtractor.extract(from: raw)
        XCTAssertNotNil(parts.html)
        XCTAssertTrue(parts.html?.contains("900752") == true)
        XCTAssertFalse(parts.html?.contains("THROTTLED") == true)
        XCTAssertFalse(parts.html?.contains("width: 100%") == true)

        let stripped = MIMEPartExtractor.stripTags(parts.html ?? "")
        XCTAssertTrue(stripped.contains("900752"))
        XCTAssertFalse(stripped.contains("{"))
    }

    func testMIMEExtractorInfersBoundaryWithoutHeader() {
        let raw = """
        preamble
        --abc123Boundary
        Content-Type: text/plain

        hello plain
        --abc123Boundary
        Content-Type: text/html

        <div>hello html 424242</div>
        --abc123Boundary--
        """
        let parts = MIMEPartExtractor.extract(from: raw)
        XCTAssertEqual(parts.plain?.trimmingCharacters(in: .whitespacesAndNewlines), "hello plain")
        XCTAssertTrue(parts.html?.contains("424242") == true)
    }
}
