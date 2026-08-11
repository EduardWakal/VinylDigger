# Discovery über Style-Charts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein zweiter Einspeise-Pfad für Platten — die meistgesuchten Vinyls je Style aus der Discogs-Suche, in einem eigenen Tab, unabhängig vom Geschmacksgraphen.

**Architecture:** Eine neue Client-Methode holt Suchtreffer nach Style und Zeitfenster, sortiert nach `want`, gefiltert gegen genre-fremde Styles. Eine rein rechnende Rotation bestimmt, welcher Style-Zeitfenster-Seite als nächstes dran ist. Ein eigener Ranker bewertet den Batch ohne den affinitätsbasierten `Scorer`, ein eigener Service schreibt das Ergebnis in zwei neue Tabellen. Die Oberfläche bekommt einen vierten Tab, der das Kartenlayout des Players wiederverwendet.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, XCTest, XcodeGen. macOS 14.

**Spec:** [docs/superpowers/specs/2026-08-10-discovery-design.md](../specs/2026-08-10-discovery-design.md)

## Global Constraints

- Sprache im Code: Englisch. Nutzersichtbare Texte: Deutsch — wie im gesamten Bestand.
- Kommentare nur, wo die Logik nicht selbsterklärend ist, und dann auf Englisch.
- Kein `var` in JavaScript-Kontexten — hier irrelevant, das Projekt ist reines Swift.
- Tests laufen mit `cd VinylDiggerKit && swift test`.
- App baut mit `xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build`.
- Neue Dateien unter `App/` werden von XcodeGen über den Ordner-Glob erfasst; nach dem Anlegen `xcodegen generate` laufen lassen.
- Discogs-Rate-Limit: 60 Aufrufe pro Minute. Ein Discovery-Refresh darf genau einen Suchaufruf kosten.
- Alle Discogs-Modelle sind `Sendable`; `DiscoveryService` ist ein `actor` wie `QueueService`.
- Migrationen werden angehängt, nie bestehende geändert. Nächste freie Nummer: `v11`.

## Dateien

| Datei | Verantwortung |
|---|---|
| `VinylDiggerKit/Sources/VinylDiggerKit/DiscogsAPI/DiscogsModels.swift` | ergänzt um `DiscogsSearchHit` |
| `VinylDiggerKit/Sources/VinylDiggerKit/DiscogsAPI/DiscogsClient.swift` | ergänzt um `searchByStyle` |
| `VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryAxis.swift` | neu — Zeitfenster, Achse, Cursor, Rotation. Rein rechnend |
| `VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryRanker.swift` | neu — Dedup, Bewertung, Diversität. Rein rechnend |
| `VinylDiggerKit/Sources/VinylDiggerKit/Store/AppDatabase.swift` | ergänzt um Migration `v11` |
| `VinylDiggerKit/Sources/VinylDiggerKit/Store/Records.swift` | ergänzt um `DiscoveryItemRecord`, `DiscoveryCursorRecord` |
| `VinylDiggerKit/Sources/VinylDiggerKit/Session/DiscoveryService.swift` | neu — Koordination: Achse ziehen, suchen, ranken, speichern |
| `App/RecordCardView.swift` | neu — aus `QueueView.cardBody` herausgelöst, von Player und Discovery genutzt |
| `App/DiscoveryView.swift` | neu — der Tab |
| `App/RootView.swift` | vierter Tab |
| `App/SettingsView.swift` | Style-Liste |
| `App/AppEnvironment.swift` | Verdrahtung |

Testdateien spiegeln die Quelldateien: `DiscoveryAxisTests`, `DiscoveryRankerTests`, `DiscoveryServiceTests`, Ergänzungen in `DiscogsClientTests` und `AppDatabaseTests`.

---

### Task 1: Spike — die Suche gegen den Live-Dienst prüfen

Die gesamte Sortierung steht und fällt damit, dass `/database/search` `sort=have` versteht und `community` in den Treffern liefert. Das ist Doku-Wissen, kein geprüftes Verhalten. Dieser Task klärt es, bevor Code darauf gebaut wird.

**Files:**
- Create: `VinylDiggerKit/Tests/VinylDiggerKitTests/Fixtures/search_tech_house.json`

- [ ] **Step 1: Token aus dem Schlüsselbund holen**

```bash
security find-generic-password -s de.schakal.VinylDigger -a discogsToken -w
```

Kommt nichts zurück, ist in den App-Einstellungen kein Token hinterlegt — dann dort eintragen und den Befehl wiederholen.

- [ ] **Step 2: Die Suche aufrufen und roh ablegen**

```bash
TOKEN=$(security find-generic-password -s de.schakal.VinylDigger -a discogsToken -w)
curl -s -H "Authorization: Discogs token=$TOKEN" \
     -H "User-Agent: VinylDigger/0.1 +https://github.com/EduardWakal/VinylDigger" \
     'https://api.discogs.com/database/search?type=release&format=Vinyl&genre=Electronic&style=Tech+House&sort=have&sort_order=desc&per_page=50&page=1' \
     > VinylDiggerKit/Tests/VinylDiggerKitTests/Fixtures/search_tech_house.json
```

- [ ] **Step 3: Die drei Annahmen prüfen**

```bash
cd VinylDiggerKit/Tests/VinylDiggerKitTests/Fixtures
# 1. Treffer tragen community.have
jq '[.results[] | .community.have] | .[0:5]' search_tech_house.json
# 2. absteigend nach have sortiert
jq '[.results[].community.have] | . == (sort | reverse)' search_tech_house.json
# 3. master_id vorhanden
jq '[.results[] | .master_id] | .[0:5]' search_tech_house.json
```

