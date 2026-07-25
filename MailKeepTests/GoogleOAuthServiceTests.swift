import XCTest
@testable import MailKeep

final class GoogleOAuthServiceTests: XCTestCase {

    func testValidateMailScopeAcceptsFullGrant() throws {
        try GoogleOAuthService.validateMailScope(
            "https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email openid")
    }

    func testValidateMailScopeAcceptsMailScopeAlone() throws {
        try GoogleOAuthService.validateMailScope("https://mail.google.com/")
    }

    func testValidateMailScopeRejectsGrantWithoutMailScope() {
        // The exact scope set observed on 2026-07-25 that broke Gmail IMAP:
        // the user left the Gmail checkbox unticked on Google's consent screen.
        let granted = "https://www.googleapis.com/auth/userinfo.email openid https://www.googleapis.com/auth/userinfo.profile"
        XCTAssertThrowsError(try GoogleOAuthService.validateMailScope(granted)) { error in
            guard case GoogleOAuthError.insufficientScope = error else {
                return XCTFail("Expected insufficientScope, got \(error)")
            }
        }
    }

    func testValidateMailScopeRejectsPrefixLookalike() {
        XCTAssertThrowsError(
            try GoogleOAuthService.validateMailScope("https://mail.google.com/extra openid"))
    }
}
