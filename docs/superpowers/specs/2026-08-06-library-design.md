# VinylDigger — Sammlung, Track-Likes, Obsidian, Dig-Liste

**Datum:** 2026-08-06
**Status:** freigegeben, bereit für Implementierungsplan
**Baut auf:** [Player Design](2026-08-06-player-design.md)

## Problem

Die App kann Platten finden und vorspielen, aber nicht zeigen, was dabei herausgekommen ist.

**Nichts ist auffindbar.** Verlauf und Seeds liegen in eigenen `Window`-Szenen, erreichbar nur
über das Fenster-Menü, ohne Kürzel. Der Nutzer hat sie nicht gefunden.

**Der Verlauf trennt nicht.** ♥, ✗ und ↓ stehen gemischt in einer Liste. „Was habe ich
geliked" lässt sich nicht beantworten.

**Es gibt keine Track-Ebene.** Entschieden wird über ganze Platten, weil Discogs nur das
kennt. Auf einer EP mit vier Spuren trägt aber oft eine. Diese Information geht verloren.

**Die Gewichte sind nur Anzeige.** Der Graph zieht in eine Richtung, aber der Nutzer kann
nicht gegensteuern.

**Der Vault weiß nichts davon.** Die Musiksammlung in Obsidian ist die Referenz für „hab ich
das schon", Vinyl kommt darin nicht vor.

## Ziel

Ein Fenster mit drei Tabs. Track-Likes als eigene Ebene unter der Platte. Ein Knopf, der
beides in den Obsidian-Vault schreibt. Und ein Weg, die abgetippte Dig-Liste in echte
Discogs-Releases zu überführen.

## Nicht-Ziele

- Rückweg aus Obsidian in die App — der Vault ist Ziel, nicht Quelle
- Track-Likes an Discogs schicken (die API kennt keine)
- Automatisches Übernehmen von Suchtreffern ohne Bestätigung
- Rekordbox-Abgleich (macht die bestehende Musiksammlung)

## Entscheidungen

**Die Sammlung sind die Entscheidungen.** Die Discogs-Collection ist leer, also ist sie kein
tragfähiger Inhalt. Der Tab zeigt ♥ / ↓ / ✗ / besessen als umschaltbare Filter über den
Entscheidungen. „Besessen" bleibt vorerst leer und füllt sich, sobald die Collection es tut.

**Track-Likes sind lokal.** Eigene Tabelle, kein Discogs. Ein ♥ auf der Platte schreibt
weiterhin die ganze Platte in die Wantlist — daran ändert sich nichts.

**Obsidian bekommt zwei Notizen** nach dem Muster der Musiksammlung: `Vinylsammlung.md` mit
Übersicht und Statistik, `Vinylsammlung - Trackliste.md` mit der vollen Liste. Getrennt von
der bestehenden Musiksammlung.

**Der Export überschreibt nur den oberen Teil.** Alles unterhalb der Markierung
`<!-- ab hier von Hand -->` bleibt unangetastet. Fehlt die Markierung, wird sie angelegt.

**Die Dig-Liste wird vorgeschlagen, nicht übernommen.** Freitext gegen einen Katalog trifft
nicht zuverlässig. Jede Zeile bekommt Treffer zur Auswahl; erst die Bestätigung schreibt.

## Architektur

### Schema

| Migration | Inhalt |
|---|---|
| `v7` | Tabelle `track_like` (`releaseID`, `youtubeID`, `likedAt`), eindeutig über beide IDs |
| `v8` | `artist.manualWeight REAL`, `label.manualWeight REAL` — beide nullable |

`manualWeight` überschreibt das errechnete Gewicht, wenn gesetzt. `NULL` heißt „Graph
entscheidet". Damit bleibt eine Justierung erhalten, auch wenn der Graph nachwächst.

### Kit

```swift
public struct TrackLikeRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var releaseID: Int
    public var youtubeID: String
    public var likedAt: Date
}

extension QueueService {
    /// Returns the new state.
    @discardableResult
    public nonisolated func toggleTrackLike(releaseID: Int, youtubeID: String) throws -> Bool
    public nonisolated func likedTracks() throws -> [LikedTrack]
    public nonisolated func library(kind: DecisionKind?) throws -> [LibraryEntry]
    public nonisolated func setManualWeight(_ weight: Double?, artist: Int) throws
    public nonisolated func setManualWeight(_ weight: Double?, label: Int) throws
}

public struct LikedTrack: Equatable, Sendable {
    public let releaseID: Int
    public let releaseTitle: String
    public let artistName: String
    public let labelName: String?
    public let trackPosition: String?
    public let trackTitle: String?
    public let youtubeID: String
    public let likedAt: Date
}

public struct LibraryEntry: Equatable, Sendable {
    public let release: ReleaseRecord
    public let labelName: String?
    public let kind: DecisionKind
    public let decidedAt: Date
    public let likedTrackCount: Int
}
```

