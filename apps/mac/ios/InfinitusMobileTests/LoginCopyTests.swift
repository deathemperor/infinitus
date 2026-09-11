import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// A login need reads by its provider (#367): profile for AWS, account or
/// the application default credentials for gcloud.
final class LoginCopyTests: XCTestCase {
    func testSubjectAndNeedFollowTheProvider() {
        XCTAssertEqual(AwsLogin.subjectLabel(provider: .aws, profile: "papaya"), "profile papaya")
        XCTAssertEqual(AwsLogin.subjectLabel(provider: .gcloud, profile: "loc@example.com"), "account loc@example.com")
        XCTAssertEqual(AwsLogin.subjectLabel(provider: .gcloud, profile: GcloudLogin.adcProfile), "application default credentials")
        XCTAssertEqual(AwsLogin.Provider.aws.loginLabel, "AWS login")
        XCTAssertEqual(AwsLogin.Provider.gcloud.loginLabel, "gcloud login")
    }
}
