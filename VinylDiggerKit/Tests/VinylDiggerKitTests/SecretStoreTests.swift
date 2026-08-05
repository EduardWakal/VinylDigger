import XCTest
@testable import VinylDiggerKit

final class SecretStoreTests: XCTestCase {
    private let service = "de.schakal.VinylDigger.tests"

    override func tearDown() {
        let store = KeychainSecretStore(service: service)
        try? store.delete(.discogsToken)
        super.tearDown()
    }

    func testReadReturnsNilWhenNothingStored() throws {
        let store = KeychainSecretStore(service: service)
        try store.delete(.discogsToken)
        XCTAssertNil(try store.read(.discogsToken))
    }

    func testWriteThenReadRoundTrips() throws {
        let store = KeychainSecretStore(service: service)
        try store.write("abc123", for: .discogsToken)
        XCTAssertEqual(try store.read(.discogsToken), "abc123")
    }

    func testWriteOverwritesExistingValue() throws {
        let store = KeychainSecretStore(service: service)
        try store.write("first", for: .discogsToken)
        try store.write("second", for: .discogsToken)
        XCTAssertEqual(try store.read(.discogsToken), "second")
    }

    func testDeleteRemovesValue() throws {
        let store = KeychainSecretStore(service: service)
        try store.write("abc123", for: .discogsToken)
        try store.delete(.discogsToken)
        XCTAssertNil(try store.read(.discogsToken))
    }

    func testInMemoryStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.read(.discogsToken))
        try store.write("xyz", for: .discogsToken)
        XCTAssertEqual(try store.read(.discogsToken), "xyz")
        try store.delete(.discogsToken)
        XCTAssertNil(try store.read(.discogsToken))
    }
}
