import XCTest
@testable import VinylDiggerKit

final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    private let status: Int

    init(status: Int = 200) { self.status = status }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data("image-bytes".utf8), response)
    }
}

final class CoverStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDownloadsAndStoresCover() async throws {
        let transport = CountingTransport()
        let store = CoverStore(directory: directory, transport: transport)

        let url = try await store.localURL(
            for: 2831, remote: URL(string: "https://i.discogs.com/front.jpeg")!
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), Data("image-bytes".utf8))
        XCTAssertEqual(transport.callCount, 1)
    }

    func testSecondCallServesFromCache() async throws {
        let transport = CountingTransport()
        let store = CoverStore(directory: directory, transport: transport)
        let remote = URL(string: "https://i.discogs.com/front.jpeg")!

        _ = try await store.localURL(for: 2831, remote: remote)
        _ = try await store.localURL(for: 2831, remote: remote)

        XCTAssertEqual(transport.callCount, 1)
    }

    func testFailedDownloadThrowsAndWritesNothing() async throws {
        let transport = CountingTransport(status: 404)
        let store = CoverStore(directory: directory, transport: transport)

        do {
            _ = try await store.localURL(
                for: 2831, remote: URL(string: "https://i.discogs.com/front.jpeg")!
            )
            XCTFail("expected a throw")
        } catch {
            let path = directory.appendingPathComponent("2831.jpg").path
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }
}
