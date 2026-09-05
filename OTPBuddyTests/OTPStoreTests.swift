import XCTest
@testable import OTPBuddy
import BuddyTesting

final class OTPStoreTests: XCTestCase {
    @MainActor
    func testIngestDemoEmail() {
        let store = OTPStore()
        store.autoCopy = false
        store.ingestDemoEmail(BuddyFixtures.otpEmail)
        XCTAssertEqual(store.latestOTP, "482913")
        XCTAssertTrue(store.latestAnnouncement.contains("OTP"))
    }
}
