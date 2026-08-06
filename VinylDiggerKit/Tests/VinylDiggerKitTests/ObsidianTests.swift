import XCTest
@testable import VinylDiggerKit

final class ObsidianRendererTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func release(_ id: Int, _ title: String, year: Int? = 1999) -> ReleaseRecord {
        ReleaseRecord(
            id: id, title: title, artistName: "Inland Knights", year: year,
            catno: "VIS0\(id)", labelID: 15, styles: ["Deep House"],
            want: 582, have: 517, hydrated: true, rating: 4.22, ratingCount: 79
        )
    }

    private func entry(_ id: Int, _ title: String, _ kind: DecisionKind, likes: Int = 0) -> LibraryEntry {
        LibraryEntry(
            release: release(id, title), labelName: "20:20 Vision", kind: kind,
            decidedAt: generatedAt, likedTrackCount: likes
        )
    }

    func testOverviewCountsDecisions() {
        let export = ObsidianRenderer.render(
            library: [
                entry(1, "A", .love), entry(2, "B", .love),
                entry(3, "C", .discard), entry(4, "D", .later)
            ],
            likes: [],
            generatedAt: generatedAt
        )

        XCTAssertTrue(export.overview.contains("# Vinylsammlung"))
        XCTAssertTrue(export.overview.contains("| Wantlist ♥ | 2 |"))
        XCTAssertTrue(export.overview.contains("| Später ↓ | 1 |"))
        XCTAssertTrue(export.overview.contains("| Verworfen ✗ | 1 |"))
    }

    func testOverviewLinksTheExistingNotes() {
        let export = ObsidianRenderer.render(library: [], likes: [], generatedAt: generatedAt)

        XCTAssertTrue(export.overview.contains("[[Musiksammlung]]"))
        XCTAssertTrue(export.overview.contains("[[Dig Minimal-House Vinyl]]"))
    }

    func testOverviewListsTopLabels() {
        let export = ObsidianRenderer.render(
            library: [entry(1, "A", .love), entry(2, "B", .love)],
            likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(export.overview.contains("20:20 Vision"))
    }

    func testTracklistGroupsWantlistByLabel() {
        let export = ObsidianRenderer.render(
            library: [entry(1, "Fresh Connections", .love)],
            likes: [],
            generatedAt: generatedAt
        )

        XCTAssertTrue(export.tracklist.contains("## 20:20 Vision"))
        XCTAssertTrue(export.tracklist.contains("Inland Knights — Fresh Connections"))
    }

    func testTracklistShowsLikedTracksUnderTheirRelease() {
        let like = LikedTrack(
            releaseID: 1, releaseTitle: "Fresh Connections", artistName: "Inland Knights",
            labelName: "20:20 Vision", trackPosition: "B1", trackTitle: "Toi Toi",
            youtubeID: "abc", likedAt: generatedAt
        )
        let export = ObsidianRenderer.render(
            library: [entry(1, "Fresh Connections", .love, likes: 1)],
            likes: [like],
            generatedAt: generatedAt
        )

        XCTAssertTrue(export.tracklist.contains("B1 · Toi Toi"))
        XCTAssertTrue(export.tracklist.contains("youtube.com/watch?v=abc"))
    }

    func testDiscardedReleasesStayOutOfTheTracklist() {
        let export = ObsidianRenderer.render(
            library: [entry(9, "Nope", .discard)], likes: [], generatedAt: generatedAt
        )

        XCTAssertFalse(export.tracklist.contains("Nope"))
    }
}

final class ObsidianMergeTests: XCTestCase {
    func testMergeKeepsHandWrittenPart() {
        let existing = """
        # Vinylsammlung
        alter Inhalt

        \(ObsidianRenderer.handMarker)

        Meine eigene Notiz.
        """

        let merged = ObsidianRenderer.merge(rendered: "# Vinylsammlung\nneu", into: existing)

        XCTAssertTrue(merged.contains("neu"))
        XCTAssertTrue(merged.contains("Meine eigene Notiz."))
        XCTAssertFalse(merged.contains("alter Inhalt"))
    }

    func testMergeAppendsMarkerWhenMissing() {
        let merged = ObsidianRenderer.merge(rendered: "# Neu", into: "# Alt ohne Markierung")

        XCTAssertTrue(merged.contains(ObsidianRenderer.handMarker))
        XCTAssertTrue(merged.contains("# Neu"))
    }

    func testMergeIntoNothingStillCarriesTheMarker() {
        let merged = ObsidianRenderer.merge(rendered: "# Neu", into: nil)

        XCTAssertTrue(merged.hasPrefix("# Neu"))
        XCTAssertTrue(merged.contains(ObsidianRenderer.handMarker))
    }

    func testMergeIsStableWhenRunTwice() {
        let once = ObsidianRenderer.merge(rendered: "# Neu", into: nil)
        let twice = ObsidianRenderer.merge(rendered: "# Neu", into: once)

        XCTAssertEqual(once, twice)
    }
}

final class ObsidianWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesBothNotes() async throws {
        let writer = ObsidianWriter(directory: directory)

        try await writer.write(ObsidianExport(overview: "# Übersicht", tracklist: "# Tracks"))

        let overview = try String(contentsOf: directory.appendingPathComponent("Vinylsammlung.md"))
        let tracks = try String(
            contentsOf: directory.appendingPathComponent("Vinylsammlung - Trackliste.md")
        )
        XCTAssertTrue(overview.contains("# Übersicht"))
        XCTAssertTrue(tracks.contains("# Tracks"))
    }

    func testSecondWriteKeepsHandWrittenPart() async throws {
        let writer = ObsidianWriter(directory: directory)
        try await writer.write(ObsidianExport(overview: "# Eins", tracklist: "# Tracks"))

        let path = directory.appendingPathComponent("Vinylsammlung.md")
        var content = try String(contentsOf: path)
        content += "\nVon Hand ergänzt.\n"
        try content.write(to: path, atomically: true, encoding: .utf8)

        try await writer.write(ObsidianExport(overview: "# Zwei", tracklist: "# Tracks"))

        let after = try String(contentsOf: path)
        XCTAssertTrue(after.contains("# Zwei"))
        XCTAssertTrue(after.contains("Von Hand ergänzt."))
        XCTAssertFalse(after.contains("# Eins"))
    }

    func testMissingDirectoryThrows() async {
        let writer = ObsidianWriter(directory: directory.appendingPathComponent("fehlt"))

        do {
            try await writer.write(ObsidianExport(overview: "x", tracklist: "y"))
            XCTFail("expected a throw")
        } catch {}
    }
}