Erwartet: fünf absteigende Zahlen, `true`, fünf Master-IDs (einzelne `0` sind in Ordnung — die behandelt der Code als „kein Master").

- [ ] **Step 4: Ergebnis festhalten**

Trägt Prüfung 2 nicht (`false`), ist das kein Abbruch, sondern ein Wechsel der Rückfallebene: in Task 2 dann `sort=want` verwenden, oder die Treffer nach dem Dekodieren lokal nach `have` sortieren. In beiden Fällen ändert sich nur der Query-Parameter beziehungsweise eine Zeile im Service, nicht die Architektur. Das Ergebnis in der Commit-Nachricht festhalten.

- [ ] **Step 5: Commit**

```bash
git add VinylDiggerKit/Tests/VinylDiggerKitTests/Fixtures/search_tech_house.json
git commit -m "test: add discogs style search fixture"
```

---

### Task 2: DiscogsSearchHit und searchByStyle

**Files:**
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/DiscogsAPI/DiscogsModels.swift`
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/DiscogsAPI/DiscogsClient.swift`
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DiscogsClientTests.swift`

**Interfaces:**
- Consumes: `DiscogsCommunity` (bestehend), `fetch(path:query:)` (privat im Client), `loadFixture(_:)` aus Task 1
- Produces:
  - `DiscogsSearchHit` mit `id: Int`, `masterID: Int?`, `title: String`, `year: Int?`, `label: String?`, `catno: String?`, `styles: [String]`, `have: Int`, `want: Int`, `artistName: String`, `recordTitle: String`
  - `DiscogsClient.searchByStyle(style: String, yearFrom: Int?, yearTo: Int?, page: Int) async throws -> [DiscogsSearchHit]`

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

An `DiscogsClientTests` anhängen:

```swift
    func testSearchByStyleDecodesHits() async throws {
        let json = """
        {"results": [
          {"id": 2831, "master_id": 41133, "title": "Inland Knights - Fresh Connections",
           "year": "1999", "label": ["20:20 Vision"], "catno": "VIS035",
           "style": ["House", "Deep House"],
           "community": {"have": 517, "want": 582}}
        ]}
        """
        let client = makeClient(StubTransport(replies: [.init(body: Data(json.utf8))]))

        let hits = try await client.searchByStyle(
            style: "Deep House", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, 2831)
        XCTAssertEqual(hits[0].masterID, 41133)
        XCTAssertEqual(hits[0].artistName, "Inland Knights")
        XCTAssertEqual(hits[0].recordTitle, "Fresh Connections")
        XCTAssertEqual(hits[0].year, 1999)
        XCTAssertEqual(hits[0].label, "20:20 Vision")
        XCTAssertEqual(hits[0].have, 517)
        XCTAssertEqual(hits[0].want, 582)
    }

    func testSearchByStyleTreatsZeroMasterAsAbsent() async throws {
        let json = """
        {"results": [{"id": 7, "master_id": 0, "title": "A - B", "community": {"have": 1, "want": 2}}]}
        """
        let client = makeClient(StubTransport(replies: [.init(body: Data(json.utf8))]))

        let hits = try await client.searchByStyle(
            style: "Minimal", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertNil(hits[0].masterID)
    }

    func testSearchByStyleBuildsQuery() async throws {
        let transport = StubTransport(replies: [.init(body: Data(#"{"results": []}"#.utf8))])
        let client = makeClient(transport)

        _ = try await client.searchByStyle(
            style: "Tech House", yearFrom: 1990, yearTo: 1999, page: 3
        )

        let url = transport.sentRequests[0].url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(url.path, "/database/search")
        XCTAssertEqual(value("type"), "release")
        XCTAssertEqual(value("format"), "Vinyl")
        XCTAssertEqual(value("genre"), "Electronic")
        XCTAssertEqual(value("style"), "Tech House")
        XCTAssertEqual(value("sort"), "want")
        XCTAssertEqual(value("sort_order"), "desc")
        XCTAssertEqual(value("per_page"), "50")
        XCTAssertEqual(value("page"), "3")
        XCTAssertEqual(value("year"), "1990-1999")
    }

    func testSearchByStyleOmitsYearForAllTime() async throws {
        let transport = StubTransport(replies: [.init(body: Data(#"{"results": []}"#.utf8))])
        let client = makeClient(transport)

        _ = try await client.searchByStyle(
            style: "House", yearFrom: nil, yearTo: nil, page: 1
        )

        let items = URLComponents(
            url: transport.sentRequests[0].url!, resolvingAgainstBaseURL: false
        )!.queryItems!
        XCTAssertNil(items.first { $0.name == "year" })
    }

    func testSearchByStyleDecodesLiveFixture() async throws {
        let body = try loadFixture("search_tech_house")
        let client = makeClient(StubTransport(replies: [.init(body: body)]))

        let hits = try await client.searchByStyle(
            style: "Tech House", yearFrom: nil, yearTo: nil, page: 1
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertFalse(hits[0].artistName.isEmpty)
    }
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd VinylDiggerKit && swift test --filter DiscogsClientTests`
Expected: FAIL — `value of type 'DiscogsClient' has no member 'searchByStyle'`

- [ ] **Step 3: Das Modell schreiben**

In `DiscogsModels.swift` hinter `DiscogsReleaseSummary` einfügen:

```swift
/// One hit from `/database/search`. Only decodable — the search response is read,
/// never sent back, and its keys do not line up with the flattened properties.
public struct DiscogsSearchHit: Decodable, Equatable, Sendable {
    public let id: Int
    public let masterID: Int?
    /// Discogs prints artist and record as one string, "Artist - Title".
    public let title: String
    public let year: Int?
    public let label: String?
    public let catno: String?
    public let styles: [String]
    public let have: Int
    public let want: Int

    public var artistName: String {
        guard let range = title.range(of: " - ") else { return "" }
        return String(title[..<range.lowerBound])
    }

    public var recordTitle: String {
        guard let range = title.range(of: " - ") else { return title }
        return String(title[range.upperBound...])
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, label, catno, year, community
        case style
        case masterID = "master_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        // Discogs writes 0 for a release that belongs to no master.
        let master = try c.decodeIfPresent(Int.self, forKey: .masterID) ?? 0
        masterID = master == 0 ? nil : master
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        label = try c.decodeIfPresent([String].self, forKey: .label)?.first
        catno = try c.decodeIfPresent(String.self, forKey: .catno)
        styles = try c.decodeIfPresent([String].self, forKey: .style) ?? []
        // Search reports the year as a string; other endpoints send a number.
        if let text = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = text.flatMap(Int.init)
        } else {
            year = try c.decodeIfPresent(Int.self, forKey: .year)
        }
        let community = try c.decodeIfPresent(DiscogsCommunity.self, forKey: .community)
            ?? DiscogsCommunity()
        have = community.have
        want = community.want
    }

    public init(
        id: Int, masterID: Int?, title: String, year: Int?, label: String?,
        catno: String?, styles: [String], have: Int, want: Int
    ) {
        self.id = id
        self.masterID = masterID
        self.title = title
        self.year = year
        self.label = label
        self.catno = catno
        self.styles = styles
        self.have = have
        self.want = want
    }
}
```

- [ ] **Step 4: Die Client-Methode schreiben**

In `DiscogsClient.swift` hinter `searchReleases` einfügen:

```swift
    /// The most sought-after vinyl of one style.
    ///
    /// Sorted by `want`, not `have`: the most *collected* records of a style are
    /// the ones that sold in pop quantities and happen to carry the tag — Charli
    /// XCX and Lady Gaga head the tech house charts by that measure. Collector
    /// demand tracks the genre's own canon far better.
    ///
    /// `type=release` rather than `type=master`: a master hit carries no main
    /// release, so each one would cost a second call. A release hit is usable at
    /// once, and the repressings it drags in are deduplicated over `master_id`.
    public func searchByStyle(
        style: String, yearFrom: Int?, yearTo: Int?, page: Int
    ) async throws -> [DiscogsSearchHit] {
        struct Envelope: Decodable { let results: [DiscogsSearchHit] }

        var query = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "format", value: "Vinyl"),
            URLQueryItem(name: "genre", value: "Electronic"),
            URLQueryItem(name: "style", value: style),
            URLQueryItem(name: "sort", value: "want"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let yearFrom, let yearTo {
            query.append(URLQueryItem(name: "year", value: "\(yearFrom)-\(yearTo)"))
        }

        let envelope: Envelope = try await fetch(path: "/database/search", query: query)
        return envelope.results
    }
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd VinylDiggerKit && swift test --filter DiscogsClientTests`
Expected: PASS, alle Tests der Datei

- [ ] **Step 6: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/DiscogsAPI VinylDiggerKit/Tests/VinylDiggerKitTests/DiscogsClientTests.swift
git commit -m "feat: search discogs by style, sorted by collector demand"
```

---

### Task 3: Die Rotation über Styles und Zeitfenster

**Files:**
- Create: `VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryAxis.swift`
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryAxisTests.swift`

**Interfaces:**
- Consumes: nichts aus früheren Tasks
- Produces:
  - `DiscoveryWindow` mit `label: String`, `from: Int?`, `to: Int?`
  - `DiscoveryAxis` mit `style: String`, `window: DiscoveryWindow`, `page: Int`, `key: String`
  - `DiscoveryCursor` mit `styleIndex: Int`, `windowIndex: Int`, `page: Int`, `init(styleIndex:windowIndex:page:)`, `static let start`
  - `DiscoveryRotation.windows(now: Date) -> [DiscoveryWindow]`
  - `DiscoveryRotation.next(styles: [String], cursor: DiscoveryCursor, now: Date) -> (axis: DiscoveryAxis, next: DiscoveryCursor)?`

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

```swift
import XCTest
@testable import VinylDiggerKit

final class DiscoveryAxisTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02-02

    func testWindowsCoverAllTimeAndFourRanges() {
        let windows = DiscoveryRotation.windows(now: reference)

        XCTAssertEqual(windows.count, 5)
        XCTAssertNil(windows[0].from)
        XCTAssertNil(windows[0].to)
        XCTAssertEqual(windows[1].from, 1990)
        XCTAssertEqual(windows[1].to, 1999)
        XCTAssertEqual(windows[4].to, 2026)
        XCTAssertEqual(windows[4].from, 2024)
    }

    func testRotationWalksEveryStyleAndWindowBeforeSecondPage() {
        let styles = ["House", "Minimal"]
        var cursor = DiscoveryCursor.start
        var seen: [String] = []

        let combinations = styles.count * DiscoveryRotation.windows(now: reference).count
        for _ in 0..<combinations {
            let step = DiscoveryRotation.next(styles: styles, cursor: cursor, now: reference)!
            seen.append(step.axis.key)
            XCTAssertEqual(step.axis.page, 1)
            cursor = step.next
        }

        XCTAssertEqual(Set(seen).count, combinations)

        let wrapped = DiscoveryRotation.next(styles: styles, cursor: cursor, now: reference)!
        XCTAssertEqual(wrapped.axis.page, 2)
        XCTAssertEqual(wrapped.axis.style, "House")
    }

    func testRotationYieldsNothingWithoutStyles() {
        XCTAssertNil(DiscoveryRotation.next(styles: [], cursor: .start, now: reference))
    }

    func testCursorOutOfRangeFallsBackToStart() {
        let step = DiscoveryRotation.next(
            styles: ["House"],
            cursor: DiscoveryCursor(styleIndex: 99, windowIndex: 99, page: 4),
            now: reference
        )!

        XCTAssertEqual(step.axis.style, "House")
        XCTAssertEqual(step.axis.page, 4)
    }
}
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryAxisTests`
Expected: FAIL — `cannot find 'DiscoveryRotation' in scope`

- [ ] **Step 3: Die Rotation schreiben**

```swift
import Foundation

/// One slice of time to search in. `from` and `to` are both nil for the whole
/// catalogue.
public struct DiscoveryWindow: Equatable, Sendable {
    public let label: String
    public let from: Int?
    public let to: Int?

    public init(label: String, from: Int?, to: Int?) {
        self.label = label
        self.from = from
        self.to = to
    }
}

/// What a single search asks for.
public struct DiscoveryAxis: Equatable, Sendable {
    public let style: String
    public let window: DiscoveryWindow
    public let page: Int

    public init(style: String, window: DiscoveryWindow, page: Int) {
        self.style = style
        self.window = window
        self.page = page
    }

    public var key: String { "\(style)|\(window.label)|\(page)" }
}

public struct DiscoveryCursor: Equatable, Sendable {
    public var styleIndex: Int
    public var windowIndex: Int
    public var page: Int

    public init(styleIndex: Int, windowIndex: Int, page: Int) {
        self.styleIndex = styleIndex
        self.windowIndex = windowIndex
        self.page = page
    }

    public static let start = DiscoveryCursor(styleIndex: 0, windowIndex: 0, page: 1)
}

/// Walks styles and time windows in a fixed order, one step per refresh.
///
/// Styles turn over fastest, then windows, and only when both are exhausted does
/// the page advance. Ordering it the other way round would show five slices of the
/// same style in a row.
public enum DiscoveryRotation {
    public static func windows(now: Date) -> [DiscoveryWindow] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        return [
            DiscoveryWindow(label: "All-Time", from: nil, to: nil),
            DiscoveryWindow(label: "90er", from: 1990, to: 1999),
            DiscoveryWindow(label: "2000er", from: 2000, to: 2009),
            DiscoveryWindow(label: "2010er", from: 2010, to: 2019),
            DiscoveryWindow(label: "aktuell", from: year - 2, to: year)
        ]
    }

    public static func next(
        styles: [String], cursor: DiscoveryCursor, now: Date
    ) -> (axis: DiscoveryAxis, next: DiscoveryCursor)? {
        guard !styles.isEmpty else { return nil }
        let windows = self.windows(now: now)

        // A stored cursor can outlive the style list it was written against.
        let styleIndex = styles.indices.contains(cursor.styleIndex) ? cursor.styleIndex : 0
        let windowIndex = windows.indices.contains(cursor.windowIndex) ? cursor.windowIndex : 0
        let page = max(cursor.page, 1)

        let axis = DiscoveryAxis(
            style: styles[styleIndex], window: windows[windowIndex], page: page
        )

        var nextStyle = styleIndex + 1
        var nextWindow = windowIndex
        var nextPage = page
        if nextStyle >= styles.count {
            nextStyle = 0
            nextWindow += 1
            if nextWindow >= windows.count {
                nextWindow = 0
                nextPage += 1
            }
        }

        return (axis, DiscoveryCursor(styleIndex: nextStyle, windowIndex: nextWindow, page: nextPage))
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryAxisTests`
Expected: PASS, vier Tests

- [ ] **Step 5: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryAxis.swift VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryAxisTests.swift
git commit -m "feat: rotate discovery over styles and decades"
```

---

### Task 4: Tabellen und Records

**Files:**
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Store/AppDatabase.swift:190` (vor `return migrator`)
- Modify: `VinylDiggerKit/Sources/VinylDiggerKit/Store/Records.swift`
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/AppDatabaseTests.swift`

**Interfaces:**
- Consumes: nichts aus früheren Tasks
- Produces:
  - `DiscoveryItemRecord` mit `releaseID: Int`, `masterID: Int?`, `title: String`, `artistName: String`, `styles: [String]`, `have: Int`, `want: Int`, `year: Int?`, `labelName: String?`, `catno: String?`, `axisKey: String`, `score: Double`, `rank: Int`, `fetchedAt: Date`
  - `DiscoveryCursorRecord` mit `id: Int`, `styleIndex: Int`, `windowIndex: Int`, `page: Int` und `static let singletonID = 1`

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

An `AppDatabaseTests` anhängen:

```swift
    func testStoresAndReadsDiscoveryItem() throws {
        let database = try AppDatabase.inMemory()
        let stamp = Date(timeIntervalSince1970: 1_770_000_000)

        try database.write { db in
            var item = DiscoveryItemRecord(
                releaseID: 2831, masterID: 41133, title: "Fresh Connections",
                artistName: "Inland Knights", styles: ["Deep House"],
                have: 517, want: 582, year: 1999, labelName: "20:20 Vision",
                catno: "VIS035", axisKey: "Deep House|All-Time|1",
                score: 0.8, rank: 0, fetchedAt: stamp
            )
            try item.insert(db)
        }

        let stored = try database.read { try DiscoveryItemRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(stored?.artistName, "Inland Knights")
        XCTAssertEqual(stored?.styles, ["Deep House"])
        XCTAssertEqual(stored?.have, 517)
    }

    func testDiscoveryCursorRoundTrips() throws {
        let database = try AppDatabase.inMemory()

        try database.write { db in
            var cursor = DiscoveryCursorRecord(
                id: DiscoveryCursorRecord.singletonID,
                styleIndex: 2, windowIndex: 3, page: 4
            )
            try cursor.save(db)
        }

        let stored = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(stored?.styleIndex, 2)
        XCTAssertEqual(stored?.windowIndex, 3)
        XCTAssertEqual(stored?.page, 4)
    }
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd VinylDiggerKit && swift test --filter AppDatabaseTests`
Expected: FAIL — `cannot find 'DiscoveryItemRecord' in scope`

- [ ] **Step 3: Die Migration schreiben**

In `AppDatabase.swift` direkt vor `return migrator` einfügen:

```swift
        migrator.registerMigration("v11") { db in
            try db.create(table: "discovery_item") { t in
                t.primaryKey("releaseID", .integer)
                t.column("masterID", .integer)
                t.column("title", .text).notNull()
                t.column("artistName", .text).notNull()
                t.column("styles", .blob).notNull()
                t.column("have", .integer).notNull().defaults(to: 0)
                t.column("want", .integer).notNull().defaults(to: 0)
                t.column("year", .integer)
                t.column("labelName", .text)
                t.column("catno", .text)
                t.column("axisKey", .text).notNull()
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("rank", .integer).notNull().defaults(to: 0)
                t.column("fetchedAt", .datetime).notNull()
            }

            try db.create(table: "discovery_cursor") { t in
                t.primaryKey("id", .integer)
                t.column("styleIndex", .integer).notNull().defaults(to: 0)
                t.column("windowIndex", .integer).notNull().defaults(to: 0)
                t.column("page", .integer).notNull().defaults(to: 1)
            }
        }
```

- [ ] **Step 4: Die Records schreiben**

An `Records.swift` anhängen:

```swift
/// One record from the style charts, waiting to be auditioned. The table is
/// cleared and refilled on every refresh, like `queue_item`.
public struct DiscoveryItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "discovery_item"

    public var releaseID: Int
    /// Nil when Discogs files the release under no master.
    public var masterID: Int?
    public var title: String
    public var artistName: String
    public var styles: [String]
    public var have: Int
    public var want: Int
    public var year: Int?
    public var labelName: String?
    public var catno: String?
    /// Which style, window and page turned this up — shown on the card.
    public var axisKey: String
    public var score: Double
    public var rank: Int
    public var fetchedAt: Date

    public init(
        releaseID: Int, masterID: Int?, title: String, artistName: String,
        styles: [String], have: Int, want: Int, year: Int?, labelName: String?,
        catno: String?, axisKey: String, score: Double, rank: Int, fetchedAt: Date
    ) {
        self.releaseID = releaseID
        self.masterID = masterID
        self.title = title
        self.artistName = artistName
        self.styles = styles
        self.have = have
        self.want = want
        self.year = year
        self.labelName = labelName
        self.catno = catno
        self.axisKey = axisKey
        self.score = score
        self.rank = rank
        self.fetchedAt = fetchedAt
    }
}

/// Where the rotation stopped last time. Exactly one row.
public struct DiscoveryCursorRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "discovery_cursor"
    public static let singletonID = 1

    public var id: Int
    public var styleIndex: Int
    public var windowIndex: Int
    public var page: Int

    public init(id: Int = DiscoveryCursorRecord.singletonID, styleIndex: Int, windowIndex: Int, page: Int) {
        self.id = id
        self.styleIndex = styleIndex
        self.windowIndex = windowIndex
        self.page = page
    }
}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd VinylDiggerKit && swift test --filter AppDatabaseTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Store VinylDiggerKit/Tests/VinylDiggerKitTests/AppDatabaseTests.swift
git commit -m "feat: store discovery batches and the rotation cursor"
```

---

### Task 5: Der Ranker

**Files:**
- Create: `VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryRanker.swift`
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryRankerTests.swift`

**Interfaces:**
- Consumes: `ScoredRelease` und `QueuePlanner.plan(_:limit:)` (bestehend)
- Produces:
  - `DiscoveryCandidate` mit `releaseID: Int`, `masterID: Int?`, `artistName: String`, `labelName: String?`, `want: Int`, `styles: [String]`, `isKnownArtist: Bool`, `isOwned: Bool`, `isDecided: Bool`, `revisitAt: Date?`
  - `RankedDiscovery` mit `releaseID: Int`, `score: Double`
  - `DiscoveryRanker.knownArtistFactor: Double`
  - `DiscoveryRanker.foreignStyles: Set<String>`
  - `DiscoveryRanker.rank(_ candidates: [DiscoveryCandidate], limit: Int, now: Date) -> [RankedDiscovery]`

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

```swift
import XCTest
@testable import VinylDiggerKit

final class DiscoveryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func candidate(
        id: Int, artist: String = "A", label: String? = nil, want: Int = 100,
        styles: [String] = ["Tech House"], known: Bool = false, owned: Bool = false,
        decided: Bool = false, master: Int? = nil, revisitAt: Date? = nil
    ) -> DiscoveryCandidate {
        DiscoveryCandidate(
            releaseID: id, masterID: master, artistName: artist, labelName: label,
            want: want, styles: styles, isKnownArtist: known, isOwned: owned,
            isDecided: decided, revisitAt: revisitAt
        )
    }

    func testDropsOwnedAndDecided() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", owned: true),
                candidate(id: 2, artist: "B", decided: true),
                candidate(id: 3, artist: "C")
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [3])
    }

    func testPostponedRecordReturnsAfterItsDate() {
        let past = now.addingTimeInterval(-60)
        let future = now.addingTimeInterval(60)

        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", decided: true, revisitAt: past),
                candidate(id: 2, artist: "B", decided: true, revisitAt: future)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [1])
    }

    func testKnownArtistRanksBehindUnknownAtEqualWant() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "Bekannt", want: 500, known: true),
                candidate(id: 2, artist: "Neu", want: 500, known: false)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [2, 1])
    }

    func testDeduplicatesByMasterKeepingTheMostWanted() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", want: 100, master: 77),
                candidate(id: 2, artist: "A", want: 900, master: 77),
                candidate(id: 3, artist: "B", want: 50, master: nil)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [2, 3])
    }

    func testDropsForeignStyles() {
        // What the live search actually returned at the top of "Tech House".
        let ranked = DiscoveryRanker.rank(
            [
                candidate(
                    id: 1, artist: "Charli XCX", want: 3757,
                    styles: ["Tech House", "Electro House", "Dance-pop", "Hyperpop"]
                ),
                candidate(
                    id: 2, artist: "Stromae", want: 2812,
                    styles: ["Hip Hop", "Tech House", "Chanson"]
                ),
                candidate(
                    id: 3, artist: "Villalobos", want: 4888,
                    styles: ["Minimal Techno", "Tech House", "House"]
                )
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [3])
    }

    func testKeepsRecordsWithoutStyles() {
        // An unstyled hit is unknown, not foreign. Throwing it out would silently
        // shrink the pool.
        let ranked = DiscoveryRanker.rank(
            [candidate(id: 1, artist: "A", styles: [])], limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [1])
    }

    func testForeignStyleMatchIgnoresCase() {
        let ranked = DiscoveryRanker.rank(
            [candidate(id: 1, artist: "A", styles: ["dance-POP"])], limit: 10, now: now
        )

        XCTAssertTrue(ranked.isEmpty)
    }

    func testSpreadsAcrossArtists() {
        // Three by one artist, one by another. The lone outsider must not end last.
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "Vielschreiber", want: 900),
                candidate(id: 2, artist: "Vielschreiber", want: 890),
                candidate(id: 3, artist: "Vielschreiber", want: 880),
                candidate(id: 4, artist: "Anderer", want: 400)
            ],
            limit: 4, now: now
        )

        XCTAssertEqual(ranked[0].releaseID, 1)
        XCTAssertEqual(ranked[1].releaseID, 4)
    }

    func testHonoursLimit() {
        let many = (1...20).map { candidate(id: $0, artist: "A\($0)") }
        XCTAssertEqual(DiscoveryRanker.rank(many, limit: 5, now: now).count, 5)
    }
}
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryRankerTests`
Expected: FAIL — `cannot find 'DiscoveryRanker' in scope`

- [ ] **Step 3: Den Ranker schreiben**

```swift
import Foundation