`QueueTrack` bekommt `liked: Bool`.

### Obsidian-Export

```swift
public struct ObsidianExport: Equatable, Sendable {
    public let overview: String     // Vinylsammlung.md
    public let tracklist: String    // Vinylsammlung - Trackliste.md
}

public enum ObsidianRenderer {
    public static let handMarker = "<!-- ab hier von Hand -->"

    public static func render(
        library: [LibraryEntry], likes: [LikedTrack], generatedAt: Date
    ) -> ObsidianExport

    /// Keeps everything from `handMarker` onwards out of the app's hands.
    public static func merge(rendered: String, into existing: String?) -> String
}

public actor ObsidianWriter {
    public init(directory: URL)
    public func write(_ export: ObsidianExport) throws
}
```

`ObsidianRenderer` ist rein und damit testbar. `ObsidianWriter` macht nur Dateizugriff.
Zielverzeichnis `~/Obsidian/Schakal/Musik`. Die App ist nicht sandboxed, der Zugriff ist frei.

Die Übersicht führt: Anzahl je Entscheidung, Top-Labels, Top-Artists, Jahre. Die Trackliste
führt Platten nach Label gruppiert, darunter die markierten Spuren, Wikilinks auf
`[[Musiksammlung]]` und `[[Dig Minimal-House Vinyl]]`.

### Dig-Liste abgleichen

```swift
public struct DigLine: Equatable, Sendable {
    public let raw: String
    public let artist: String?
    public let title: String
}

public enum DigParser {
    /// Splits "Artist - Title" and strips catalogue prefixes such as "BCR035 : ".
    public static func parse(_ text: String) -> [DigLine]
}

extension DiscogsClient {
    public func searchReleases(artist: String?, title: String) async throws -> [DiscogsReleaseSummary]
}
```

Der Nutzer sieht je Zeile bis zu fünf Treffer und wählt einen oder verwirft die Zeile.
Bestätigte Treffer laufen durch den bestehenden `decide(releaseID:kind: .love)` — damit
greifen Wantlist-Schreibung, Outbox und Graph-Erweiterung unverändert.

### Oberfläche

`RootView` mit `TabView`, drei Tabs:

| Tab | Inhalt |
|---|---|
| **Player** | die bestehende `QueueView` |
| **Sammlung** | Filter ♥ / ↓ / ✗ / besessen, Liste mit Cover, Bewertung, Anzahl markierter Spuren |
| **Statistik** | Artists und Labels mit Gewicht, von Hand überschreibbar; Obsidian-Knopf; Dig-Liste einlesen |

Die bestehenden Fenster „Seeds" und „Verlauf" entfallen — ihr Inhalt geht in die Tabs.

In der Spurliste bekommt jede Zeile einen Stern. Taste `L` markiert die laufende Spur.

## Fehlerfälle

| Fall | Verhalten |
|---|---|
| Vault-Verzeichnis fehlt | Meldung im Statistik-Tab, kein Schreibversuch |
| Obsidian-Datei nicht schreibbar | Fehler im Status, bestehende Datei bleibt unberührt |
| Suche liefert nichts | Zeile bleibt offen und wird als „kein Treffer" markiert |
| Suche schlägt fehl | Zeile bleibt offen, Fehler im Status, Rest läuft weiter |
| Manuelles Gewicht gelöscht | `NULL`, der Graph übernimmt wieder |
| Track-Like auf unbekanntem Video | wird ignoriert, kein Eintrag |

## Tests

- `TrackLikeRecord`: Round-Trip, doppeltes Like wird abgewiesen, Toggle schaltet zurück
- `library(kind:)`: filtert, zählt markierte Spuren, sortiert nach Datum
- `setManualWeight`: setzt, überschreibt Graph-Gewicht, `nil` gibt zurück
- `ObsidianRenderer.render`: Übersicht und Trackliste aus bekannten Daten
- `ObsidianRenderer.merge`: bewahrt Handteil, legt Markierung an wenn sie fehlt, leere Datei
- `ObsidianWriter`: schreibt zwei Dateien, überschreibt nur den verwalteten Teil
- `DigParser`: "Artist - Title", Katalogpräfix, Zeile ohne Artist, Klammerzusätze
- `searchReleases`: Query-Aufbau, leeres Ergebnis
- Migrationen `v7`/`v8` inklusive Vorbelegung

Die Oberfläche selbst bleibt ungetestet und wird am laufenden Programm geprüft.
