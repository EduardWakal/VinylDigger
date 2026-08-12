# VinylDigger — Player echt machen

**Datum:** 2026-08-06
**Status:** freigegeben, bereit für Implementierungsplan
**Baut auf:** [2026-08-04 Digger Design](2026-08-04-digger-design.md)

## Problem

Der Player der ersten Fassung trägt die Hörschleife nicht.

**Der Fortschrittsbalken ist keine Wiedergabeposition.** `PlayerController.startTicker()`
zählt lokal alle 0,25 s eine Variable hoch, völlig unabhängig davon, was der YouTube-Player
tut. Deshalb lässt sich nicht scrubben — es gibt nichts zu scrubben, nur einen Zähler. Der
Balken lief in der ersten Fassung sogar dann weiter, als überhaupt kein Ton kam.

**Das 60-Sekunden-Hörfenster passt nicht zum Gebrauch.** Es war als Zwang gedacht, damit
keine Karte ohne Entscheidung durchrutscht. In der Praxis will der Nutzer die Platte hören,
nicht einen Ausschnitt.

**Die Karte zeigt zu wenig.** Kein Cover, keine Spuren der Platte, keine Dauer. Man sieht
nicht, was gerade läuft und was noch kommt.

**Der Nachrichtenkanal ist überladen.** `userContentController(_:didReceive:)` behandelt
*jede* Nachricht aus dem JS als „Video kaputt". Sobald der Player mehr als eine Sorte
Nachricht schickt, bricht das.

## Ziel

Der Player verhält sich wie ein Plattenspieler: Spur läuft in voller Länge, danach läuft die
nächste Spur der Platte, am Ende bleibt die Karte stehen und wartet auf die Entscheidung.
Der Balken zeigt die echte Position und lässt sich ziehen. Die Karte zeigt Cover und Spuren.

## Nicht-Ziele

- Wiedergabe außerhalb von YouTube (kein Bandcamp, kein lokales Audio)
- Lautstärkeregelung in der App — YouTube steht auf 100, Systemlautstärke reicht
- Warteschlangen-übergreifendes Abspielen (Karte endet, es geht nicht automatisch weiter)
- Track-Ebene in Entscheidungen oder Wantlist — bleibt eigene Baustelle

## Entscheidungen

