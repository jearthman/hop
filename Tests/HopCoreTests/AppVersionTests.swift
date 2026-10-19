import XCTest
@testable import HopCore

final class AppVersionTests: XCTestCase {
    private func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testParsing() {
        XCTAssertEqual(v("v1.2.3").components, [1, 2, 3])
        XCTAssertEqual(v("1.0").components, [1, 0])
        XCTAssertEqual(v("2.0.0-beta.1").components, [2, 0, 0])
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("dev"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testOrdering() {
        XCTAssertLessThan(v("1.0.1"), v("1.1.0"))
        XCTAssertLessThan(v("1.9"), v("1.10"))
        XCTAssertLessThan(v("v1.0.9"), v("v1.1"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertFalse(v("1.1.0") < v("1.0.9"))
    }
}
