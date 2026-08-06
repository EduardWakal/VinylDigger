import XCTest
@testable import VinylDiggerKit

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

    func testDecodesCommunityRating() throws {
        let data = try loadFixture("release_2831")
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: data)

        XCTAssertEqual(release.community.rating.average, 4.22, accuracy: 0.001)
        XCTAssertEqual(release.community.rating.count, 79)
    }

    func testMissingRatingDecodesToZero() throws {
        let json = Data(#"{"id": 1, "title": "X", "labels": [], "artists": [], "community": {"want": 5, "have": 2}}"#.utf8)
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: json)

        XCTAssertEqual(release.community.rating.average, 0)
        XCTAssertEqual(release.community.rating.count, 0)
    }

    func testDecodesImagesAndCoverURL() throws {
        let json = Data(#"""
        {"id": 1, "title": "X", "labels": [], "artists": [],
         "images": [
           {"type": "secondary", "uri": "https://i.discogs.com/back.jpeg", "uri150": "https://i.discogs.com/back150.jpeg"},
           {"type": "primary", "uri": "https://i.discogs.com/front.jpeg", "uri150": "https://i.discogs.com/front150.jpeg"}
         ]}
        """#.utf8)
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: json)

        XCTAssertEqual(release.images.count, 2)
        XCTAssertEqual(release.coverURL, "https://i.discogs.com/front.jpeg")
    }

    func testCoverURLFallsBackToFirstImage() throws {
        let json = Data(#"""
        {"id": 1, "title": "X", "labels": [], "artists": [],
         "images": [{"uri": "https://i.discogs.com/only.jpeg"}]}
        """#.utf8)
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: json)

        XCTAssertEqual(release.coverURL, "https://i.discogs.com/only.jpeg")
    }

    func testCoverURLIsNilWithoutImages() throws {
        let json = Data(#"{"id": 1, "title": "X", "labels": [], "artists": []}"#.utf8)
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: json)

        XCTAssertNil(release.coverURL)
    }

    func testDecodesVideoDuration() throws {
        let data = try loadFixture("release_2831")
        let release = try DiscogsJSON.decoder.decode(DiscogsRelease.self, from: data)

        XCTAssertNotNil(release.videos.first?.duration)
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

final class ReleaseSummaryIdentityTests: XCTestCase {
    func testAMasterEntryReportsItsMainRelease() throws {
        let json = Data(#"""
        {"type": "master", "id": 75951, "main_release": 43321, "title": "Limitations EP"}
        """#.utf8)
        let summary = try DiscogsJSON.decoder.decode(DiscogsReleaseSummary.self, from: json)

        XCTAssertEqual(
            summary.releaseID, 43321,
            "a master id is not a release id — fetching it returns a different record"
        )
    }

    func testAPlainReleaseEntryKeepsItsOwnID() throws {
        let json = Data(#"{"type": "release", "id": 16100, "title": "Sheltered EP"}"#.utf8)
        let summary = try DiscogsJSON.decoder.decode(DiscogsReleaseSummary.self, from: json)

        XCTAssertEqual(summary.releaseID, 16100)
    }

    func testAMasterWithoutAMainReleaseIsUnusable() throws {
        let json = Data(#"{"type": "master", "id": 75951, "title": "Limitations EP"}"#.utf8)
        let summary = try DiscogsJSON.decoder.decode(DiscogsReleaseSummary.self, from: json)

        XCTAssertNil(summary.releaseID, "better no record than the wrong one")
    }

    func testAnEntryWithoutATypeIsTreatedAsARelease() throws {
        let json = Data(#"{"id": 16100, "title": "Sheltered EP"}"#.utf8)
        let summary = try DiscogsJSON.decoder.decode(DiscogsReleaseSummary.self, from: json)

        XCTAssertEqual(summary.releaseID, 16100)
    }
}
