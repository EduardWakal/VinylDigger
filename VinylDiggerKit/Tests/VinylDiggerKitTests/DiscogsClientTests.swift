import XCTest
@testable import VinylDiggerKit

final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var sentRequests: [URLRequest] = []

    init(replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        sentRequests.append(request)
        let reply = replies.isEmpty ? Reply() : replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: reply.headers
        )!
        return (reply.body, response)
    }
}

final class DiscogsClientTests: XCTestCase {
    private func makeSecrets(token: String? = "tok") -> InMemorySecretStore {
        let secrets = InMemorySecretStore()
        if let token { try? secrets.write(token, for: .discogsToken) }
        return secrets
    }

    private func makeClient(_ transport: StubTransport, secrets: SecretStore? = nil) -> DiscogsClient {
        DiscogsClient(
            transport: transport,
            secrets: secrets ?? makeSecrets(),
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
    }

    func testSendsAuthorizationAndUserAgentHeaders() async throws {
        let body = try loadFixture("artist_13320")
        let transport = StubTransport(replies: [.init(body: body)])
        let client = makeClient(transport)

        _ = try await client.artist(id: 13320)

        let request = transport.sentRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Discogs token=tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "VinylDiggerTests/1.0")
        XCTAssertEqual(request.url?.path, "/artists/13320")
    }

