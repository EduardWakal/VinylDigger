import XCTest
import GRDB
@testable import VinylDiggerKit

final class ExportCursorTests: XCTestCase {
    func testTheCursorIsAbsentUntilSomethingIsExported() throws {
        let db = try AppDatabase.inMemory()
        let loaded = try db.read {
            try ExportCursorRecord.fetchOne($0, key: ExportCursorRecord.singletonID)
        }
        XCTAssertNil(loaded)
    }

    func testSavingTheCursorTwiceKeepsOneRow() throws {
        let db = try AppDatabase.inMemory()
        try db.write { database in
            var first = ExportCursorRecord(lastExportedAt: Date(timeIntervalSince1970: 1_000))
            try first.save(database)
            var second = ExportCursorRecord(lastExportedAt: Date(timeIntervalSince1970: 2_000))
            try second.save(database)
        }
        let all = try db.read { try ExportCursorRecord.fetchAll($0) }
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].lastExportedAt, Date(timeIntervalSince1970: 2_000))
    }
}
