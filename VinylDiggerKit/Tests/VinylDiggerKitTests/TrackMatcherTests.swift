import XCTest
@testable import VinylDiggerKit

final class TrackMatcherTests: XCTestCase {
    private func video(_ title: String) -> DiscogsVideo {
        DiscogsVideo(uri: "https://youtu.be/abc", title: title, duration: nil)
    }

    func testMatchesTrackTitleInsideVideoTitle() {
        let videos = [
            video("BCR035 : Mr G - Let Down"),
            video("BCR035 : Mr G - Toi Toi")
        ]
        let tracklist = [
            DiscogsTrack(position: "A1", title: "Let Down"),
            DiscogsTrack(position: "B1", title: "Toi Toi")
        ]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), ["A1", "B1"])
    }

    func testIgnoresCaseAndPunctuation() {
        let videos = [video("Mr. G — TONY'S TAXI (Lol Lindy)")]
        let tracklist = [DiscogsTrack(position: "B2", title: "Tony's Taxi")]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), ["B2"])
    }

    func testReturnsNilWhenNothingMatches() {
        let videos = [video("Some Unrelated Live Set")]
        let tracklist = [DiscogsTrack(position: "A1", title: "Let Down")]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), [nil])
    }

    func testReturnsNilWhenTwoTracksMatchEqually() {
        let videos = [video("Label - Untitled")]
        let tracklist = [
            DiscogsTrack(position: "A1", title: "Untitled"),
            DiscogsTrack(position: "B1", title: "Untitled")
        ]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), [nil])
    }

    func testEmptyTracklistYieldsAllNil() {
        let videos = [video("A"), video("B")]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: []), [nil, nil])
    }

    func testSkipsTracksWithoutPosition() {
        let videos = [video("Artist - Interlude")]
        let tracklist = [DiscogsTrack(position: nil, title: "Interlude")]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), [nil])
    }

    func testPrefersLongestMatchingTitle() {
        let videos = [video("Artist - Love's Fading (Dub)")]
        let tracklist = [
            DiscogsTrack(position: "A1", title: "Love's Fading"),
            DiscogsTrack(position: "A2", title: "Love's Fading (Dub)")
        ]

        XCTAssertEqual(TrackMatcher.positions(videos: videos, tracklist: tracklist), ["A2"])
    }
}
