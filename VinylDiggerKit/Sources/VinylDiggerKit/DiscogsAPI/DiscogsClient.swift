import Foundation

public enum DiscogsError: Error, Equatable {
    case missingToken
    case unauthorized
    case rateLimited
    case notFound
    case http(Int)
    case transport
}

public actor DiscogsClient {
    private static let host = "api.discogs.com"
    private static let maxRateLimitRetries = 3

    private let transport: HTTPTransport
    private let secrets: SecretStore
    private let limiter: RateLimiter
    private let userAgent: String

    public init(
        transport: HTTPTransport,
        secrets: SecretStore,
        limiter: RateLimiter,
        userAgent: String = "VinylDigger/0.1 +https://github.com/EduardWakal/VinylDigger"
    ) {
        self.transport = transport
        self.secrets = secrets
        self.limiter = limiter
        self.userAgent = userAgent
    }

    // MARK: - Endpoints

    public func artist(id: Int) async throws -> DiscogsArtist {
        try await fetch(path: "/artists/\(id)")
    }

    public func artistReleases(id: Int, page: Int = 1) async throws -> DiscogsPage<DiscogsReleaseSummary> {
        try await fetchPage(path: "/artists/\(id)/releases", key: .releases, page: page)
    }

    public func labelReleases(id: Int, page: Int = 1) async throws -> DiscogsPage<DiscogsReleaseSummary> {
        try await fetchPage(path: "/labels/\(id)/releases", key: .releases, page: page)
    }

    public func release(id: Int) async throws -> DiscogsRelease {
        try await fetch(path: "/releases/\(id)")
    }

    public func searchArtist(name: String) async throws -> [DiscogsNameRef] {
        struct Hit: Codable { let id: Int; let title: String }
        struct Envelope: Codable { let results: [Hit] }
        let envelope: Envelope = try await fetch(
            path: "/database/search",
            query: [URLQueryItem(name: "q", value: name), URLQueryItem(name: "type", value: "artist")]
        )
        return envelope.results.map { DiscogsNameRef(id: $0.id, name: $0.title) }
    }

    /// Looks a hand-typed dig line up in the Discogs catalogue. Vinyl only — the
    /// list came off records, and format noise costs review time.
    public func searchReleases(artist: String?, title: String) async throws -> [DiscogsReleaseSummary] {
        struct Hit: Codable {
            let id: Int
            let title: String
            let year: String?
            let label: [String]?
            let catno: String?
        }
        struct Envelope: Codable { let results: [Hit] }

        var query = [
            URLQueryItem(name: "release_title", value: title),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Vinyl"),
            URLQueryItem(name: "per_page", value: "5")
        ]
        if let artist, !artist.isEmpty {
            query.append(URLQueryItem(name: "artist", value: artist))
        }

        let envelope: Envelope = try await fetch(path: "/database/search", query: query)
        return envelope.results.map { hit in
            DiscogsReleaseSummary(
                id: hit.id,
                // Search returns "Artist - Title" in one string; keep it whole rather
                // than splitting it a second time and risking a wrong artist.
                title: hit.title,
                year: hit.year.flatMap(Int.init),
                label: hit.label?.first,
                catno: hit.catno,
                artist: nil,
                role: nil
            )
        }
    }

    public func collectionReleaseIDs(username: String) async throws -> [Int] {
        try await allReleaseIDs(path: "/users/\(username)/collection/folders/0/releases")
    }

    public func wantlistReleaseIDs(username: String) async throws -> [Int] {
        try await allReleaseIDs(path: "/users/\(username)/wants")
    }

    public func addToWantlist(username: String, releaseID: Int) async throws {
        _ = try await perform(
            path: "/users/\(username)/wants/\(releaseID)",
            method: "PUT",
            query: []
        )
    }

    // MARK: - Paging helpers

    private enum PageKey: String {
        case releases
        case wants
    }

    private struct IDHolder: Codable, Equatable, Sendable {
        let id: Int
    }

    private struct PageEnvelope<Item: Codable>: Codable {
        let pagination: DiscogsPagination
        let releases: [Item]?
        let wants: [Item]?
    }

    private func allReleaseIDs(path: String) async throws -> [Int] {
        var ids: [Int] = []
        var page = 1
        while true {
            // Both /collection/... and /wants return their items under "releases".
            let result: DiscogsPage<IDHolder> = try await fetchPage(path: path, key: .releases, page: page)
            ids.append(contentsOf: result.items.map(\.id))
            if page >= result.pages { break }
            page += 1
        }
        return ids
    }

    private func fetchPage<T: Codable & Equatable & Sendable>(
        path: String,
        key: PageKey,
        page: Int
    ) async throws -> DiscogsPage<T> {
        let envelope: PageEnvelope<T> = try await fetch(
            path: path,
            query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "100")
            ]
        )
        let items = envelope.releases ?? envelope.wants ?? []
        return DiscogsPage(items: items, page: envelope.pagination.page, pages: envelope.pagination.pages)
    }

    // MARK: - Request plumbing

    private func fetch<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(path: path, method: "GET", query: query)
        return try DiscogsJSON.decoder.decode(T.self, from: data)
    }

    private func perform(path: String, method: String, query: [URLQueryItem]) async throws -> Data {
        guard let token = try secrets.read(.discogsToken), !token.isEmpty else {
            throw DiscogsError.missingToken
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DiscogsError.transport }

        var attempt = 0
        while true {
            await limiter.acquire()

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await transport.send(request)

            if let remaining = response.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining"),
               let value = Int(remaining) {
                await limiter.observeRemaining(value)
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw DiscogsError.unauthorized
            case 404:
                throw DiscogsError.notFound
            case 429:
                attempt += 1
                if attempt >= Self.maxRateLimitRetries { throw DiscogsError.rateLimited }
                let backoff = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            default:
                throw DiscogsError.http(response.statusCode)
            }
        }
    }
}
