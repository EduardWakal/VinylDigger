# VinylDigger — Dig-Session-Export und fester Transport

**Datum:** 2026-08-11
**Status:** Entwurf, wartet auf Freigabe
**Baut auf:** [Library Design](2026-08-06-library-design.md), [Player Design](2026-08-06-player-design.md), [Discovery Design](2026-08-10-discovery-design.md)

## Problem

Zwei Dinge stehen der täglichen Nutzung im Weg.

**Die Suchliste wächst monoton.** `ObsidianRenderer.renderSearchList` bekommt jedes Mal
`QueueService.likedTracks()`, also *jeden* je markierten Track, und schreibt das Ergebnis in
immer dieselbe Notiz `Vinyl - Gesuchte Tracks.md`. Nach der dritten Grabungsrunde steht dort
zu neunzig Prozent, was längst heruntergeladen ist. Die Häkchen des letzten Durchgangs sind
beim Überschreiben weg, also lässt sich Abgearbeitetes nicht einmal manuell aussortieren.

**Platten aus der eigenen Sammlung landen in der Suchliste.** Eine Platte, die man besitzt,
kann in der App auftauchen und angehört werden; ein Herz auf einer ihrer Spuren schreibt eine
Suchzeile für etwas, das im Regal steht.

**Der Transport hängt an einem Tab.** `TransportView` liegt in `QueueView`. Wer im Entdecken-
Tab eine Platte startet und zur Sammlung wechselt, hört zwar weiter, hat aber keine Pause,
keinen Slider und keine Möglichkeit die laufende Spur zu markieren. Der `PlayerHost` wurde
genau deshalb schon aus `QueueView` herausgezogen und auf die `TabView` gehängt — die
Bedienung ist ihm dabei nicht gefolgt.

## Ziel

Ein Export, der genau die Ausbeute einer Grabungsrunde als eigene Notiz in den Vault legt und
nichts wiederholt. Ein Transport, der zum Fenster gehört und nicht zu einem Tab.

## Nicht-Ziele

- Ein Session-Objekt mit Start und Ende. Der Export ist der Schnitt, siehe unten.
- Abgleich mit der Obsidian-Notiz `Musiksammlung - Trackliste`. Die App würde eine fremde
  Notiz parsen müssen; zurückgestellt.
- Cover oder aufklappbare Trackliste in der Transportleiste.
- Ein Umbau des zweiten Exports (`Vinylsammlung.md`). Der bleibt unverändert.

## Teil 1 — Dig-Session-Export

### Der Export ist der Schnitt

Es gibt keinen Knopf, der eine Session öffnet. Eine Session ist die Menge der Tracks, die seit
dem letzten Export markiert wurden. Das hat drei Vorteile gegenüber einem expliziten Start:
Es kann nicht vergessen werden, es überlebt einen App-Neustart, und es gibt keinen Zustand,
der mit der Datenbank aus dem Tritt geraten kann.

`TrackLikeRecord` trägt bereits `likedAt`. Es fehlt nur die Gegenseite: wann zuletzt
exportiert wurde.

### Schema

Migration `v13` legt `export_cursor` an, eine Singleton-Tabelle nach dem Muster von
`discovery_cursor`:

```
export_cursor
  id             INTEGER PRIMARY KEY   -- immer 1
  lastExportedAt DATETIME NOT NULL
```

Dazu `ExportCursorRecord` in `Store/Records.swift` mit `singletonID`, gespiegelt an
`DiscoveryCursorRecord`. Fehlt die Zeile, gilt der Export als nie gelaufen.

### Auswahl

Neu in `Session/Library.swift`:

```swift
public nonisolated func digSession(until: Date) throws -> [LikedTrack]
```

Regeln, in dieser Reihenfolge:

1. `likedAt > lastExportedAt`, sofern ein Cursor existiert. Sonst alles.
2. `likedAt <= until`. `until` ist der Zeitstempel, mit dem der Export läuft. Ohne diese
   Obergrenze könnte ein Like, der während des Schreibens gesetzt wird, vom fortgeschriebenen
   Cursor überholt und nie exportiert werden.
3. Releases mit `owned == true` fallen raus. Das sind die Platten der Discogs-Sammlung —
   was im Regal steht, muss nicht gesucht werden.
4. Sortierung wie bisher: `likedAt` absteigend.

`likedTracks()` bleibt daneben unverändert bestehen. `renderRecords` markiert damit die ♥ in
der Plattenliste und braucht dort weiterhin *alle* Likes, nicht nur die der laufenden Session.

### Schreiben

`ObsidianDocument` verliert `searchList` und bekommt `digSession(Date)`. Der Fall trägt ein
Datum, also fällt der `String`-RawValue weg; an seine Stelle tritt

```swift
public var filename: String
```

- `.records` → `"Vinylsammlung.md"`
- `.digSession(date)` → `"Vinyl - Dig 2026-08-11.md"`

Zwei Exporte am selben Tag dürfen sich nicht überschreiben. Das Auflösen eines freien Namens
braucht das Dateisystem und gehört deshalb in `ObsidianWriter`, nicht in den bewusst reinen
`ObsidianRenderer`. `ObsidianDocument` bekommt dafür

```swift
public var overwrites: Bool   // .records true, .digSession false
```

