import Foundation
import XCTest

enum FixtureError: Error { case missing(String) }

func loadFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}