public struct DiscoveryCandidate: Equatable, Sendable {
    public let releaseID: Int
    public let masterID: Int?
    public let artistName: String
    public let labelName: String?
    /// How many people are looking for this record. Collector demand, not sales.
    public let want: Int
    /// Every style Discogs files the record under, used to weed out pop records
    /// that merely carry the searched tag.
    public let styles: [String]
    /// True when this artist already sits in the taste graph.
    public let isKnownArtist: Bool
    public let isOwned: Bool
    public let isDecided: Bool
    public let revisitAt: Date?

    public init(
        releaseID: Int, masterID: Int?, artistName: String, labelName: String?,
        want: Int, styles: [String], isKnownArtist: Bool, isOwned: Bool,
        isDecided: Bool, revisitAt: Date?
    ) {
        self.releaseID = releaseID
        self.masterID = masterID
        self.artistName = artistName
        self.labelName = labelName
        self.want = want
        self.styles = styles
        self.isKnownArtist = isKnownArtist
        self.isOwned = isOwned
        self.isDecided = isDecided
        self.revisitAt = revisitAt
    }
}

public struct RankedDiscovery: Equatable, Sendable {
    public let releaseID: Int
    public let score: Double

    public init(releaseID: Int, score: Double) {
        self.releaseID = releaseID
        self.score = score
    }
}

