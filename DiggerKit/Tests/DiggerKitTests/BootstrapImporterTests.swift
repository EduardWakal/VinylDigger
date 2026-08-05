import XCTest
import GRDB
@testable import DiggerKit

final class BootstrapImporterTests: XCTestCase {
    private func runImport() throws -> (AppDatabase, BootstrapSummary) {
        let db = try AppDatabase.inMemory()
        let importer = BootstrapImporter(database: db)
        let summary = try importer.importDumps(
            profile: try loadFixture("dig_profile"),
            labels: try loadFixture("dig_labels")
        )
        return (db, summary)
    }

    func testImportsSeedArtistsWithFullWeight() throws {
        let (db, summary) = try runImport()

        XCTAssertEqual(summary.artists, 4)
        let finlow = try db.read { try ArtistRecord.fetchOne($0, key: 13320) }
        XCTAssertEqual(finlow?.name, "Carl A. Finlow")
        XCTAssertEqual(finlow?.weight, 1.0)
    }

    func testImportsLabelsWithIDs() throws {
        let (db, summary) = try runImport()

        XCTAssertGreaterThanOrEqual(summary.labels, 6)
        let vision = try db.read { try LabelRecord.fetchOne($0, key: 15) }
        XCTAssertEqual(vision?.name, "20:20 Vision")
    }

    func testImportsReleasesAsHydrated() throws {
        let (db, _) = try runImport()

        let release = try db.read { try ReleaseRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(release?.title, "Fresh Connections")
        XCTAssertEqual(release?.artistName, "Inland Knights")
        XCTAssertEqual(release?.catno, "VIS035")
        XCTAssertEqual(release?.want, 582)
        XCTAssertEqual(release?.labelID, 15)
        XCTAssertTrue(release?.hydrated == true)
    }

    func testImportsVideosAsYouTubeIDs() throws {
        let (db, _) = try runImport()

        let videos = try db.read { db in
            try VideoRecord.filter(Column("releaseID") == 2831).order(Column("position")).fetchAll(db)
        }
        XCTAssertFalse(videos.isEmpty)
        XCTAssertEqual(videos[0].youtubeID, "cqRa3O8xQNQ")
        XCTAssertFalse(videos[0].unavailable)
    }

    func testCreatesArtistToLabelEdgesForSeeds() throws {
        let (db, _) = try runImport()

        let edges = try db.read { db in
            try EdgeRecord
                .filter(Column("fromID") == 13320 && Column("kind") == EdgeKind.artistToLabel.rawValue)
                .fetchAll(db)
        }
        XCTAssertTrue(edges.contains { $0.toID == 15 }, "Finlow must link to 20:20 Vision")
    }

    func testImportIsIdempotent() throws {
        let db = try AppDatabase.inMemory()
        let importer = BootstrapImporter(database: db)
        let profile = try loadFixture("dig_profile")
        let labels = try loadFixture("dig_labels")

        let first = try importer.importDumps(profile: profile, labels: labels)
        let second = try importer.importDumps(profile: profile, labels: labels)

        XCTAssertEqual(first, second)
        let artistCount = try db.read { try ArtistRecord.fetchCount($0) }
        XCTAssertEqual(artistCount, first.artists)
    }

    func testSkipsDuplicateReleaseIDsAcrossLabels() throws {
        let (db, summary) = try runImport()

        let releaseCount = try db.read { try ReleaseRecord.fetchCount($0) }
        XCTAssertEqual(releaseCount, summary.releases)
    }
}
