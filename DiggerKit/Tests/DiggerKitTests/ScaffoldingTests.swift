import XCTest
@testable import DiggerKit

final class ScaffoldingTests: XCTestCase {
    func testPackageVersionIsExposed() {
        XCTAssertEqual(DiggerKit.version, "0.1.0")
    }
}