/// Orders a batch of style-chart hits.
///
/// Deliberately not `Scorer`: that one multiplies by graph affinity, and every
/// record here comes from outside the graph, so all of them would score zero.
/// What stands in for affinity is how many people are hunting the record.
public enum DiscoveryRanker {
    /// How much a record loses for being by an artist already in the graph.
    /// Lower it to 0 to shut familiar names out entirely.
    public static let knownArtistFactor = 0.5

    /// Styles that mark a hit as something other than club music, however the
    /// tags read. A pop record with a "Tech House" tag outranks every real one
    /// on demand alone, so it is dropped rather than ranked down.
    ///
    /// Kept deliberately short: it should catch pop, not borderline cases. Every
    /// entry here was seen at the top of a live search.
    public static let foreignStyles: Set<String> = [
        "pop", "dance-pop", "hyperpop", "synth-pop", "europop", "j-pop", "k-pop",
        "hip hop", "rap", "chanson", "schlager", "country", "ballad", "rock",
        "pop rock", "indie rock", "reggaeton"
    ]

    public static func rank(
        _ candidates: [DiscoveryCandidate], limit: Int, now: Date
    ) -> [RankedDiscovery] {
        // Filter before collapsing pressings. The other way round, a pressing that
        // is owned or carries a foreign tag can win the master on `want` and then
        // be filtered out, taking a perfectly good pressing of the same record with
        // it.
        let playable = candidates.filter { novelty($0, now: now) > 0 && !isForeign($0) }
        let deduped = deduplicate(playable)
        guard !deduped.isEmpty else { return [] }

        let maxWant = max(deduped.map(\.want).max() ?? 0, 1)
        let denominator = log1p(Double(maxWant))

        // QueuePlanner counts repeats by integer id, but a search hit carries only
        // names. Numbering them within the batch is enough — the counts never
        // leave this call.
        var artistIDs: [String: Int] = [:]
        var labelIDs: [String: Int] = [:]
        func number(_ name: String, in table: inout [String: Int]) -> Int {
            if let existing = table[name] { return existing }
            let next = table.count + 1
            table[name] = next
            return next
        }

        let scored = deduped.map { candidate -> ScoredRelease in
            let demand = denominator > 0 ? log1p(Double(candidate.want)) / denominator : 0
            let familiarity = candidate.isKnownArtist ? knownArtistFactor : 1.0
            return ScoredRelease(
                releaseID: candidate.releaseID,
                score: demand * familiarity,
                labelID: candidate.labelName.map { number($0, in: &labelIDs) },
                artistIDs: [number(candidate.artistName, in: &artistIDs)],
                reason: ""
            )
        }

        let ordered = QueuePlanner.plan(
            scored.sorted {
                $0.score == $1.score ? $0.releaseID < $1.releaseID : $0.score > $1.score
            },
            limit: limit
        )
        return ordered.map { RankedDiscovery(releaseID: $0.releaseID, score: $0.score) }
    }

