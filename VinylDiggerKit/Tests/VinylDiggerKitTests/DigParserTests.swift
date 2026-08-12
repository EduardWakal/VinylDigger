import XCTest
@testable import VinylDiggerKit

final class DigParserTests: XCTestCase {
    func testSplitsArtistAndTitle() {
        let lines = DigParser.parse("Carl Finlow - Islands")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].artist, "Carl Finlow")
        XCTAssertEqual(lines[0].title, "Islands")
    }

    func testStripsCataloguePrefix() {
        let lines = DigParser.parse("BCR035 : Mr G - Toi Toi")

        XCTAssertEqual(lines[0].artist, "Mr G")
        XCTAssertEqual(lines[0].title, "Toi Toi")
    }

    func testStripsTrailingCatalogueBracket() {
        let lines = DigParser.parse("Satoshi Tomiie - Late Night (Enzo Siragusa Remix) [VL011]")

        XCTAssertEqual(lines[0].artist, "Satoshi Tomiie")
        XCTAssertEqual(lines[0].title, "Late Night (Enzo Siragusa Remix)")
    }

    func testStripsSleevePositionPrefix() {
        let lines = DigParser.parse("B1. Gabriele Mancino - Reake [VENTRILOC001]")

        XCTAssertEqual(lines[0].artist, "Gabriele Mancino")
        XCTAssertEqual(lines[0].title, "Reake")
    }

    func testLineWithoutSeparatorKeepsEverythingAsTitle() {
        let lines = DigParser.parse("Late Night (Enzo Siragusa Remix)")

        XCTAssertNil(lines[0].artist)
        XCTAssertEqual(lines[0].title, "Late Night (Enzo Siragusa Remix)")
    }

    func testKeepsRawLineForDisplay() {
        let lines = DigParser.parse("BCR035 : Mr G - Toi Toi")

        XCTAssertEqual(lines[0].raw, "BCR035 : Mr G - Toi Toi")
    }

    func testSkipsBlankLines() {
        let lines = DigParser.parse("A - B\n\n   \nC - D")

        XCTAssertEqual(lines.count, 2)
    }

    func testHandlesEnDashSeparator() {
        let lines = DigParser.parse("Kelvin K – G's Groove")

        XCTAssertEqual(lines[0].artist, "Kelvin K")
        XCTAssertEqual(lines[0].title, "G's Groove")
    }

    func testDoesNotSplitOnHyphenInsideAWord() {
        let lines = DigParser.parse("Dig Minimal-House Vinyl")

        XCTAssertNil(lines[0].artist)
        XCTAssertEqual(lines[0].title, "Dig Minimal-House Vinyl")
    }
}

final class SearchReleasesTests: XCTestCase {
    private func makeClient(_ transport: StubTransport) -> DiscogsClient {
        let secrets = InMemorySecretStore()
        try? secrets.write("tok", for: .discogsToken)
        return DiscogsClient(
            transport: transport, secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
    }

    func testBuildsVinylOnlyQuery() async throws {
        let body = Data(#"{"results": []}"#.utf8)
        let transport = StubTransport(replies: [.init(body: body)])

        _ = try await makeClient(transport).searchReleases(artist: "Mr G", title: "Toi Toi")

        let url = transport.sentRequests[0].url!.absoluteString
        XCTAssertTrue(url.contains("release_title=Toi%20Toi") || url.contains("release_title=Toi+Toi"))
        XCTAssertTrue(url.contains("type=release"))
        XCTAssertTrue(url.contains("format=Vinyl"))
        XCTAssertTrue(url.contains("artist=Mr"))
    }

    func testOmitsArtistWhenAbsent() async throws {
        let body = Data(#"{"results": []}"#.utf8)
        let transport = StubTransport(replies: [.init(body: body)])

        _ = try await makeClient(transport).searchReleases(artist: nil, title: "Islands")

        XCTAssertFalse(transport.sentRequests[0].url!.absoluteString.contains("artist="))
    }

    func testMapsHitsOntoSummaries() async throws {
        let body = Data(#"""
        {"results": [{"id": 5040318, "title": "Mr. G - J's Credit EP", "year": "2013",
                      "label": ["Bass Culture Records"], "catno": "BCR035"}]}
        """#.utf8)
        let transport = StubTransport(replies: [.init(body: body)])

        let hits = try await makeClient(transport).searchReleases(artist: "Mr G", title: "Toi Toi")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, 5040318)
        XCTAssertEqual(hits[0].title, "Mr. G - J's Credit EP")
        XCTAssertEqual(hits[0].year, 2013)
        XCTAssertEqual(hits[0].label, "Bass Culture Records")
        XCTAssertEqual(hits[0].catno, "BCR035")
    }

    func testEmptyResultIsNotAnError() async throws {
        let transport = StubTransport(replies: [.init(body: Data(#"{"results": []}"#.utf8))])

        let hits = try await makeClient(transport).searchReleases(artist: nil, title: "nichts")

        XCTAssertTrue(hits.isEmpty)
    }
}
