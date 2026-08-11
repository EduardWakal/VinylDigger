# Dig-Session-Export und fester Transport — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Der Obsidian-Export schreibt je Grabungsrunde eine eigene Notiz mit genau den seither markierten Tracks, und der Transport wird Teil des Fensterrahmens statt Teil des ersten Tabs.

**Architecture:** Ein Singleton-Cursor in der Datenbank hält fest, wann zuletzt exportiert wurde; eine Session ist alles, was seither markiert wurde und nicht auf einer Platte der eigenen Sammlung liegt. `ObsidianDocument` trägt für den Session-Fall ein Datum und wird damit zu einem Enum mit assoziiertem Wert; der Writer löst einen freien Dateinamen auf. In der App zieht `TransportView` aus `QueueView` heraus unter die `TabView`.

**Tech Stack:** Swift 5.9+, SwiftUI, GRDB (SQLite), XCTest. Paket `VinylDiggerKit`, App-Target `VinylDigger`.

## Global Constraints

- Deployment-Target ist `.macOS(.v14)` — keine API und kein SF Symbol, das erst mit macOS 15 / SF Symbols 6 kam.
- Sichtbare Texte sind deutsch, Codekommentare englisch, und Kommentare nur wo die Logik nicht selbsterklärend ist.
- Kein `var` in JavaScript; hier nicht relevant, aber die Regel steht.
- Kit-Tests laufen mit `swift test --package-path VinylDiggerKit`, gefiltert mit `--filter <Klassenname>`.
- App-Build läuft mit `xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build`.
- Die App-Schicht (`App/*.swift`) hat kein Testziel. Was dort geändert wird, wird per Build und Lauf geprüft, nicht per Test.
- Spec: `docs/superpowers/specs/2026-08-11-session-export-design.md`.

## Dateien im Überblick

| Datei | Verantwortung | Task |
|---|---|---|
| `VinylDiggerKit/Sources/VinylDiggerKit/Store/Records.swift` | `ExportCursorRecord` | 1 |
| `VinylDiggerKit/Sources/VinylDiggerKit/Store/AppDatabase.swift` | Migration `v13` | 1 |
| `VinylDiggerKit/Sources/VinylDiggerKit/Session/Library.swift` | `digSession(until:)`, Cursor lesen und setzen | 2 |
| `VinylDiggerKit/Sources/VinylDiggerKit/Obsidian/ObsidianExport.swift` | `ObsidianDocument`, `renderDigSession`, freier Dateiname | 3 |
| `VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift` | Tests zu Task 1 und 2 | 1, 2 |
| `VinylDiggerKit/Tests/VinylDiggerKitTests/ObsidianTests.swift` | Tests zu Task 3 | 3 |
| `App/AppEnvironment.swift` | Export-Ablauf, `likeCurrentlyPlaying` | 4, 5 |
| `App/StatsView.swift` | Knopf mit Zähler | 4 |
| `App/TransportView.swift` (neu) | die Leiste, aus `QueueView` gelöst | 5 |
| `App/QueueView.swift` | verliert die Leiste | 5 |
| `App/RootView.swift` | mountet die Leiste, benennt Tab 1 um | 5 |

Task 3 fasst Enum, Renderer und Writer zusammen, weil `ObsidianWriter` heute `document.rawValue` liest — der RawValue fällt weg, also übersetzt sich das nicht getrennt.

---

### Task 1: Der Export-Cursor

