import Foundation

public enum DiscogsJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

public struct DiscogsNameRef: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct DiscogsArtist: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let aliases: [DiscogsNameRef]
    public let groups: [DiscogsNameRef]

    private enum CodingKeys: String, CodingKey { case id, name, aliases, groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([DiscogsNameRef].self, forKey: .aliases) ?? []
        groups = try c.decodeIfPresent([DiscogsNameRef].self, forKey: .groups) ?? []
    }

    public init(id: Int, name: String, aliases: [DiscogsNameRef], groups: [DiscogsNameRef]) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.groups = groups
    }
}

public struct DiscogsRating: Codable, Equatable, Sendable {
    /// Community average on Discogs' 0–5 scale; 0 when nobody has rated yet.
    public let average: Double
    public let count: Int

    public init(average: Double = 0, count: Int = 0) {
        self.average = average
        self.count = count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        average = try c.decodeIfPresent(Double.self, forKey: .average) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case average, count }
}

public struct DiscogsCommunity: Codable, Equatable, Sendable {
    public let want: Int
    public let have: Int
    public let rating: DiscogsRating

    public init(want: Int = 0, have: Int = 0, rating: DiscogsRating = DiscogsRating()) {
        self.want = want
        self.have = have
        self.rating = rating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        want = try c.decodeIfPresent(Int.self, forKey: .want) ?? 0
        have = try c.decodeIfPresent(Int.self, forKey: .have) ?? 0
        rating = try c.decodeIfPresent(DiscogsRating.self, forKey: .rating) ?? DiscogsRating()
    }

    private enum CodingKeys: String, CodingKey { case want, have, rating }
}

public struct DiscogsImage: Codable, Equatable, Sendable {
    public let type: String?
    public let uri: String
    public let uri150: String?

    public init(type: String? = nil, uri: String, uri150: String? = nil) {
        self.type = type
        self.uri = uri
        self.uri150 = uri150
    }
}

public struct DiscogsVideo: Codable, Equatable, Sendable {
    public let uri: String
    public let title: String?
    /// Length in seconds as Discogs reports it; the tracklist rarely carries one.
    public let duration: Int?

    public init(uri: String, title: String?, duration: Int? = nil) {
        self.uri = uri
        self.title = title
        self.duration = duration
    }

    /// Discogs stores full YouTube URLs. The IFrame player needs the bare video ID.
    public var youtubeID: String? {
        guard let components = URLComponents(string: uri), let host = components.host else { return nil }
        if host.contains("youtu.be") {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        return components.queryItems?.first { $0.name == "v" }?.value
    }
}

public struct DiscogsTrack: Codable, Equatable, Sendable {
    public let position: String?
    public let title: String
}

public struct DiscogsLabelRef: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let catno: String?
}

public struct DiscogsRelease: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let year: Int?
    public let styles: [String]
    public let genres: [String]
    public let community: DiscogsCommunity
    public let videos: [DiscogsVideo]
    public let tracklist: [DiscogsTrack]
    public let labels: [DiscogsLabelRef]
    public let artists: [DiscogsNameRef]
    public let images: [DiscogsImage]

    private enum CodingKeys: String, CodingKey {
        case id, title, year, styles, genres, community, videos, tracklist, labels, artists, images
    }

    /// Discogs puts the sleeve front under `type == "primary"`, but not every
    /// release marks one — then the first image is the best guess available.
    public var coverURL: String? {
        (images.first { $0.type == "primary" } ?? images.first)?.uri
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        styles = try c.decodeIfPresent([String].self, forKey: .styles) ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        community = try c.decodeIfPresent(DiscogsCommunity.self, forKey: .community) ?? DiscogsCommunity()
        videos = try c.decodeIfPresent([DiscogsVideo].self, forKey: .videos) ?? []
        tracklist = try c.decodeIfPresent([DiscogsTrack].self, forKey: .tracklist) ?? []
        labels = try c.decodeIfPresent([DiscogsLabelRef].self, forKey: .labels) ?? []
        artists = try c.decodeIfPresent([DiscogsNameRef].self, forKey: .artists) ?? []
        images = try c.decodeIfPresent([DiscogsImage].self, forKey: .images) ?? []
    }
}

public struct DiscogsReleaseSummary: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let year: Int?
    public let label: String?
    public let catno: String?
    public let artist: String?
    public let role: String?

    private enum CodingKeys: String, CodingKey { case id, title, year, label, catno, artist, role }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        catno = try c.decodeIfPresent(String.self, forKey: .catno)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }

    public init(id: Int, title: String, year: Int?, label: String?, catno: String?, artist: String?, role: String?) {
        self.id = id
        self.title = title
        self.year = year
        self.label = label
        self.catno = catno
        self.artist = artist
        self.role = role
    }
}

public struct DiscogsPagination: Codable, Equatable, Sendable {
    public let page: Int
    public let pages: Int
}

public struct DiscogsPage<T: Codable & Equatable & Sendable>: Equatable, Sendable {
    public let items: [T]
    public let page: Int
    public let pages: Int

    public init(items: [T], page: Int, pages: Int) {
        self.items = items
        self.page = page
        self.pages = pages
    }
}

/// One entry of the user's Discogs wantlist. The API nests the useful part under
/// `basic_information`; this flattens it.
public struct DiscogsWant: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let artistName: String
    public let year: Int?
    public let labelName: String?
    public let labelID: Int?
    public let catno: String?

    public init(
        id: Int, title: String, artistName: String, year: Int?,
        labelName: String?, labelID: Int?, catno: String?
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.year = year
        self.labelName = labelName
        self.labelID = labelID
        self.catno = catno
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case basicInformation = "basic_information"
    }

    private struct Basic: Codable {
        struct Ref: Codable {
            let id: Int?
            let name: String?
            let catno: String?
        }
        let title: String?
        let year: Int?
        let artists: [Ref]?
        let labels: [Ref]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        let basic = try c.decodeIfPresent(Basic.self, forKey: .basicInformation)
        title = basic?.title ?? ""
        year = basic?.year
        artistName = basic?.artists?.first?.name ?? ""
        labelName = basic?.labels?.first?.name
        labelID = basic?.labels?.first?.id
        catno = basic?.labels?.first?.catno
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
    }
}
