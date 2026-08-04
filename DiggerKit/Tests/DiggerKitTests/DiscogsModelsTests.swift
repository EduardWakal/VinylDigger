import XCTest
@testable import DiggerKit

final class DiscogsModelsTests: XCTestCase {
    func testDecodesArtistWithAliasesAndGroups() throws {
        let data = try loadFixture("artist_13320")
        let artist = try DiscogsJSON.decoder.decode(DiscogsArtist.self, from: data)

        XCTAssertEqual(artist.id, 13320)
        XCTAssertEqual(artist.name, "Carl A. Finlow")
        XCTAssertTrue(artist.aliases.contains { $0.name == "Random Factor" })
        XCTAssertTrue(artist.groups.contains { $0.name == "20:20 Vision" })
    }

    func testDecodesReleaseWithCommunityAndVideos() throws {
        let data = try loadFixture("release_2831")
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: data)

        XCTAssertEqual(release.id, 2831)
        XCTAssertGreaterThan(release.community.want, 0)
        XCTAssertGreaterThan(release.community.have, 0)
        XCTAssertFalse(release.videos.isEmpty)
        XCTAssertFalse(release.tracklist.isEmpty)
        XCTAssertFalse(release.labels.isEmpty)
    }

    func testExtractsYouTubeIDFromWatchURL() {
        let video = DiscogsVideo(uri: "https://www.youtube.com/watch?v=cqRa3O8xQNQ", title: nil)
        XCTAssertEqual(video.youtubeID, "cqRa3O8xQNQ")
    }

    func testExtractsYouTubeIDFromShortURL() {
        let video = DiscogsVideo(uri: "https://youtu.be/cqRa3O8xQNQ", title: nil)
        XCTAssertEqual(video.youtubeID, "cqRa3O8xQNQ")
    }

    func testReturnsNilYouTubeIDForForeignHost() {
        let video = DiscogsVideo(uri: "https://vimeo.com/12345", title: nil)
        XCTAssertNil(video.youtubeID)
    }

    func testMissingOptionalFieldsDecodeToNil() throws {
        let json = Data(#"{"id": 1, "title": "X", "labels": [], "artists": []}"#.utf8)
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: json)

        XCTAssertNil(release.year)
        XCTAssertEqual(release.styles, [])
        XCTAssertEqual(release.videos, [])
        XCTAssertEqual(release.community.want, 0)
    }
}
