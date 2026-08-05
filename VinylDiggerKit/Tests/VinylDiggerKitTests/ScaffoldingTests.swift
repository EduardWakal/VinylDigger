import XCTest
@testable import VinylDiggerKit

final class ScaffoldingTests: XCTestCase {
    func testPackageVersionIsExposed() {
        XCTAssertEqual(VinylDiggerKit.version, "0.1.0")
    }
}