**Files:**
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Store/Records.swift` (ans Ende, hinter `DiscoveryCursorRecord` bei Zeile 326)
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Store/AppDatabase.swift` (hinter Migration `v12`, vor `return migrator`)
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift` (neu)

**Interfaces:**
- Consumes: `AppDatabase.inMemory()`, GRDB `MutablePersistableRecord`
- Produces: `ExportCursorRecord(lastExportedAt: Date)` mit `static let singletonID = 1`, `static let databaseTableName = "export_cursor"`, Tabelle `export_cursor(id INTEGER PRIMARY KEY, lastExportedAt DATETIME NOT NULL)`

- [ ] **Step 1: Write the failing test**

Neue Datei `VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path VinylDiggerKit --filter ExportCursorTests`
Expected: FAIL beim Übersetzen mit „cannot find 'ExportCursorRecord' in scope".

- [ ] **Step 3: Add the record**

Ans Ende von `Store/Records.swift`:

```swift
/// When the last dig session was written to the vault. A session is everything
/// marked since — there is no session object, the export itself is the cut.
public struct ExportCursorRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "export_cursor"
    public static let singletonID = 1

    public var id: Int
    public var lastExportedAt: Date

    public init(id: Int = ExportCursorRecord.singletonID, lastExportedAt: Date) {
        self.id = id
        self.lastExportedAt = lastExportedAt
    }
}
```

- [ ] **Step 4: Add the migration**

In `Store/AppDatabase.swift`, hinter dem `v12`-Block und vor `return migrator`:

```swift
        migrator.registerMigration("v13") { db in
            try db.create(table: "export_cursor") { t in
                t.primaryKey("id", .integer)
                t.column("lastExportedAt", .datetime).notNull()
            }
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path VinylDiggerKit --filter ExportCursorTests`
Expected: PASS, beide Tests.

- [ ] **Step 6: Run the whole kit suite**

Run: `swift test --package-path VinylDiggerKit`
Expected: PASS. Eine neue Migration darf keinen bestehenden Test brechen.

- [ ] **Step 7: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Store/Records.swift \
        VinylDiggerKit/Sources/VinylDiggerKit/Store/AppDatabase.swift \
        VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift
git commit -m "feat: remember when the last dig session was exported"
```

---

### Task 2: Die Session-Auswahl

**Files:**
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Session/Library.swift:112-145` (`likedTracks`)
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift` (zweite Klasse anhängen)

**Interfaces:**
- Consumes: `ExportCursorRecord` aus Task 1; `LikedTrack`, `TrackLikeRecord`, `ReleaseRecord`, `VideoRecord`, `LabelRecord`
- Produces:
  - `QueueService.digSession(until: Date) throws -> [LikedTrack]` (nonisolated)
  - `QueueService.markExported(at: Date) throws` (nonisolated)
  - `QueueService.likedTracks() throws -> [LikedTrack]` bleibt unverändert im Verhalten

Die Auswahlregeln, in dieser Reihenfolge: kein Release mit `owned == true`; `likedAt <= until`; und falls ein Cursor existiert, `likedAt > cursor.lastExportedAt`. Sortierung `likedAt` absteigend, wie bei `likedTracks()`.

- [ ] **Step 1: Write the failing tests**

An `DigSessionTests.swift` anhängen:

```swift
final class DigSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeService() throws -> (QueueService, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        try secrets.write("tok", for: .discogsToken)
        let client = DiscogsClient(
            transport: StubTransport(replies: []), secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
        let outbox = OutboxProcessor(
            database: db, writer: client, username: "schakal", now: { self.now }
        )
        let service = QueueService(
            database: db, client: client, outbox: outbox,
            username: "schakal", now: { self.now }
        )
        return (service, db)
    }

    /// Two releases, one owned, each with one video, plus a like on each.
    private func seed(_ db: AppDatabase, likedAt: Date, ownedLikedAt: Date) throws {
        try db.write { database in
            var wanted = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: nil, styles: ["Deep House"],
                want: 582, have: 517, hydrated: true, owned: false
            )
            try wanted.save(database)
            var shelved = ReleaseRecord(
                id: 4242, title: "Im Regal", artistName: "Mr. G",
                year: 2001, catno: "PH01", labelID: nil, styles: ["House"],
                want: 10, have: 900, hydrated: true, owned: true
            )
            try shelved.save(database)

            for (releaseID, youtubeID) in [(2831, "aaa"), (4242, "bbb")] {
                var video = VideoRecord(
                    id: nil, releaseID: releaseID, youtubeID: youtubeID, title: "Track",
                    position: 0, unavailable: false, duration: 300, trackPosition: "A1"
                )
                try video.insert(database)
            }

            var like = TrackLikeRecord(
                id: nil, releaseID: 2831, youtubeID: "aaa", likedAt: likedAt
            )
            try like.insert(database)
            var ownedLike = TrackLikeRecord(
                id: nil, releaseID: 4242, youtubeID: "bbb", likedAt: ownedLikedAt
            )
            try ownedLike.insert(database)
        }
    }

    func testWithoutACursorEverythingCounts() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)

        let session = try service.digSession(until: now.addingTimeInterval(60))

        XCTAssertEqual(session.map(\.youtubeID), ["aaa"], "the owned record must not be searched for")
    }

    func testOnlyWhatWasMarkedAfterTheCursorCounts() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)
        try service.markExported(at: now.addingTimeInterval(10))

        XCTAssertTrue(try service.digSession(until: now.addingTimeInterval(60)).isEmpty)

        try db.write { database in
            var later = TrackLikeRecord(
                id: nil, releaseID: 2831, youtubeID: "ccc",
                likedAt: now.addingTimeInterval(20)
            )
            try later.insert(database)
        }

        let session = try service.digSession(until: now.addingTimeInterval(60))
        XCTAssertEqual(session.map(\.youtubeID), ["ccc"])
    }

    func testALikeSetAfterTheCutoffIsLeftForTheNextSession() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now.addingTimeInterval(100), ownedLikedAt: now)

        XCTAssertTrue(try service.digSession(until: now.addingTimeInterval(50)).isEmpty)
        XCTAssertEqual(
            try service.digSession(until: now.addingTimeInterval(200)).map(\.youtubeID), ["aaa"]
        )
    }

    func testTheFullListStillCarriesEverything() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)
        try service.markExported(at: now.addingTimeInterval(10))

        XCTAssertEqual(try service.likedTracks().count, 2, "renderRecords needs all of them")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path VinylDiggerKit --filter DigSessionTests`
Expected: FAIL beim Übersetzen mit „value of type 'QueueService' has no member 'digSession'".

- [ ] **Step 3: Refactor likedTracks onto a shared body**

In `Session/Library.swift` `likedTracks()` (Zeile 112) durch dieses Trio ersetzen. Die Zusammenstellung eines `LikedTrack` steht danach genau einmal da:

```swift
    public nonisolated func likedTracks() throws -> [LikedTrack] {
        try database.read { db in try Self.likedTracks(in: db) { _, _ in true } }
    }

    /// The tracks of one dig session: everything marked since the last export that
    /// is not already on a record in the collection. `until` is the stamp the
    /// export runs with — without it a like set while the note is being written
    /// would be overtaken by the advancing cursor and never exported.
    public nonisolated func digSession(until: Date) throws -> [LikedTrack] {
        try database.read { db in
            let since = try ExportCursorRecord
                .fetchOne(db, key: ExportCursorRecord.singletonID)?
                .lastExportedAt

            return try Self.likedTracks(in: db) { like, release in
                guard !release.owned, like.likedAt <= until else { return false }
                guard let since else { return true }
                return like.likedAt > since
            }
        }
    }

    public nonisolated func markExported(at stamp: Date) throws {
        try database.write { db in
            var record = ExportCursorRecord(lastExportedAt: stamp)
            try record.save(db)
        }
    }

    private static func likedTracks(
        in db: Database, where include: (TrackLikeRecord, ReleaseRecord) -> Bool
    ) throws -> [LikedTrack] {
        let labelNames = Dictionary(
            try LabelRecord.fetchAll(db).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        return try TrackLikeRecord
            .order(Column("likedAt").desc)
            .fetchAll(db)
            .compactMap { like in
                guard
                    let release = try ReleaseRecord.fetchOne(db, key: like.releaseID),
                    include(like, release)
                else { return nil }

                let video = try VideoRecord
                    .filter(
                        Column("releaseID") == like.releaseID
                        && Column("youtubeID") == like.youtubeID
                    )
                    .fetchOne(db)

                return LikedTrack(
                    releaseID: release.id,
                    releaseTitle: release.title,
                    artistName: release.artistName,
                    labelName: release.labelID.flatMap { labelNames[$0] },
                    trackPosition: video?.trackPosition,
                    trackTitle: video?.title,
                    youtubeID: like.youtubeID,
                    likedAt: like.likedAt
                )
            }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path VinylDiggerKit --filter DigSessionTests`
Expected: PASS, alle vier Tests.

- [ ] **Step 5: Run the whole kit suite**

Run: `swift test --package-path VinylDiggerKit`
Expected: PASS. `likedTracks()` wurde umgebaut, also müssen `TrackLikeTests` und `ObsidianTests` unverändert grün bleiben.

- [ ] **Step 6: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Session/Library.swift \
        VinylDiggerKit/Tests/VinylDiggerKitTests/DigSessionTests.swift
git commit -m "feat: select the tracks of one dig session"
```

---

### Task 3: Notiz je Session statt einer wachsenden Liste

**Files:**
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Obsidian/ObsidianExport.swift` (Enum bei Zeile 4, `renderSearchList` bei Zeile 19, `format` bei Zeile 134, `ObsidianWriter.write` bei Zeile 158)
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/ObsidianTests.swift`

**Interfaces:**
- Consumes: `LikedTrack`, `ObsidianRenderer.merge`, `ObsidianRenderer.handMarker`
- Produces:
  - `ObsidianDocument.digSession(Date)` und `.records`, beide mit `var filename: String` und `var overwrites: Bool`; **kein** RawValue und **kein** `CaseIterable` mehr
  - `ObsidianRenderer.renderDigSession(likes: [LikedTrack], generatedAt: Date) -> String` ersetzt `renderSearchList`
  - `ObsidianWriter.write(_ rendered: String, to document: ObsidianDocument) throws -> URL` (`@discardableResult`)

- [ ] **Step 1: Write the failing tests**

In `ObsidianTests.swift`: in `ObsidianSearchListTests` jeden Aufruf `ObsidianRenderer.renderSearchList(` durch `ObsidianRenderer.renderDigSession(` ersetzen (sieben Stellen: Zeilen 19, 27, 36, 45, 55, 61, 67) und die Klasse in `ObsidianDigSessionTests` umbenennen. Dann diesen Test in dieselbe Klasse aufnehmen:

```swift
    func testTheHeaderNamesTheSession() {
        let text = ObsidianRenderer.renderDigSession(
            likes: [like("Toi Toi")], generatedAt: generatedAt
        )
        XCTAssertTrue(text.contains("# Vinyl — Dig-Session"))
        XCTAssertTrue(text.contains("Session vom 2026-02-01 · 1 Tracks"))
    }
```

In `ObsidianWriterTests` den Test `testWritesTheNoteItWasAskedFor` (Zeile 212) durch diese drei ersetzen:

```swift
    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    func testASessionGetsItsOwnDatedNote() async throws {
        let writer = ObsidianWriter(directory: directory)

        let url = try await writer.write("# Tracks", to: .digSession(day))

        XCTAssertEqual(url.lastPathComponent, "Vinyl - Dig 2026-02-01.md")
        XCTAssertTrue(try String(contentsOf: url).contains("# Tracks"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Vinylsammlung.md").path
            ),
            "the other note must not be touched"
        )
    }

    func testASecondSessionTheSameDayDoesNotOverwriteTheFirst() async throws {
        let writer = ObsidianWriter(directory: directory)

        let first = try await writer.write("# Eins", to: .digSession(day))
        let second = try await writer.write("# Zwei", to: .digSession(day))
        let third = try await writer.write("# Drei", to: .digSession(day))

        XCTAssertEqual(first.lastPathComponent, "Vinyl - Dig 2026-02-01.md")
        XCTAssertEqual(second.lastPathComponent, "Vinyl - Dig 2026-02-01 (2).md")
        XCTAssertEqual(third.lastPathComponent, "Vinyl - Dig 2026-02-01 (3).md")
        XCTAssertTrue(try String(contentsOf: first).contains("# Eins"))
        XCTAssertTrue(try String(contentsOf: second).contains("# Zwei"))
    }

    func testTheRecordNoteIsStillOverwritten() async throws {
        let writer = ObsidianWriter(directory: directory)

        let first = try await writer.write("# Eins", to: .records)
        let second = try await writer.write("# Zwei", to: .records)

        XCTAssertEqual(first, second)
        XCTAssertTrue(try String(contentsOf: second).contains("# Zwei"))
        XCTAssertFalse(try String(contentsOf: second).contains("# Eins"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path VinylDiggerKit --filter Obsidian`
Expected: FAIL beim Übersetzen mit „type 'ObsidianDocument' has no member 'digSession'".

- [ ] **Step 3: Rework the document type**

In `Obsidian/ObsidianExport.swift` das Enum an Zeile 4 ersetzen:

```swift
public enum ObsidianDocument: Sendable, Equatable {
    /// One dig session: the tracks marked since the last export, as a Soulseek
    /// shopping list.
    case digSession(Date)
    /// What is on each record, for when one has actually been bought.
    case records

    public var filename: String {
        switch self {
        case .digSession(let date): return "Vinyl - Dig \(ObsidianRenderer.format(date)).md"
        case .records: return "Vinylsammlung.md"
        }
    }

    /// A session note is the snapshot of one round, so a second export on the same
    /// day is filed beside the first rather than replacing it.
    public var overwrites: Bool {
        switch self {
        case .digSession: return false
        case .records: return true
        }
    }
}
```

- [ ] **Step 4: Open up the date formatter and rename the renderer**

In derselben Datei `private static func format(_ date: Date)` (Zeile 134) zu `fileprivate static func format(_ date: Date)` ändern — `private` wäre für `ObsidianDocument` nicht sichtbar, `fileprivate` reicht, weil beide Typen in dieser Datei stehen.

`renderSearchList` (Zeile 19) zu `renderDigSession` umbenennen und die ersten beiden Kopfzeilen austauschen:

```swift
    public static func renderDigSession(likes: [LikedTrack], generatedAt: Date) -> String {
        var lines = [
            "# Vinyl — Dig-Session",
            "",
            "Beim Hören markierte Tracks, als Suchzeilen für Nicotine+. Findet die Suche "
                + "den Track nicht, hilft meist der Plattenname darunter.",
            "",
            "Session vom \(format(generatedAt)) · \(likes.count) Tracks · Ablauf siehe [[Ablauf]].",
            "",
            "Schon in der Library? Gegenprüfen in [[Musiksammlung - Trackliste]].",
            ""
        ]
```

Der Rest der Funktion ab `if likes.isEmpty` bleibt unangetastet.

- [ ] **Step 5: Let the writer resolve a free name**

`ObsidianWriter.write` (Zeile 158) ersetzen und die Hilfsfunktion daneben legen:

```swift
    @discardableResult
    public func write(_ rendered: String, to document: ObsidianDocument) throws -> URL {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WriterError.directoryMissing(directory.path)
        }

        let target = document.overwrites
            ? directory.appendingPathComponent(document.filename)
            : freeName(for: document.filename)
        let existing = try? String(contentsOf: target, encoding: .utf8)
        let merged = ObsidianRenderer.merge(rendered: rendered, into: existing)
        try merged.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private func freeName(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path VinylDiggerKit --filter Obsidian`
Expected: PASS. Erwartet wird auch, dass `2026-02-01` herauskommt — `format` rechnet in `Europe/Berlin`, und `1_770_000_000` ist dort der 1. Februar 2026.

- [ ] **Step 7: Run the whole kit suite**

Run: `swift test --package-path VinylDiggerKit`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Obsidian/ObsidianExport.swift \
        VinylDiggerKit/Tests/VinylDiggerKitTests/ObsidianTests.swift
git commit -m "feat: write one dated note per dig session"
```

---

### Task 4: Der Export in der App

Ab hier gibt es keine Tests mehr — die App-Schicht hat kein Testziel. Geprüft wird per Build und per Lauf.

**Files:**
- Modify: `App/AppEnvironment.swift:374-400` (`exportToObsidian`)
- Modify: `App/StatsView.swift:7-9` (State), `:69-85` (Toolbar), `:112-118` (`reload`)

**Interfaces:**
- Consumes: `QueueService.digSession(until:)`, `QueueService.markExported(at:)`, `ObsidianRenderer.renderDigSession`, `ObsidianDocument.digSession(_:)`, `ObsidianWriter.write` (gibt URL zurück) — alles aus Task 2 und 3
- Produces:
  - `AppEnvironment.exportDigSession() async`
  - `AppEnvironment.exportRecords() async`
  - `AppEnvironment.openDigSessionCount() -> Int`
  - `AppEnvironment.exportToObsidian(_:)` entfällt

- [ ] **Step 1: Replace the export method**

In `App/AppEnvironment.swift` im Abschnitt `// MARK: - Obsidian` die Funktion `exportToObsidian` samt ihrem Doc-Kommentar durch diese drei ersetzen:

```swift
    /// Two notes for two jobs: the session list is what gets taken to Soulseek, the
    /// record list is what is on a record once it is bought.
    ///
    /// The cursor moves only after the note is on disk. A failed write therefore
    /// leaves the tracks in the next session rather than dropping them.
    func exportDigSession() async {
        guard let service else {
            status = "Noch keine Verbindung — Token prüfen"
            return
        }
        do {
            let now = Date()
            let likes = try service.digSession(until: now)
            guard !likes.isEmpty else {
                status = "nichts Neues seit dem letzten Export"
                return
            }
            let text = ObsidianRenderer.renderDigSession(likes: likes, generatedAt: now)
            let url = try await ObsidianWriter(directory: ObsidianWriter.defaultDirectory)
                .write(text, to: .digSession(now))
            try service.markExported(at: now)
            status = "\(url.lastPathComponent) · \(likes.count) Tracks"
        } catch {
            status = "Obsidian: \(error)"
        }
    }

    func exportRecords() async {
        guard let service else {
            status = "Noch keine Verbindung — Token prüfen"
            return
        }
        do {
            let text = ObsidianRenderer.renderRecords(
                library: try service.library(kind: nil),
                likes: try service.likedTracks(),
                generatedAt: Date()
            )
            let url = try await ObsidianWriter(directory: ObsidianWriter.defaultDirectory)
                .write(text, to: .records)
            status = "\(url.lastPathComponent) geschrieben"
        } catch {
            status = "Obsidian: \(error)"
        }
    }

    /// How many marked tracks the next session would carry. Drives the label on
    /// the export button, so it is answered from the database on every reload.
    func openDigSessionCount() -> Int {
        guard let service else { return 0 }
        return (try? service.digSession(until: Date()))?.count ?? 0
    }
```

- [ ] **Step 2: Wire the buttons**

In `App/StatsView.swift` neben die bestehenden `@State`-Zeilen setzen:

```swift
    @State private var openTracks = 0
```

Die beiden Export-Knöpfe in `toolbar` ersetzen:

```swift
            Button {
                Task {
                    await environment.exportDigSession()
                    reload()
                }
            } label: {
                Label("Dig-Session (\(openTracks))", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(openTracks == 0)
            .help("Die seit dem letzten Export markierten Tracks als eigene Notiz in den Vault")

            Button {
                Task { await environment.exportRecords() }
            } label: {
                Label("Platten + Tracklisten", systemImage: "arrow.up.doc.on.clipboard")
            }
            .help("Wantlist mit vollständiger Trackliste je Platte in den Vault")
```

In `reload()` die letzte Zeile ergänzen:

```swift
    private func reload() {
        let weights = environment.nodeWeights()
        artists = weights.artists
        labels = weights.labels
        likes = environment.likedTracks()
        openTracks = environment.openDigSessionCount()
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. Bleibt irgendwo ein Aufruf von `exportToObsidian` oder `renderSearchList` stehen, bricht genau hier der Übersetzer ab.

- [ ] **Step 4: Commit**

```bash
git add App/AppEnvironment.swift App/StatsView.swift
git commit -m "feat: export one dig session at a time"
```

---

### Task 5: Transport gehört dem Fenster

**Files:**
- Create: `App/TransportView.swift`
- Modify: `App/QueueView.swift` (`TransportView` samt Divider aus `body` entfernen, `private struct TransportView` ab Zeile 196 herausschneiden)
- Modify: `App/RootView.swift`
- Modify: `App/AppEnvironment.swift:202-206` (`likeCurrentlyPlaying`)

**Interfaces:**
- Consumes: `PlayerController` (`isPlaying`, `position`, `duration`, `hasLoadedVideo`, `currentTrackLabel`, `contextLabel`, `isScrubbing`, `togglePlayPause()`, `seek(to:)`, `seek(by:)`, `restart()`, `nextVideo()`), `AppEnvironment.likeCurrentlyPlaying()`
- Produces: `TransportView(player:onLikeCurrent:)` als internes `struct` in eigener Datei

- [ ] **Step 1: Move the bar into its own file**

Neue Datei `App/TransportView.swift`. Aus `App/QueueView.swift` das gesamte `private struct TransportView` (ab dem Doc-Kommentar „Der Transport. Sitzt below…", Zeilen 194–291) und die freie Funktion `formatSeconds` (Zeilen 332–336) herausschneiden und hier ablegen. Kopf der neuen Datei:

```swift
import SwiftUI
import VinylDiggerKit

/// The transport. Belongs to the window, not to a tab: a record started in the
/// discovery tab has to stay steerable from every other tab.
struct TransportView: View {
    @ObservedObject var player: PlayerController
    let onLikeCurrent: () -> Void
```

Der Rumpf ab `@State private var scrub: TimeInterval = 0` wird unverändert übernommen. `formatSeconds` bleibt eine freie `private func` am Ende dieser neuen Datei.

Achtung: `TrackList` in `QueueView.swift` und `CoverView` rufen `formatSeconds` ebenfalls auf. Weil `private` auf oberster Ebene dateiweit gilt, braucht `QueueView.swift` eine eigene Kopie. Deshalb: in `QueueView.swift` `formatSeconds` **stehen lassen** und in `TransportView.swift` eine zweite `private func formatSeconds` mit gleichem Rumpf anlegen. Zwei vier Zeilen lange private Helfer sind billiger als ein neuer geteilter Typ.

- [ ] **Step 2: Take the bar out of the queue view**

In `App/QueueView.swift` im `body` diese drei Zeilen streichen:

```swift
            Divider()
            TransportView(player: environment.player) {
                environment.likeCurrentlyPlaying()
            }
```

Der `Divider()` vor `controls` bleibt stehen.

- [ ] **Step 3: Mount the bar under the tabs**

`App/RootView.swift` — den `body` so umbauen, dass `TabView` und Leiste in einem `VStack` sitzen:

```swift
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                QueueView()
                    .tabItem { Label("Digliste", systemImage: "play.circle") }
                    .tag(0)

                DiscoveryView()
                    .tabItem { Label("Entdecken", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(3)

                LibraryView()
                    .tabItem { Label("Sammlung", systemImage: "square.stack") }
                    .tag(1)

                StatsView()
                    .tabItem { Label("Statistik", systemImage: "chart.bar") }
                    .tag(2)
            }

            Divider()

            TransportView(player: environment.player) {
                environment.likeCurrentlyPlaying()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        // Mounted once on the window, not inside a single tab: macOS unmounts an
        // unselected tab's views entirely, and a WKWebView outside the hierarchy
        // does not reliably keep playing.
        .background(PlayerHost(controller: environment.player).frame(width: 1, height: 1))
        .frame(minWidth: 720, minHeight: 720)
        // The environment stays the channel the library uses to send a record over
        // to the player, so the two selections are kept level in both directions.
        .onChange(of: environment.selectedTab) { _, requested in tab = requested }
        .onChange(of: tab) { _, selected in environment.selectedTab = selected }
    }
```

- [ ] **Step 4: Let the heart find records outside the queue**

In `App/AppEnvironment.swift` `likeCurrentlyPlaying` ersetzen:

```swift
    /// Marks whatever is playing, which is not always a track of the card on screen
    /// — and not always a card of the queue either, now that the transport sits
    /// under every tab.
    func likeCurrentlyPlaying() {
        guard let id = player.currentVideoID else { return }
        let pools = [cards, discoveryCards, inspected.map { [$0] } ?? []]
        guard
            let card = pools.lazy.compactMap({ pool in
                pool.first { $0.videoIDs.contains(id) }
            }).first
        else { return }
        toggleLike(releaseID: card.releaseID, youtubeID: id)
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Check it in the running app**

App starten. Fünf Dinge prüfen, in dieser Reihenfolge:

1. Die Leiste steht unter allen vier Tabs und verschwindet beim Wechseln nicht.
2. Im Tab Entdecken „Nachladen" drücken, eine Spur anklicken, zum Tab Sammlung wechseln — es läuft weiter, Pause und Slider greifen.
3. Das Herz in der Leiste bei einer laufenden Entdecken-Spur drücken; im Tab Statistik muss die Spur unter „Gemochte Tracks" auftauchen.
4. Der erste Tab heißt „Digliste".
5. In der Statistik-Toolbar zeigt der Knopf eine Zahl; nach dem Export steht `(0)` da, er ist ausgegraut, und im Vault liegt `Vinyl - Dig <heute>.md` mit genau den Tracks der Runde.

- [ ] **Step 7: Commit**

```bash
git add App/TransportView.swift App/QueueView.swift App/RootView.swift App/AppEnvironment.swift
git commit -m "feat: pin the transport under every tab"
```

---

### Task 6: Plan und Spec nachziehen

**Files:**
- Modify: `docs/superpowers/specs/2026-08-11-session-export-design.md`

- [ ] **Step 1: Note what the implementation changed**

Falls Task 1–5 vom Spec abgewichen sind — andere Signatur, anderer Dateiname, ein Fall der im Spec fehlte —, den Spec an der betroffenen Stelle korrigieren. Ist nichts abgewichen, nur den Status im Kopf von „Entwurf, wartet auf Freigabe" auf „umgesetzt" setzen.

Zwei Punkte, die auf jeden Fall gehören: `exportToObsidian(_:)` ist im Spec noch als eine Methode beschrieben, wurde aber zu `exportDigSession()` und `exportRecords()` geteilt, weil `.digSession` ein Datum trägt, das die Ansicht nicht erfinden soll. Und `formatSeconds` liegt jetzt doppelt vor, in `QueueView.swift` und `TransportView.swift`.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-11-session-export-design.md
git commit -m "docs: record how the dig session export was built"
```
