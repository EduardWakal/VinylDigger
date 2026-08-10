# VinylDigger — Discovery über Style-Charts

**Datum:** 2026-08-10
**Status:** Entwurf, wartet auf Freigabe
**Baut auf:** [Digger Design](2026-08-04-digger-design.md), [Library Design](2026-08-06-library-design.md)

## Problem

Die Queue schlägt immer dieselben Künstler vor.

**Der Kandidatenpool ist geschlossen.** `Scorer` bewertet nur, was schon in der lokalen
Datenbank liegt. Dorthin kommt eine Platte ausschließlich über `QueueService.expand(from:)`:
Künstler der Platte, deren Aliases und Gruppen, deren Discography, deren Labels. Das ist das
Ego-Netzwerk der eigenen Sammlung. Es verlässt die eigene Nachbarschaft nie.

**Die Diversitäts-Logik kann das nicht heilen.** `Scorer` sättigt die Affinität, `QueuePlanner`
bestraft Wiederholungen von Künstler und Label. Beide sortieren aber denselben geschlossenen
Topf um. Ein Re-Ranking repariert keinen leeren Horizont.

**Der Score sperrt Unbekanntes aus.** Der Gesamtscore ist ein Produkt mit
`affinity / (1 + affinity)` als Faktor. Ein Künstler ohne Historie hat Affinität 0, also Score 0.
Selbst wenn eine fremde Platte in der Datenbank landete, käme sie nie in die Queue.

## Ziel

Ein zweiter Weg, auf dem Platten in die App kommen: die meistgesammelten Vinyls je Style,
direkt aus der Discogs-Suche, unabhängig vom eigenen Geschmacksgraphen. Sie erscheinen in
einem eigenen Tab. Was dort gefällt, fließt über den bestehenden Entscheidungs-Pfad in den
Graphen zurück und verbreitert damit auch die normale Queue.

## Nicht-Ziele

- Externe Empfehlungsdienste (Last.fm, ListenBrainz, Spotify). Discogs hat keinen
  Similarity-Endpoint, aber der Kanon je Style reicht als Einstieg. Bewusst zurückgestellt.
- Personalisierung innerhalb des Discovery-Tabs. Er ist absichtlich nicht geschmacksgetrieben.
- Ein Umbau von `Scorer` oder `QueueService`. Die bleiben unverändert.
- Marketplace-Preise oder Verfügbarkeit.

## Was die Discogs-API hergibt

Geprüft gegen die öffentliche Dokumentation, nicht gegen den Live-Dienst:

- **Kein** Endpoint für ähnliche Künstler oder Empfehlungen.
- **Kein** Chart-Endpoint. Ersatz: `/database/search` mit `sort=have&sort_order=desc` — die
  meistgesammelten Platten eines Styles sind faktisch dessen All-Time-Kanon.
- Suchfilter: `genre`, `style`, `year`, `format`, `country`, `label`.
- Treffer tragen `community.have` und `community.want` sowie `master_id`.
- `community.rating.average` gibt es nur pro Release über `/releases/{id}`, nicht als
  Sortierschlüssel der Suche. Deshalb ist Rating hier kein Ranking-Kriterium.

**Diese Annahmen sind vor der Implementierung zu verifizieren** — siehe Risiken.

## Entscheidungen

| Frage | Entscheidung |
|---|---|
| Datenquelle | Nur Discogs. Keine externen Dienste. |
| Styles | Feste, in den Einstellungen editierbare Liste. Vorbelegt: Tech House, House, Deep House, Minimal, Progressive House. |
| Einstieg | Eigener Tab, nicht in die bestehende Queue gemischt. |
| Sortierung | `have` absteigend, rotierend über Styles und Zeitfenster. |
| Zeitfenster | all-time, 1990–1999, 2000–2009, 2010–2019, letzte drei Jahre. |
| Filter | Besessenes und bereits Entschiedenes fliegt raus. Bekannte Künstler bleiben, mit Abschlag. |
| Suchtyp | `type=release`, lokal dedupliziert über `master_id`. |

Zwei davon brauchen eine Begründung.

**`type=release` statt `type=master`.** Ein Master-Treffer trägt keine `main_release`, dafür
wäre je Treffer ein Aufruf von `/masters/{id}` nötig — 50 Aufrufe pro Batch bei einem Limit von
60 pro Minute. Ein Release-Treffer ist dagegen sofort verwendbar, und die Repress-Dubletten
lassen sich lokal über die mitgelieferte `master_id` erschlagen.