    func testThrowsMissingTokenWhenKeychainEmpty() async {
        let transport = StubTransport(replies: [])
        let client = makeClient(transport, secrets: makeSecrets(token: nil))

        do {
            _ = try await client.artist(id: 1)
            XCTFail("expected missingToken")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .missingToken)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDecodesArtist() async throws {
        let body = try loadFixture("artist_13320")
        let client = makeClient(StubTransport(replies: [.init(body: body)]))

        let artist = try await client.artist(id: 13320)

        XCTAssertEqual(artist.name, "Carl A. Finlow")
        XCTAssertTrue(artist.aliases.contains { $0.name == "Random Factor" })
    }

    func testDecodesArtistReleasesPage() async throws {
        let json = """
        {"pagination": {"page": 1, "pages": 4},
         "releases": [
           {"id": 2831, "title": "Fresh Connections", "year": 1999,
            "label": "20:20 Vision", "catno": "VIS035", "artist": "Inland Knights", "role": "Main"}
         ]}
        """
        let client = makeClient(StubTransport(replies: [.init(body: Data(json.utf8))]))

        let page = try await client.artistReleases(id: 13320, page: 1)

        XCTAssertEqual(page.pages, 4)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].label, "20:20 Vision")
        XCTAssertEqual(page.items[0].catno, "VIS035")
    }

    func testMapsUnauthorized() async {
        let client = makeClient(StubTransport(replies: [.init(status: 401)]))

        do {
            _ = try await client.artist(id: 1)
            XCTFail("expected unauthorized")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMapsNotFound() async {
        let client = makeClient(StubTransport(replies: [.init(status: 404)]))

        do {
            _ = try await client.artist(id: 1)
            XCTFail("expected notFound")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRetriesOnceAfterRateLimit() async throws {
        let body = try loadFixture("artist_13320")
        let transport = StubTransport(replies: [
            .init(status: 429),
            .init(status: 200, body: body)
        ])
        let client = makeClient(transport)

        let artist = try await client.artist(id: 13320)

        XCTAssertEqual(artist.id, 13320)
        XCTAssertEqual(transport.sentRequests.count, 2)
    }

    func testGivesUpAfterRepeatedRateLimits() async {
        let transport = StubTransport(replies: [
            .init(status: 429), .init(status: 429), .init(status: 429), .init(status: 429)
        ])
        let client = makeClient(transport)

        do {
            _ = try await client.artist(id: 1)
            XCTFail("expected rateLimited")
        } catch let error as DiscogsError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAddToWantlistUsesPut() async throws {
        let transport = StubTransport(replies: [.init(status: 201)])
        let client = makeClient(transport)

        try await client.addToWantlist(username: "schakal", releaseID: 2831)

        let request = transport.sentRequests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/users/schakal/wants/2831")
    }

    func testCollectionReleaseIDsFollowsPagination() async throws {
        let page1 = """
        {"pagination": {"page": 1, "pages": 2}, "releases": [{"id": 1}, {"id": 2}]}
        """
        let page2 = """
        {"pagination": {"page": 2, "pages": 2}, "releases": [{"id": 3}]}
        """
        let transport = StubTransport(replies: [
            .init(body: Data(page1.utf8)),
            .init(body: Data(page2.utf8))
        ])
        let client = makeClient(transport)

        let ids = try await client.collectionReleaseIDs(username: "schakal")

        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testSearchByStyleDecodesHits() async throws {
        let json = """
        {"results": [
          {"id": 2831, "master_id": 41133, "title": "Inland Knights - Fresh Connections",
           "year": "1999", "label": ["20:20 Vision"], "catno": "VIS035",
           "style": ["House", "Deep House"],
           "community": {"have": 517, "want": 582}}
        ]}
        """
        let client = makeClient(StubTransport(replies: [.init(body: Data(json.utf8))]))

        let hits = try await client.searchByStyle(
            style: "Deep House", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, 2831)
        XCTAssertEqual(hits[0].masterID, 41133)
        XCTAssertEqual(hits[0].artistName, "Inland Knights")
        XCTAssertEqual(hits[0].recordTitle, "Fresh Connections")
        XCTAssertEqual(hits[0].year, 1999)
        XCTAssertEqual(hits[0].label, "20:20 Vision")
        XCTAssertEqual(hits[0].have, 517)
        XCTAssertEqual(hits[0].want, 582)
    }

    func testSearchByStyleTreatsZeroMasterAsAbsent() async throws {
        let json = """
        {"results": [{"id": 7, "master_id": 0, "title": "A - B", "community": {"have": 1, "want": 2}}]}
        """
        let client = makeClient(StubTransport(replies: [.init(body: Data(json.utf8))]))

        let hits = try await client.searchByStyle(
            style: "Minimal", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertNil(hits[0].masterID)
    }

    func testSearchByStyleBuildsQuery() async throws {
        let transport = StubTransport(replies: [.init(body: Data(#"{"results": []}"#.utf8))])
        let client = makeClient(transport)

        _ = try await client.searchByStyle(
            style: "Tech House", yearFrom: 1990, yearTo: 1999, page: 3
        )

        let url = transport.sentRequests[0].url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.path, "/database/search")
        XCTAssertEqual(value("type"), "release")
        XCTAssertEqual(value("format"), "Vinyl")
        XCTAssertEqual(value("genre"), "Electronic")
        XCTAssertEqual(value("style"), "Tech House")
        XCTAssertEqual(value("sort"), "want")
        XCTAssertEqual(value("sort_order"), "desc")
        XCTAssertEqual(value("per_page"), "50")
        XCTAssertEqual(value("page"), "3")
        XCTAssertEqual(value("year"), "1990-1999")
    }

    func testSearchByStyleOmitsYearForAllTime() async throws {
        let transport = StubTransport(replies: [.init(body: Data(#"{"results": []}"#.utf8))])
        let client = makeClient(transport)

        _ = try await client.searchByStyle(
            style: "House", yearFrom: nil, yearTo: nil, page: 1
        )

        let items = URLComponents(
            url: transport.sentRequests[0].url!, resolvingAgainstBaseURL: false
        )!.queryItems!
        XCTAssertNil(items.first { $0.name == "year" })
    }

    func testSearchByStyleDecodesLiveFixture() async throws {
        let body = try loadFixture("search_tech_house")
        let client = makeClient(StubTransport(replies: [.init(body: body)]))

        let hits = try await client.searchByStyle(
            style: "Tech House", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertFalse(hits[0].artistName.isEmpty)
    }
}
