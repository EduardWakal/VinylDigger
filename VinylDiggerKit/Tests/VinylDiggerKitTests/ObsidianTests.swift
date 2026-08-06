import XCTest
@testable import VinylDiggerKit

final class ObsidianSearchListTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func like(
        _ title: String?, artist: String = "Mr. G", release: String = "J's Credit EP",
        label: String? = "Bass Culture", position: String? = "B1", releaseID: Int = 1
    ) -> LikedTrack {
        LikedTrack(
            releaseID: releaseID, releaseTitle: release, artistName: artist,
            labelName: label, trackPosition: position, trackTitle: title,
            youtubeID: "abc", likedAt: generatedAt
        )
    }

    func testEachTrackIsACheckboxSearchLine() {
        let text = ObsidianRenderer.renderSearchList(
            likes: [like("Toi Toi")], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("- [ ] Mr. G - Toi Toi"))
    }

    func testTheRecordIsCarriedAsAFallback() {
        let text = ObsidianRenderer.renderSearchList(
            likes: [like("Toi Toi")], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("Platte: J's Credit EP · Bass Culture · B1"))
        XCTAssertTrue(text.contains("youtube.com/watch?v=abc"))
    }

    func testATitleThatAlreadyNamesTheArtistIsNotDoubled() {
        let text = ObsidianRenderer.renderSearchList(
            likes: [like("Mr. G - Toi Toi")], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("- [ ] Mr. G - Toi Toi"))
        XCTAssertFalse(text.contains("Mr. G - Mr. G"))
    }

    func testCatalogueBracketsAreStrippedForTheSearch() {
        let text = ObsidianRenderer.renderSearchList(
            likes: [like("Late Night (Enzo Siragusa Remix) [VL011]", artist: "Satoshi Tomiie")],
            generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("Late Night (Enzo Siragusa Remix)"))
        XCTAssertFalse(text.contains("[VL011]"))
    }

    func testATrackWithoutTitleStillGetsALine() {
        let text = ObsidianRenderer.renderSearchList(likes: [like(nil)], generatedAt: generatedAt)

        XCTAssertTrue(text.contains("ohne Titel"))
    }

    func testAnEmptyListSaysSo() {
        let text = ObsidianRenderer.renderSearchList(likes: [], generatedAt: generatedAt)

        XCTAssertTrue(text.contains("Noch nichts markiert"))
    }

    func testItPointsAtTheExistingLibraryNote() {
        let text = ObsidianRenderer.renderSearchList(likes: [], generatedAt: generatedAt)

        XCTAssertTrue(text.contains("[[Musiksammlung - Trackliste]]"))
    }
}

final class ObsidianRecordsTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func entry(
        _ id: Int, tracklist: [ReleaseTrack], kind: DecisionKind = .love
    ) -> LibraryEntry {
        LibraryEntry(
            release: ReleaseRecord(
                id: id, title: "J's Credit EP", artistName: "Mr. G", year: 2013,
                catno: "BCR035", labelID: 42, styles: [], want: 0, have: 0,
                hydrated: true, rating: 4.39, ratingCount: 69, tracklist: tracklist
            ),
            labelName: "Bass Culture", kind: kind,
            decidedAt: generatedAt, likedTrackCount: 0
        )
    }

    func testEveryTrackOfTheRecordIsListed() {
        let text = ObsidianRenderer.renderRecords(
            library: [entry(1, tracklist: [
                ReleaseTrack(position: "A1", title: "Let Down"),
                ReleaseTrack(position: "B1", title: "Toi Toi")
            ])],
            likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("### Mr. G — J's Credit EP"))
        XCTAssertTrue(text.contains("**A1** Let Down"))
        XCTAssertTrue(text.contains("**B1** Toi Toi"))
    }

    func testALikedTrackIsMarkedInsideTheTracklist() {
        let like = LikedTrack(
            releaseID: 1, releaseTitle: "J's Credit EP", artistName: "Mr. G",
            labelName: "Bass Culture", trackPosition: "B1", trackTitle: "Toi Toi",
            youtubeID: "abc", likedAt: generatedAt
        )
        let text = ObsidianRenderer.renderRecords(
            library: [entry(1, tracklist: [
                ReleaseTrack(position: "A1", title: "Let Down"),
                ReleaseTrack(position: "B1", title: "Toi Toi")
            ])],
            likes: [like], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("**B1** Toi Toi  ♥"))
        XCTAssertFalse(text.contains("Let Down  ♥"))
    }

    func testCatalogueAndRatingRideAlong() {
        let text = ObsidianRenderer.renderRecords(
            library: [entry(1, tracklist: [ReleaseTrack(position: "A1", title: "X")])],
            likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("BCR035"))
        XCTAssertTrue(text.contains("★ 4.39 (69)"))
        XCTAssertTrue(text.contains("discogs.com/release/1"))
    }

    func testARecordWithoutATracklistSaysSoRatherThanLookingEmpty() {
        let text = ObsidianRenderer.renderRecords(
            library: [entry(1, tracklist: [])], likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("Trackliste noch nicht geladen"))
    }

    func testOnlyWantlistRecordsAppear() {
        let text = ObsidianRenderer.renderRecords(
            library: [entry(9, tracklist: [], kind: .discard)],
            likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("Noch nichts auf der Wantlist"))
    }

    func testRecordsAreGroupedByLabel() {
        let text = ObsidianRenderer.renderRecords(
            library: [entry(1, tracklist: [])], likes: [], generatedAt: generatedAt
        )

        XCTAssertTrue(text.contains("## Bass Culture"))
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

    func testWritesTheNoteItWasAskedFor() async throws {
        let writer = ObsidianWriter(directory: directory)

        try await writer.write("# Tracks", to: .searchList)

        let text = try String(
            contentsOf: directory.appendingPathComponent("Vinyl - Gesuchte Tracks.md")
        )
        XCTAssertTrue(text.contains("# Tracks"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Vinylsammlung.md").path
            ),
            "the other note must not be touched"
        )
    }

    func testSecondWriteKeepsHandWrittenPart() async throws {
        let writer = ObsidianWriter(directory: directory)
        try await writer.write("# Eins", to: .records)

        let path = directory.appendingPathComponent("Vinylsammlung.md")
        var content = try String(contentsOf: path)
        content += "\nVon Hand ergänzt.\n"
        try content.write(to: path, atomically: true, encoding: .utf8)

        try await writer.write("# Zwei", to: .records)

        let after = try String(contentsOf: path)
        XCTAssertTrue(after.contains("# Zwei"))
        XCTAssertTrue(after.contains("Von Hand ergänzt."))
        XCTAssertFalse(after.contains("# Eins"))
    }

    func testMissingDirectoryThrows() async {
        let writer = ObsidianWriter(directory: directory.appendingPathComponent("fehlt"))

        do {
            try await writer.write("x", to: .records)
            XCTFail("expected a throw")
        } catch {}
    }
}