**Bekannte Künstler bleiben drin.** Sie ganz auszuschließen wäre die direktere Antwort auf das
Problem, würde aber den Klassiker verstecken, den man von einem bekannten Künstler noch nicht
besitzt. Der Abschlag ist eine einzelne Konstante; wenn wieder zu viel Vertrautes durchkommt,
ist das die Schraube, an der gedreht wird.

## Architektur

Vier neue Einheiten, keine Änderung an bestehenden Bewertungs-Pfaden.

### DiscoveryAxis

Eine Suchachse ist das Tripel `(Style, Zeitfenster, Seite)`. `DiscoveryAxis` erzeugt daraus
eine deterministische Reihenfolge: erst alle Style-mal-Fenster-Kombinationen auf Seite 1, dann
dieselbe Runde auf Seite 2. Ein persistierter Cursor merkt sich die Position, jeder Refresh
rückt eine Stelle weiter.

Rein rechnend, ohne Netzwerk und ohne Datenbank. Eingabe: Style-Liste und aktueller Cursor.
Ausgabe: nächste Achse und neuer Cursor.

### DiscogsClient.searchByStyle

Eine neue Methode am bestehenden Client:

```
/database/search?type=release&format=Vinyl&genre=Electronic
  &style=<Style>&year=<Fenster>&sort=have&sort_order=desc&per_page=50&page=<N>
```

Beim Fenster `all-time` entfällt `year`. Rückgabe ist eine Liste von `DiscogsSearchHit`
(neu in `DiscogsModels`) mit `id`, `masterID`, `title`, `year`, `label`, `catno`, `styles`,
`have`, `want`.

Die Suche liefert Künstler und Titel als einen String `"Artist - Titel"`. Der wird am ersten
` - ` getrennt, der linke Teil ist der Künstlername. Wie in `searchReleases` bleibt der
vollständige String zusätzlich erhalten — die Trennung ist eine Heuristik, und die Hydration
über `/releases/{id}` liefert später die verlässlichen Werte nach. Ein Refresh kostet genau einen Aufruf; der bestehende `RateLimiter` trägt das
ohne Sonderbehandlung.

### DiscoveryRanker

Bewertet einen Batch, unabhängig von `Scorer`:

```
score = log1p(have) / log1p(maxHave)   // Kanon-Rang innerhalb des Batches
      × knownArtistFactor              // 1.0 unbekannt, 0.5 bereits im Graphen
      × novelty                        // 0 wenn besessen oder entschieden
```

„Bereits im Graphen" heißt: der aus dem Treffer gelöste Künstlername steht in der
`artist`-Tabelle. Der Abgleich läuft über den Namen, nicht über eine ID, weil Suchtreffer keine
Künstler-ID tragen — verglichen wird normalisiert, also klein geschrieben und ohne den
Discogs-Zähler-Suffix wie `(2)`. Das trifft nicht jeden Fall; ein verfehlter Abgleich kostet
nur den Abschlag, nicht die Korrektheit.

`novelty` folgt derselben Regel wie in `Scorer`: eine zurückgestellte Platte kommt zurück,
sobald ihr `revisitAt` verstrichen ist. `maxHave` normalisiert gegen den Batch, nicht gegen
ein globales Maximum — sonst spreizt ein Nischen-Style nicht über den Bereich.

Kein Preview-Faktor. Im Batch ist noch nichts hydriert, ein Faktor wäre für alle gleich.

Anschließend läuft `QueuePlanner.plan` unverändert über das Ergebnis. Dessen Künstler- und
Label-Malus verhindert, dass fünf Platten desselben Labels hintereinander stehen.

### DiscoveryService

Der Koordinator, analog zu `QueueService`, aber getrennt davon — `QueueService` ist bereits
groß, und die beiden Pfade teilen keine Zustände.

Ablauf eines Refresh:

1. Style-Liste und Cursor lesen, nächste Achse ziehen.
2. `searchByStyle` aufrufen.
3. Treffer über `masterID` deduplizieren; ohne `masterID` zählt die Release-ID.
4. `DiscoveryRanker` anwenden, dann `QueuePlanner.plan`.
5. Ergebnis nach `discovery_item` schreiben, Cursor fortschreiben.

Bleibt nach dem Filtern nichts übrig, wird die Achse übersprungen und die nächste gezogen,
höchstens dreimal pro Refresh. Danach meldet die Statuszeile, dass nichts Neues kam.