**Das Hörfenster fällt ersatzlos weg.** Kein Schalter, keine Option. `windowLength`,
`extendWindow()` und der Slider in den Einstellungen verschwinden. Damit kippt bewusst die
Design-Entscheidung aus dem Ursprungsspec („playback pauses at the end of the listening
window … so no card is ever passed without a decision"). Der Ersatz ist schwächer, aber
ausreichend: am Ende der letzten Spur stoppt die Wiedergabe und die Karte bleibt stehen.

**Spurdauer kommt vom Video, Spurposition von der Tracklist.** Discogs füllt
`tracklist[].duration` in der Praxis oft nicht (bei `/releases/5040318` sind alle drei
Einträge leer), liefert aber `videos[].duration` in Sekunden. Umgekehrt kennt nur die
Tracklist die Positionen `A1`, `B1`.

**Ein Abruf pro Karte, nicht mehr.** `hydrateRating` wird zu `hydrateRelease` und füllt
alles gleichzeitig. Ein Release wird nie zweimal geholt.

## Architektur

### Nachrichtenprotokoll

Der Handler `playerError` wird ersetzt durch einen Kanal `player`, über den typisierte
JSON-Nachrichten laufen:

```json
{"kind": "state", "t": 41.2, "d": 372.0, "state": 1}
{"kind": "error", "code": 152}
```

`state` schickt das JS alle 250 ms per `setInterval`, solange gespielt wird, und zusätzlich
sofort bei jedem `onStateChange` — sonst hinkt Pause oder Trackende bis zu 250 ms nach. Kein
`evaluateJavaScript`-Polling, die Werte kommen von selbst.

Swift veröffentlicht daraus `position: TimeInterval` und `duration: TimeInterval`.
`isPlaying` folgt dem YouTube-State (`1` = playing) statt einer selbst gepflegten Flagge.

### Auto-Durchlauf

YouTube-State `0` (ENDED) → nächstes Video der Platte. Kein weiteres → Stopp.

Die Entscheidung „welches Video kommt als nächstes" wandert als `PlaylistCursor` in den Kit:

```swift
public struct PlaylistCursor: Equatable, Sendable {
    public init(videoIDs: [String])
    public private(set) var index: Int
    public var current: String? { get }
    public mutating func advance() -> String?      // nil am Ende der Platte
    public mutating func select(_ index: Int) -> String?
    public mutating func skipFailed() -> String?   // bei YouTube-Fehler
}
```

Grund: `PlayerController` liegt im App-Target und ist nicht unit-testbar. Im Controller
bleibt nur die WebView-Anbindung, die Logik ist im Kit geprüft.

### Scrubben

Der Balken wird ein `Slider` über `0...duration`, gebunden an `position`.
`onEditingChanged` setzt beim Loslassen `player.seekTo(wert, true)`. Solange gezogen wird,
verwirft der Controller eingehende `state`-Nachrichten — sonst zieht der Regler gegen die
laufenden Updates zurück.

### Daten pro Platte

`hydrateRelease(releaseID:)` schreibt aus einem `/releases/{id}`-Abruf:

| Feld | Quelle | Ablage |
|---|---|---|
| `rating`, `ratingCount`, `want`, `have` | `community` | `release` (vorhanden) |
| `coverURL` | `images[0].uri`, 600×600 | `release.coverURL` (neu) |
| Videotitel | `videos[].title` | `video.title` (vorhanden, bisher leer) |
| Videodauer | `videos[].duration`, Sekunden | `video.duration` (neu) |
| Spurposition | `tracklist[].position` | `video.trackPosition` (neu) |

Migration `v4` ergänzt `release.coverURL TEXT`, `video.duration INTEGER`,
`video.trackPosition TEXT`.

Achtung auf die Namen: `video.position` gibt es schon und meint die Reihenfolge im Bundle
(`Int`, 0-basiert). `video.trackPosition` ist die Discogs-Spurbezeichnung (`"A1"`, `String`).
Zwei verschiedene Dinge, die leicht verwechselt werden.

`DiscogsVideo` bekommt `duration: Int?`, neu dazu `DiscogsImage { uri, uri150 }` und
`DiscogsTrack { position, title, duration }`.

### Video ↔ Spur zuordnen

Reine Funktion im Kit, damit prüfbar:

```swift
public enum TrackMatcher {
    /// Ordnet jedem Video die Spurposition zu, deren Titel im Videotitel steckt.
    /// Kein Treffer → nil, niemals geraten.
    public static func positions(
        videos: [DiscogsVideo], tracklist: [DiscogsTrack]
    ) -> [String?]
}
```

Regel: normalisieren (klein, ohne Satzzeichen), dann trifft eine Spur, wenn ihr Titel im
Videotitel als Teilkette vorkommt. `"BCR035 : Mr G - Toi Toi"` trifft `B1 · Toi Toi`.
Mehrdeutig oder kein Treffer → `nil`, dann zeigt die Karte einfach keine Position an. Eine
falsche Position ist schlimmer als keine.

### Cover-Cache

```swift
public actor CoverStore {
    public init(directory: URL, transport: HTTPTransport)
    public func localURL(for releaseID: Int, remote: URL) async throws -> URL
}
```

Lädt einmal nach `Application Support/VinylDigger/Covers/{releaseID}.jpg`, danach lokal.
Die Bild-URLs liegen auf `i.discogs.com` und sind ohne Auth abrufbar (geprüft: `200`).
Fehlschlag ist kein Fehler der Karte — dann bleibt der Platzhalter stehen.

### Karte

```
┌───────────────────────────────────────┐
│ 3 / 47                    47 in Queue │
│───────────────────────────────────────│
│ ┌──────┐  Mr. G                       │
│ │      │  J's Credit EP               │
│ │ Cover│  Bass Culture · BCR035       │
│ │      │  2013 · Deep House           │
│ └──────┘  ★ 4.45 (29)   ♡ 582         │
│                                       │
│  ▸ A1  Toi Toi                 6:12   │
│    B1  J's Credit              7:04   │
│    B2  Rowdy                   5:48   │
│                                       │
│  ▬▬▬▬▬●───────────────  2:41 / 6:12   │
│  [⏮] [⏴10] [⏸] [10⏵] [⏭]              │
│───────────────────────────────────────│
│ [✗ weg]  [↓ später]      [♥ Wantlist] │
└───────────────────────────────────────┘
```

Spurzeilen sind klickbar und springen direkt auf das Video. Die laufende Spur ist markiert.

`QueueCard` bekommt `coverURL: String?` und `tracks: [QueueTrack]` mit
`QueueTrack { youtubeID, title, position, duration }`. Das bisherige `tracklist: [String]`
entfällt — es hielt nur Videotitel und wird davon abgelöst.

## Fehlerfälle

| Fall | Verhalten |
|---|---|
| Video gesperrt (YouTube-Fehler) | nächstes Video der Platte, wie bisher |
| Kein Video spielbar | „kein Preview", Karte bleibt entscheidbar |
| Kein Cover bei Discogs | Platzhalter, keine Meldung |
| Cover-Download scheitert | Platzhalter, Karte unberührt |
| `hydrateRelease` scheitert | Karte bleibt nutzbar, ohne Cover und Spurdaten |
| `duration` noch 0 | Slider gesperrt bis die erste `state`-Nachricht da ist |

## Tests

Im Kit, also lauffähig unter `swift test`:

- `DiscogsModels`: Bilder, Videodauer, Tracklist dekodieren; fehlende Felder → leer
- `TrackMatcher`: Treffer über Suffix, kein Treffer → `nil`, leere Tracklist → alle `nil`
- `PlaylistCursor`: Vorlauf, Ende der Platte, gezielte Auswahl, Überspringen nach Fehler
- `hydrateRelease`: schreibt Cover, Titel, Dauer, Position; zweiter Aufruf holt nicht erneut
- `CoverStore`: lädt einmal, liefert beim zweiten Mal aus dem Cache
- `AppDatabase`: Migration `v4`, Alt-Zeilen behalten `NULL`

`PlayerController` bleibt ungetestet — WebView-Anbindung, per Hand am laufenden Programm
geprüft. Deshalb ist die Logik bewusst dünn gehalten.

## Offen für später

Track-Ebene in Entscheidungen, Obsidian-Abgleich, Tabs für Sammlung und Statistik, Abgleich
der Dig-Liste gegen Discogs. Jede Baustelle bekommt einen eigenen Spec.