    /// One entry per master — a reissue is the same record twice. The most
    /// sought-after pressing wins, because that is the one being hunted.
    private static func deduplicate(_ candidates: [DiscoveryCandidate]) -> [DiscoveryCandidate] {
        var best: [Int: DiscoveryCandidate] = [:]
        var withoutMaster: [DiscoveryCandidate] = []

        for candidate in candidates {
            guard let masterID = candidate.masterID else {
                withoutMaster.append(candidate)
                continue
            }
            if let existing = best[masterID], existing.want >= candidate.want { continue }
            best[masterID] = candidate
        }

        return Array(best.values) + withoutMaster
    }

    /// A record with no styles at all is unknown, not foreign — dropping it would
    /// quietly shrink the pool for a missing tag.
    private static func isForeign(_ candidate: DiscoveryCandidate) -> Bool {
        candidate.styles.contains { foreignStyles.contains($0.lowercased()) }
    }

    /// Same rule as `Scorer.novelty`: a postponed record comes back once its
    /// revisit date has passed.
    private static func novelty(_ candidate: DiscoveryCandidate, now: Date) -> Double {
        if candidate.isOwned { return 0 }
        guard candidate.isDecided else { return 1 }
        guard let revisitAt = candidate.revisitAt else { return 0 }
        return revisitAt <= now ? 1 : 0
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryRankerTests`
Expected: PASS, neun Tests

- [ ] **Step 5: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Graph/DiscoveryRanker.swift VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryRankerTests.swift
git commit -m "feat: rank style-chart hits without the taste graph"
```

---

### Task 6: Der Service

**Files:**
- Create: `VinylDiggerKit/Sources/VinylDiggerKit/Session/DiscoveryService.swift`
- Test: `VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryServiceTests.swift`

**Interfaces:**
- Consumes: `DiscogsClient.searchByStyle`, `DiscoveryRotation.next`, `DiscoveryRanker.rank`, `DiscoveryItemRecord`, `DiscoveryCursorRecord`, `QueueCard`, `ReleaseRecord`, `ArtistRecord`, `DecisionRecord`
- Produces:
  - `DiscoveryError.noStyles`
  - `DiscoveryService.init(database:client:styles:now:)`
  - `DiscoveryService.refresh(limit:) async throws -> [QueueCard]`
  - `DiscoveryService.currentBatch() throws -> [QueueCard]` (nonisolated)

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

```swift
import XCTest
import GRDB
@testable import VinylDiggerKit

final class DiscoveryServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeClient(_ transport: StubTransport) -> DiscogsClient {
        let secrets = InMemorySecretStore()
        try? secrets.write("tok", for: .discogsToken)
        return DiscogsClient(
            transport: transport, secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
    }

    private func results(_ hits: String) -> Data {
        Data("{\"results\": [\(hits)]}".utf8)
    }

    private func hit(id: Int, artist: String, want: Int, master: Int = 0) -> String {
        """
        {"id": \(id), "master_id": \(master), "title": "\(artist) - Titel \(id)",
         "year": "1999", "label": ["Label"], "catno": "CAT\(id)",
         "style": ["Deep House"], "community": {"have": 10, "want": \(want)}}
        """
    }

    func testRefreshStoresBatchAndAdvancesCursor() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results([hit(id: 1, artist: "Neu", want: 500)].joined(separator: ",")))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].releaseID, 1)
        XCTAssertEqual(cards[0].artistName, "Neu")
        XCTAssertTrue(cards[0].reason.contains("Deep House"))

        let cursor = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(cursor?.windowIndex, 1)
    }

    func testRefreshFilesStubReleasesSoTheyCanBeHydrated() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 42, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        _ = try await service.refresh(limit: 10)

        let release = try database.read { try ReleaseRecord.fetchOne($0, key: 42) }
        XCTAssertEqual(release?.artistName, "Neu")
        XCTAssertEqual(release?.detailFetched, false)
    }

    func testRefreshSkipsExhaustedAxisAndTriesTheNext() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            var owned = ReleaseRecord(
                id: 1, title: "Titel 1", artistName: "Neu", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: false, owned: true
            )
            try owned.save(db)
        }
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500))),
            .init(body: results(hit(id: 2, artist: "Neu", want: 400)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.map(\.releaseID), [2])
        XCTAssertEqual(transport.sentRequests.count, 2)
    }

    func testRefreshGivesUpAfterThreeEmptyAxes() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results("")), .init(body: results("")), .init(body: results(""))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertTrue(cards.isEmpty)
        XCTAssertEqual(transport.sentRequests.count, 3)
    }

    func testRefreshWithoutStylesThrows() async {
        let database = try! AppDatabase.inMemory()
        let service = DiscoveryService(
            database: database, client: makeClient(StubTransport(replies: [])),
            styles: [], now: { self.now }
        )

        do {
            _ = try await service.refresh(limit: 10)
            XCTFail("expected noStyles")
        } catch let error as DiscoveryError {
            XCTAssertEqual(error, .noStyles)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFailedSearchLeavesCursorAndBatchAlone() async throws {
        let database = try AppDatabase.inMemory()
        let good = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(good),
            styles: ["Deep House"], now: { self.now }
        )
        _ = try await service.refresh(limit: 10)

        let failing = DiscoveryService(
            database: database,
            client: makeClient(StubTransport(replies: [.init(status: 500)])),
            styles: ["Deep House"], now: { self.now }
        )
        _ = try? await failing.refresh(limit: 10)

        XCTAssertEqual(try failing.currentBatch().map(\.releaseID), [1])
        let cursor = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(cursor?.windowIndex, 1)
    }

    func testKnownArtistIsMarkedForTheRanker() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            var artist = ArtistRecord(id: 9, name: "Bekannt", weight: 1, refreshedAt: nil)
            try artist.save(db)
        }
        let transport = StubTransport(replies: [
            .init(body: results([
                hit(id: 1, artist: "Bekannt", want: 500),
                hit(id: 2, artist: "Neu", want: 500)
            ].joined(separator: ",")))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.map(\.releaseID), [2, 1])
    }
}
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryServiceTests`
Expected: FAIL — `cannot find 'DiscoveryService' in scope`

- [ ] **Step 3: Den Service schreiben**

```swift
import Foundation
import GRDB

public enum DiscoveryError: Error, Equatable {
    case noStyles
}

/// Fills the discovery tab from the Discogs style charts.
///
/// Separate from `QueueService` on purpose: the two share no state, and the
/// queue path is already long enough. What they do share is the decision
/// record — a love here goes through `QueueService.decide`, which is how a
/// discovered record finds its way into the taste graph.
public actor DiscoveryService {
    /// How many exhausted axes to skip before reporting an empty refresh.
    private static let maxEmptyAxes = 3

    private let database: AppDatabase
    private let client: DiscogsClient
    private let styles: [String]
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        client: DiscogsClient,
        styles: [String],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.client = client
        self.styles = styles
        self.now = now
    }

    @discardableResult
    public func refresh(limit: Int = 50) async throws -> [QueueCard] {
        guard !styles.isEmpty else { throw DiscoveryError.noStyles }
        let current = now()

        for _ in 0..<Self.maxEmptyAxes {
            var cursor = try readCursor()
            guard let step = DiscoveryRotation.next(styles: styles, cursor: cursor, now: current) else {
                throw DiscoveryError.noStyles
            }

            let hits = try await client.searchByStyle(
                style: step.axis.style,
                yearFrom: step.axis.window.from,
                yearTo: step.axis.window.to,
                page: step.axis.page
            )

            // The cursor only moves once the call came back. A failed search must
            // not silently burn an axis.
            cursor = step.next
            try writeCursor(cursor)

            let ranked = try rank(hits, limit: limit, now: current)
            guard !ranked.isEmpty else { continue }

            try store(ranked, hits: hits, axis: step.axis, at: current)
            return try currentBatch()
        }

        return []
    }

    public nonisolated func currentBatch() throws -> [QueueCard] {
        try database.read { db in
            let items = try DiscoveryItemRecord
                .order(Column("rank"))
                .fetchAll(db)

            return try items.map { item in
                let release = try ReleaseRecord.fetchOne(db, key: item.releaseID)
                let videos = try VideoRecord
                    .filter(Column("releaseID") == item.releaseID && Column("unavailable") == false)
                    .order(Column("position"))
                    .fetchAll(db)

                return QueueCard(
                    releaseID: item.releaseID,
                    title: release?.title ?? item.title,
                    artistName: release?.artistName ?? item.artistName,
                    labelName: item.labelName,
                    catno: item.catno,
                    year: item.year,
                    styles: item.styles,
                    want: item.want,
                    reason: Self.reason(for: item),
                    videoIDs: videos.map(\.youtubeID),
                    rating: (release?.ratingCount ?? 0) > 0 ? release?.rating : nil,
                    ratingCount: release?.ratingCount ?? 0,
                    coverURL: release?.coverURL,
                    tracks: videos.map {
                        QueueTrack(
                            youtubeID: $0.youtubeID, title: $0.title,
                            position: $0.trackPosition, duration: $0.duration
                        )
                    }
                )
            }
        }
    }

    /// "Deep House · All-Time · 1.204 wollen's"
    ///
    /// Parsed from the right: the trailing two components are fixed, but the style
    /// is user-entered and may itself contain the separator.
    private static func reason(for item: DiscoveryItemRecord) -> String {
        let parts = item.axisKey.split(separator: "|", omittingEmptySubsequences: false)
        let style = parts.count >= 3 ? parts[0..<(parts.count - 2)].joined(separator: "|") : ""
        let window = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "de_DE")
        let want = formatter.string(from: NSNumber(value: item.want)) ?? "\(item.want)"
        return "\(style) \u{00B7} \(window) \u{00B7} \(want) wollen's"
    }

    // MARK: - Steps

    private func readCursor() throws -> DiscoveryCursor {
        try database.read { db in
            guard let record = try DiscoveryCursorRecord.fetchOne(
                db, key: DiscoveryCursorRecord.singletonID
            ) else { return .start }
            return DiscoveryCursor(
                styleIndex: record.styleIndex, windowIndex: record.windowIndex, page: record.page
            )
        }
    }

    private func writeCursor(_ cursor: DiscoveryCursor) throws {
        try database.write { db in
            var record = DiscoveryCursorRecord(
                styleIndex: cursor.styleIndex, windowIndex: cursor.windowIndex, page: cursor.page
            )
            try record.save(db)
        }
    }

    private func rank(
        _ hits: [DiscogsSearchHit], limit: Int, now: Date
    ) throws -> [RankedDiscovery] {
        let candidates = try database.read { db -> [DiscoveryCandidate] in
            let knownArtists = Set(
                try ArtistRecord.fetchAll(db).map { Self.normalise($0.name) }
            )

            return try hits.map { hit in
                let release = try ReleaseRecord.fetchOne(db, key: hit.id)
                let decision = try DecisionRecord
                    .filter(Column("releaseID") == hit.id)
                    .order(Column("decidedAt").desc)
                    .fetchOne(db)

                return DiscoveryCandidate(
                    releaseID: hit.id,
                    masterID: hit.masterID,
                    artistName: hit.artistName,
                    labelName: hit.label,
                    want: hit.want,
                    styles: hit.styles,
                    isKnownArtist: knownArtists.contains(Self.normalise(hit.artistName)),
                    isOwned: release?.owned ?? false,
                    isDecided: decision != nil,
                    revisitAt: decision?.revisitAt
                )
            }
        }
        return DiscoveryRanker.rank(candidates, limit: limit, now: now)
    }

    /// A search hit carries no artist id, so the graph is matched by name.
    /// Discogs disambiguates duplicates with a trailing counter — "Wulf (20)" is
    /// the same name as "Wulf" for this purpose.
    private static func normalise(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let counter = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            if counter.allSatisfy(\.isNumber) {
                trimmed = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed.lowercased()
    }

    private func store(
        _ ranked: [RankedDiscovery], hits: [DiscogsSearchHit],
        axis: DiscoveryAxis, at stamp: Date
    ) throws {
        let hitsByID = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        try database.write { db in
            try DiscoveryItemRecord.deleteAll(db)

            for (rank, entry) in ranked.enumerated() {
                guard let hit = hitsByID[entry.releaseID] else { continue }

                var item = DiscoveryItemRecord(
                    releaseID: hit.id, masterID: hit.masterID, title: hit.recordTitle,
                    artistName: hit.artistName, styles: hit.styles, have: hit.have,
                    want: hit.want, year: hit.year, labelName: hit.label,
                    catno: hit.catno, axisKey: axis.key, score: entry.score,
                    rank: rank, fetchedAt: stamp
                )
                try item.insert(db)

                // Filing a stub is what lets the existing machinery work on these
                // records: hydrateRelease fills them in, refreshedCard reads them,
                // and a love decision has something to point at.
                guard try ReleaseRecord.fetchOne(db, key: hit.id) == nil else { continue }
                var release = ReleaseRecord(
                    id: hit.id, title: hit.recordTitle, artistName: hit.artistName,
                    year: hit.year, catno: hit.catno, labelID: nil,
                    styles: hit.styles, want: hit.want, have: hit.have, hydrated: false
                )
                try release.save(db)
            }
        }
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd VinylDiggerKit && swift test --filter DiscoveryServiceTests`
Expected: PASS, sieben Tests

- [ ] **Step 5: Die ganze Suite laufen lassen**

Run: `cd VinylDiggerKit && swift test`
Expected: PASS. Besonders `ScorerTests` und `QueuePlannerTests` — die Stub-Releases dürfen die normale Queue nicht verändern.

- [ ] **Step 6: Commit**

```bash
git add VinylDiggerKit/Sources/VinylDiggerKit/Session/DiscoveryService.swift VinylDiggerKit/Tests/VinylDiggerKitTests/DiscoveryServiceTests.swift
git commit -m "feat: fill a discovery batch from the style charts"
```

---

### Task 7: Das Kartenlayout herauslösen

Reiner Umbau, kein neues Verhalten. `QueueView.cardBody` ist privat, der Discovery-Tab braucht dasselbe Layout.

**Files:**
- Create: `App/RecordCardView.swift`
- Modify: `App/QueueView.swift:103-214`

**Interfaces:**
- Consumes: `QueueCard`, `AppEnvironment`
- Produces: `RecordCardView` mit `init(card: QueueCard)`

- [ ] **Step 1: Den bestehenden Zustand festhalten**

Run: `xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. Ohne grüne Ausgangslage ist nach dem Umbau nicht zu unterscheiden, was kaputt war und was kaputt ging.

- [ ] **Step 2: Den Rumpf verschieben**

`App/RecordCardView.swift` anlegen:

```swift
import SwiftUI
import VinylDiggerKit

/// The record as it appears on screen — sleeve, title, styles, rating, tracks.
/// Shared by the player queue and the discovery tab; neither owns it.
struct RecordCardView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let card: QueueCard

    var body: some View {
        // Body aus QueueView.cardBody übernehmen, unverändert. Jedes `card`
        // darin bezieht sich jetzt auf die Property statt auf den Parameter.
    }
}
```

Den kompletten Rumpf von `QueueView.cardBody(_:)` (Zeilen 103–214) hierher übertragen. `TrackList`, `TransportView` und `CoverView` bleiben in `QueueView.swift` — sie sind dort `private`, also müssen die drei Deklarationen ihr `private` verlieren, damit `RecordCardView` sie sieht. Kein `public`: beide Dateien liegen im selben Modul.

- [ ] **Step 3: QueueView umstellen**

`cardBody(_:)` in `QueueView` löschen und die Aufrufstelle ersetzen durch:

```swift
RecordCardView(card: card)
```

- [ ] **Step 4: Projekt neu erzeugen und bauen**

```bash
xcodegen generate
xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Sichtprüfung**

App starten, Player-Tab öffnen. Karte muss aussehen wie vorher: Cover, Titel, Künstler, Label, Styles, Rating, Trackliste. Ein Track lässt sich weiterhin liken.

- [ ] **Step 6: Commit**

```bash
git add App/RecordCardView.swift App/QueueView.swift VinylDigger.xcodeproj
git commit -m "refactor: lift the record card out of the queue view"
```

---

### Task 8: Die Style-Liste in den Einstellungen

**Files:**
- Modify: `App/SettingsView.swift`
- Create: `App/DiscoveryStyles.swift`

**Interfaces:**
- Consumes: nichts aus früheren Tasks
- Produces: `DiscoveryStyles.defaults: [String]`, `DiscoveryStyles.load() -> [String]`, `DiscoveryStyles.save(_ styles: [String])`

- [ ] **Step 1: Den Speicher schreiben**

`App/DiscoveryStyles.swift`:

```swift
import Foundation

/// The styles the discovery tab searches. Kept in UserDefaults rather than the
/// database — it is a setting, not data, and the settings window is where the
/// user goes looking for it.
enum DiscoveryStyles {
    private static let key = "discoveryStyles"

    static let defaults = [
        "Tech House", "House", "Deep House", "Minimal", "Progressive House"
    ]

    static func load() -> [String] {
        guard let stored = UserDefaults.standard.stringArray(forKey: key) else { return defaults }
        return stored
    }

    /// The axis key joins style, window and page with a pipe, so a style carrying
    /// one would garble the line shown on the card. Returns nil for anything that
    /// is empty once cleaned.
    static func clean(_ style: String) -> String? {
        let cleaned = style
            .replacingOccurrences(of: "|", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func save(_ styles: [String]) {
        UserDefaults.standard.set(styles.compactMap(clean), forKey: key)
    }
}
```

Eine leere gespeicherte Liste bleibt leer — sie auf die Vorgabe zurückzusetzen würde eine bewusste Entscheidung des Nutzers überschreiben. Der Refresh meldet dann `DiscoveryError.noStyles`, und die Oberfläche zeigt darauf hin.

- [ ] **Step 2: Die Einstellungen erweitern**

In `SettingsView` neben `token` und `username` ergänzen:

```swift
    @State private var styles: [String] = []
    @State private var newStyle = ""
```

Vor dem `Section` mit den Knöpfen einfügen:

```swift
            Section("Discovery-Styles") {
                ForEach(styles, id: \.self) { style in
                    HStack {
                        Text(style)
                        Spacer()
                        Button("Entfernen", role: .destructive) {
                            DiscoveryStyles.save(styles.filter { $0 != style })
                            styles = DiscoveryStyles.load()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Style hinzufügen", text: $newStyle)
                    Button("Hinzufügen") { addStyle() }
                        .disabled(newStyle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Genau so schreiben, wie Discogs den Style führt — etwa „Deep House\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Und die beiden Hilfsmethoden:

```swift
    private func addStyle() {
        guard let cleaned = DiscoveryStyles.clean(newStyle), !styles.contains(cleaned) else { return }
        DiscoveryStyles.save(styles + [cleaned])
        // Re-read rather than trust the local copy: save cleans, and the two must
        // not drift apart.
        styles = DiscoveryStyles.load()
        newStyle = ""
    }
```

In `load()` ergänzen:

```swift
        styles = DiscoveryStyles.load()
```

- [ ] **Step 3: Bauen**

```bash
xcodegen generate
xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Sichtprüfung**

Einstellungen öffnen. Fünf Styles stehen da. Einer lässt sich entfernen, einer hinzufügen, und nach einem Neustart der App ist die Änderung noch da.

- [ ] **Step 5: Commit**

```bash
git add App/DiscoveryStyles.swift App/SettingsView.swift VinylDigger.xcodeproj
git commit -m "feat: let the discovery styles be edited in settings"
```

---

### Task 9: Der Tab

**Files:**
- Create: `App/DiscoveryView.swift`
- Modify: `App/RootView.swift`
- Modify: `App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `DiscoveryService`, `DiscoveryError`, `DiscoveryStyles`, `RecordCardView`, `QueueService.decide`, `QueueService.hydrateRelease`
- Produces: `AppEnvironment.discoveryCards`, `.discoveryIndex`, `.discoveryStatus`, `.refreshDiscovery()`, `.decideDiscovery(_:)`, `.discoveryCard`

- [ ] **Step 1: Die Verdrahtung schreiben**

In `AppEnvironment` bei den anderen `@Published` ergänzen:

```swift
    @Published var discoveryCards: [QueueCard] = []
    @Published var discoveryIndex = 0
    @Published var discoveryStatus = "noch nichts geholt"
```

`start()` bleibt unverändert — der Discovery-Service wird nicht dort gebaut, sondern bei jedem Refresh neu, damit eine frisch gesetzte Style-Liste sofort greift. Er hält keinen Zustand, das kostet nichts.

Als neuer Abschnitt vor `// MARK: - Obsidian`:

```swift
    // MARK: - Discovery

    var discoveryCard: QueueCard? {
        discoveryCards.indices.contains(discoveryIndex) ? discoveryCards[discoveryIndex] : nil
    }

    /// Pulls the next slice of the style charts. The service is rebuilt on every
    /// call so a style added in settings takes effect at once instead of on the
    /// next launch; it carries no state, so this costs nothing.
    func refreshDiscovery() async {
        guard let database, let client else {
            discoveryStatus = "Noch keine Verbindung — Token prüfen"
            return
        }
        let service = DiscoveryService(
            database: database, client: client, styles: DiscoveryStyles.load()
        )

        discoveryStatus = "Charts werden geholt…"
        do {
            discoveryCards = try await service.refresh(limit: 50)
            discoveryIndex = 0
            if discoveryCards.isEmpty {
                discoveryStatus = "nichts Neues gefunden — nochmal versuchen"
            } else {
                discoveryStatus = "\(discoveryCards.count) Platten"
                loadDiscoveryCard()
            }
        } catch DiscoveryError.noStyles {
            discoveryStatus = "Keine Styles gesetzt — in den Einstellungen eintragen"
        } catch {
            discoveryStatus = "Fehler: \(error)"
        }
    }

    func decideDiscovery(_ kind: DecisionKind) async {
        guard let service, let card = discoveryCard else { return }
        do {
            try await service.decide(releaseID: card.releaseID, kind: kind)
            if discoveryIndex + 1 < discoveryCards.count {
                discoveryIndex += 1
                loadDiscoveryCard()
            } else {
                await refreshDiscovery()
            }
        } catch {
            discoveryStatus = "Fehler: \(error)"
        }
    }

    private func loadDiscoveryCard() {
        guard let card = discoveryCard else { return }
        loadIntoPlayer(card)
        Task {
            guard let service else { return }
            try? await service.hydrateRelease(releaseID: card.releaseID)
            guard
                let index = discoveryCards.firstIndex(where: { $0.releaseID == card.releaseID }),
                let refreshed = try? service.refreshedCard(discoveryCards[index])
            else { return }
            discoveryCards[index] = refreshed
        }
    }
```

`loadIntoPlayer` ist bereits privat vorhanden und wird hier mitgenutzt.

- [ ] **Step 2: Den Tab schreiben**

`App/DiscoveryView.swift`:

```swift
import SwiftUI
import VinylDiggerKit

/// The style charts, one record at a time. Same card as the player, different
/// source: nothing here comes from the taste graph.
struct DiscoveryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 12) {
            if let card = environment.discoveryCard {
                RecordCardView(card: card)

                HStack(spacing: 12) {
                    Button("Auf die Wantlist") {
                        Task { await environment.decideDiscovery(.love) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Nichts für mich") {
                        Task { await environment.decideDiscovery(.discard) }
                    }

                    Button("Später nochmal") {
                        Task { await environment.decideDiscovery(.later) }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Noch keine Vorschläge",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Hol die meistgesuchten Platten deiner Styles.")
                )
            }

            HStack {
                Button("Nachladen") {
                    Task { await environment.refreshDiscovery() }
                }
                Spacer()
                Text(environment.discoveryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
```

`DecisionKind` kennt genau drei Fälle: `love`, `discard`, `later` (`Graph/GraphTypes.swift:25`). `QueueView` benutzt dieselben.

- [ ] **Step 3: Den Tab einhängen**

In `RootView` hinter dem Player-Tab:

```swift
            DiscoveryView()
                .tabItem { Label("Entdecken", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(3)
```

Der Tag 3 ist frei — Sammlung ist 1, Statistik 2. Die Reihenfolge im `TabView` bestimmt die Anzeige, nicht der Tag.

- [ ] **Step 4: Bauen**

```bash
xcodegen generate
xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Durchspielen**

App starten, Tab „Entdecken", „Nachladen". Erwartet: Karten erscheinen, die Grund-Zeile liest sich als `Deep House · All-Time · 1.204 wollen's`, die Platte spielt. „Auf die Wantlist" schaltet weiter und legt die Platte auf die Discogs-Wantlist. Danach nochmal „Nachladen" — es kommt ein anderer Style oder ein anderes Jahrzehnt, nicht dieselbe Liste.

Zur Gegenprobe alle Styles in den Einstellungen entfernen und nachladen: es muss der Hinweis auf die Einstellungen kommen, kein Fehler.

- [ ] **Step 6: Die ganze Suite laufen lassen**

Run: `cd VinylDiggerKit && swift test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add App VinylDigger.xcodeproj
git commit -m "feat: add the discovery tab"
```

---

## Offene Punkte nach der Umsetzung

- Der Abschlag für bekannte Künstler steht auf 0.5 und ist geraten. Nach ein paar Läufen prüfen, ob zu viel Vertrautes durchkommt, und `DiscoveryRanker.knownArtistFactor` nachziehen.
- `DiscoveryService` wird bei jedem Refresh neu gebaut, damit eine geänderte Style-Liste sofort greift. Wenn der Service später Zustand hält, muss das anders gelöst werden.