## Daten

Zwei neue Tabellen, Migration im Muster von `AppDatabase`.

`discovery_item` — `releaseID` (Primärschlüssel), `masterID`, `title`, `artistName`, `styles`,
`have`, `want`, `year`, `axisKey`, `rank`, `fetchedAt`. Wird bei jedem Refresh geleert und neu
gefüllt, wie `queue_item`.

`discovery_cursor` — eine einzige Zeile mit `styleIndex`, `windowIndex`, `page`.

Die Style-Liste selbst liegt bei den übrigen Einstellungen, nicht in einer eigenen Tabelle.

## Rückkopplung

Entscheidungen im Discovery-Tab schreiben in das vorhandene `DecisionRecord`. Ein Love landet
damit im Geschmacksgraphen, `expandFromTaste` zieht beim nächsten Lauf die Discography des
neuen Künstlers nach, und die normale Queue wird dadurch breiter.

Das ist der eigentliche Zweck: der Discovery-Tab ist der Einspeiser, den der Graph bisher
nicht hatte. Die bestehende Queue bleibt geschmacksgetrieben, bekommt aber neues Futter.

## Oberfläche

Ein neuer Tab in `RootView`. Kartenlayout und `PlayerController` von `QueueView`
wiederverwendet, damit Abspielen, Herzen und Entscheiden sich identisch anfühlen.

Statt „über Label X" trägt die Karte ihre Herkunft: `Deep House · All-Time · 1.204 haben's`.

In `SettingsView` eine editierbare Style-Liste mit Hinzufügen und Entfernen, vorbelegt mit den
fünf genannten Styles. Eine leere Liste blockiert den Refresh mit einem Hinweis statt still
nichts zu tun.

Hydration — Videos, Rating, Tracklist — läuft über den bestehenden Pfad, ausgelöst pro Karte
beim Anzeigen, nicht für den ganzen Batch auf einmal.

## Fehlerfälle

| Fall | Verhalten |
|---|---|
| Suche schlägt fehl | Letzter Batch bleibt stehen, Statuszeile meldet den Fehler, Cursor rückt nicht vor |
| Rate-Limit | Bestehender Backoff im Client greift; danach wie „Suche schlägt fehl" |
| Batch nach Filtern leer | Nächste Achse, höchstens drei Versuche, dann Meldung |
| Style-Liste leer | Refresh blockiert, Hinweis auf die Einstellungen |
| Treffer ohne `masterID` | Wird behalten, Dedup fällt auf die Release-ID zurück |

## Tests

- `DiscoveryAxis`: die Rotation berührt jede Style-mal-Fenster-Kombination, bevor Seite 2
  beginnt; der Cursor läuft über und beginnt sauber von vorn.
- `DiscoveryRanker`: Besessenes und Entschiedenes fällt auf 0; eine zurückgestellte Platte
  kehrt nach `revisitAt` zurück; ein bekannter Künstler rangiert hinter einem unbekannten mit
  gleichem `have`.
- Dedup: zwei Pressungen desselben Masters ergeben einen Eintrag, die höher gesammelte gewinnt.
- URL-Bau: `year` fehlt bei `all-time` und steht sonst korrekt.
- Decoding gegen eine Fixture, im Muster von `DiscogsClientTests`.

## Risiken

**Die Sortierung ist ungeprüft.** Dass `/database/search` `sort=have` unterstützt und
`community.have` in den Treffern liefert, stammt aus der Dokumentation, nicht aus einem echten
Aufruf. **Erster Schritt der Umsetzung ist ein Spike gegen den Live-Dienst mit echtem Token.**
Trägt die Annahme nicht, sind die Rückfallebenen: `sort=want` als Sortierschlüssel, oder ein
größerer Batch, der lokal nach `have` sortiert wird. Beide ändern das Ranking, nicht die
Architektur.

**Der Kanon ist endlich.** Die Rotation über fünf Styles, fünf Fenster und wachsende Seiten
liefert einige tausend Platten. Für den Anfang genug; bei Erschöpfung wären mehr Styles oder
eine zweite Sortierachse (`want`) die Erweiterung.

**Bekannte Künstler könnten wieder dominieren.** Der Abschlag von 0.5 ist geraten. Falls die
ersten Läufe zu viel Vertrautes zeigen, wird die Konstante gesenkt oder auf 0 gesetzt — das
entspricht dann dem harten Ausschluss.