Ist `overwrites` falsch und der Name belegt, hängt der Writer ` (2)`, ` (3)` … an, bis ein
freier Name gefunden ist. `write` gibt die tatsächlich geschriebene URL zurück, damit der
Status den echten Dateinamen nennen kann.

Mit dem RawValue fällt auch `CaseIterable` weg — beides wird nirgends benutzt. Die zwei
Stellen, die heute `document.rawValue` lesen, sind `ObsidianWriter.write` (nimmt künftig
`filename`) und der Statustext in `AppEnvironment` (nimmt künftig den Namen der
zurückgegebenen URL).

`ObsidianRenderer.renderSearchList` wird zu `renderDigSession(likes:generatedAt:)`. Der Aufbau
je Track bleibt wie er ist — Checkbox mit Suchzeile, darunter Platte, Label und Position,
darunter der YouTube-Link. Nur der Kopf ändert sich: statt „Stand: …" steht dort
„Session vom …" mit der Zahl der Tracks.

### Ablauf und Fehlerfall

`AppEnvironment.exportToObsidian` für den Session-Fall:

1. `now = Date()`
2. `likes = try service.digSession(until: now)`
3. Ist `likes` leer: **keine Datei schreiben**, Status „nichts Neues seit dem letzten Export",
   Cursor bleibt stehen.
4. Rendern, schreiben.
5. Erst nach erfolgreichem Schreiben `lastExportedAt = now` setzen.

Schlägt Schritt 4 fehl, bleibt der Cursor stehen und die Tracks kommen beim nächsten Versuch
wieder. Ein leerer Export legt keine leere Notiz an — sonst sammeln sich im Vault Dateien,
die nichts enthalten.

### Bedienung

In der Toolbar der Statistik heißt der erste Knopf künftig „Dig-Session" und trägt die Zahl
der offenen Tracks, etwa `Dig-Session (12)`. Die Zahl kommt aus `digSession(until: Date())`
und wird mit dem übrigen Inhalt der Ansicht neu geladen. Bei null offenen Tracks ist der
Knopf inaktiv. Der zweite Knopf, „Platten + Tracklisten", bleibt unverändert.

## Teil 2 — Transport als Teil des Rahmens

### Verschiebung

`TransportView` ist heute eine `private struct` in `QueueView.swift`. Sie zieht nach
`App/TransportView.swift` und wird `internal`. `RootView` mountet sie unter der `TabView`,
neben dem `PlayerHost`, der dort bereits liegt:

```
VStack {
    TabView(selection: $tab) { … }
    Divider()
    TransportView(player: environment.player) { environment.likeCurrentlyPlaying() }
}
.background(PlayerHost(controller: environment.player)…)
```

`QueueView` verliert Transport und den zugehörigen Divider und behält Kopfzeile, Card und
Entscheidungsknöpfe. Der erste Tab heißt künftig **Digliste** statt Player — er ist jetzt
nur noch die geschmacksgetriebene Liste, das Abspielen gehört ihm nicht mehr allein.

### Ein Fehler, den die Verschiebung offenlegt

`likeCurrentlyPlaying()` sucht die laufende Spur ausschließlich in `cards`:

```swift
guard let card = cards.first(where: { $0.videoIDs.contains(id) }) else { return }
```

Läuft eine Platte aus dem Entdecken-Tab oder aus der Sammlung, greift das ins Leere und das
Herz tut nichts. Solange die Leiste nur in Tab 1 stand, fiel das kaum auf. Eine immer
sichtbare Leiste macht es zum offenen Fehler. Die Suche geht künftig über `cards`,
`discoveryCards` und `inspected`.

### Tastenkürzel

Die Leiste bringt `Leertaste`, `[`, `]` und `l` mit. Bisher galten sie nur, solange Tab 1
vorn war; künftig gelten sie im ganzen Fenster — auch während in der Statistik ein Gewicht in
ein Textfeld getippt wird. SwiftUI gibt fokussierten Textfeldern bei modifierlosen Kürzeln
nicht zuverlässig Vorrang.

Bewusste Entscheidung: die Kürzel bleiben ohne Modifier, weil die Leertaste beim Digging das
meistgenutzte ist. Stört es in der Statistik tatsächlich, wird nachgebessert — nicht vorher.

## Tests

Im Kit, wo die Logik liegt:

- `digSession` liefert beim allerersten Aufruf alle Likes.
- `digSession` liefert nach gesetztem Cursor nur die neueren.
- `digSession` lässt Tracks von Releases mit `owned == true` weg.
- `digSession` lässt einen Like aus, der nach `until` gesetzt wurde.
- `renderDigSession` schreibt Kopf und je Track drei Zeilen; leere Eingabe ergibt den
  Hinweistext statt einer leeren Liste.
- `ObsidianWriter` weicht bei belegtem Namen auf ` (2)` aus und gibt die geschriebene URL
  zurück; `.records` überschreibt weiterhin.

Die App-Schicht hat kein Testziel. `RootView`, `TransportView` und der Griff auf
`discoveryCards` in `likeCurrentlyPlaying` werden im laufenden Programm geprüft.

## Offene Enden

- Wird ein Track nach dem Export wieder entmarkiert, bleibt er in der geschriebenen Notiz
  stehen. Die Notiz ist eine Momentaufnahme; das ist gewollt.
- Der Cursor lässt sich nicht zurücksetzen. Nötig wäre dafür ein Knopf, der bewusst
  zurückgestellt wird, bis er fehlt.
