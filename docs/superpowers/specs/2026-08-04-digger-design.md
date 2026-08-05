# VinylDigger — Design

**Datum:** 2026-08-04
**Status:** freigegeben, bereit für Implementierungsplan

## Problem

Underground-Minimal/Deep-House auf Vinyl lässt sich nicht über Streaming-Kataloge oder
Fingerprinting finden. Shazam kennt die Platten nicht, und Empfehlungsalgorithmen der
Streamingdienste haben die Releases gar nicht im Bestand.

Was funktioniert, ist manuelles Digging über Discogs: von einem bekannten Track zu seinem
Label, von dort zu weiteren Artists, über deren Aliase zu weiteren Labels. Das ist
erwiesenermaßen tragfähig — eine manuelle Runde über vier Seed-Tracks (Carl Finlow –
Islands, Tyler Stadius – This Is How We Are, Kelvin K – G's Groove, Jamie Anderson –
Bolivian Nights) hat 20:20 Vision, Artform, NRK Sound Division und Nordic Trax als
tragende Adern freigelegt.

Der Flaschenhals ist nicht das Finden von Kandidaten, sondern der **Hördurchsatz**:
Kandidaten anhören, in Sekunden entscheiden, und aus dieser Entscheidung die nächsten
Kandidaten ableiten.

## Ziel

Eine macOS-App, die diese Schleife trägt:

1. füllt eine Warteschlange aus Discogs-Releases, abgeleitet aus bekannten Seeds
2. spielt zu jedem Release direkt einen Ausschnitt ab
3. nimmt eine Entscheidung entgegen (verwerfen / später / Wantlist)
4. schreibt ♥ in die echte Discogs-Wantlist
5. leitet aus jeder Entscheidung die nächsten Vorschläge ab

## Nicht-Ziele

- Audio-Fingerprinting oder Track-ID aus Mixes
- Marketplace-Käufe, Preisüberwachung, Bestellabwicklung
- Mehrbenutzer, Sync zwischen Geräten, iOS-Begleiter
- Empfehlungen jenseits des Discogs-Datenbestands (kein Bandcamp, kein Beatport)

## Architektur

Native SwiftUI-App, macOS 14+, XcodeGen-Projekt analog PaceForge.
Bundle-ID `de.schakal.VinylDigger`, Projektwurzel `~/Developer/Digger`.

```
VinylDigger.app
├── App/                  SwiftUI, dünn — nur Darstellung und Eingabe
│   ├── QueueView         Hauptschleife: Karte, Transport, ✗ ↓ ♥
│   ├── PlayerController  WKWebView + YouTube IFrame Player API
│   ├── SeedsView         Seeds verwalten, Graph-Gewichte einsehen
│   ├── HistoryView       Entscheidungen ansehen, rückgängig machen
│   └── SettingsView      Token, Filter (Jahr, Style, Want-Schwelle)
│
└── VinylDiggerKit/            Swift Package — die gesamte Logik
    ├── DiscogsAPI        URLSession + Codable, Token-Bucket, Cache, Retry
    ├── Store             GRDB/SQLite — Persistenz, sonst nichts
    ├── GraphEngine       Expansion + Scoring — kein Netz, keine DB, kein UI
    ├── Outbox            ausstehende Schreibvorgänge, Wiederholung mit Backoff
    └── Secrets           Keychain-Zugriff für den Token
```

### Warum diese Schnitte

`GraphEngine` bekommt einen Graphen und Entscheidungen herein und gibt gewichtete
Kandidaten heraus. Keine Seiteneffekte, kein I/O. Genau der Teil, dessen Fehler sonst
unsichtbar und teuer wären, ist damit vollständig testbar.

`DiscogsAPI` kennt nur die HTTP-Schnittstelle und Codable-Modelle, nichts über Graphen
oder Bewertung. `Store` persistiert und interpretiert nicht. Die App-Schicht enthält
keine Bewertungslogik.

### Speicherorte

| Was | Wo |
|---|---|
| Datenbank | `~/Library/Application Support/VinylDigger/vinyldigger.sqlite` |
| API-Cache | `~/Library/Caches/de.schakal.VinylDigger/` |
| Personal Access Token | Keychain |

Der Token wird nie in der Datenbank, nie in einer Konfigurationsdatei und nie im
Repository abgelegt.

## Datenmodell

| Tabelle | Inhalt |
|---|---|
| `artist` | Discogs-ID, Name, Gewicht, letzte Aktualisierung |
| `label` | Discogs-ID, Name, Gewicht, letzte Aktualisierung |
| `release` | Discogs-ID, Titel, Jahr, Katalognummer, Styles, want, have, hydratisiert-Flag |
| `video` | Release-ID, YouTube-ID, Titel, Position, Verfügbarkeitsstatus |
| `edge` | von-Knoten, nach-Knoten, Typ, Dämpfungsfaktor |
| `decision` | Release-ID, Art (♥/✗/↓), Zeitstempel, Wiedervorlagedatum |
| `queue_item` | Release-ID, Score, Rang, Begründung |
| `outbox` | ausstehende Discogs-Schreibvorgänge, Versuchszähler |

## Graph und Bewertung

**Knoten:** Artist, Label, Release.
**Kanten:** Alias, Gruppenmitgliedschaft, Artist→Label, Release→Artist, Release→Label.

Gewicht fließt von den Seeds nach außen, je Kantentyp gedämpft:

```
w(seed) = 1.0
w(kind) = w(eltern) × dämpfung(kantentyp)

  alias              × 0.90
  gruppe/mitglied    × 0.70
  artist → label     × 0.60
  label → artist     × 0.35

Expansionstiefe: maximal 3
```

Beispiel: Carl Finlow (1.0) → 20:20 Vision (0.60) → Inland Knights (0.21). Ein direkter
Alias wie Random Factor liegt mit 0.90 deutlich darüber — gewollt.

**Score eines Release:**

```
affinität = Σ w(zugehörige Artists + Label)
nachfrage = log1p(want) / log1p(maxWant)          Wertebereich 0…1
score     = affinität × (0.7 + 0.3 × nachfrage) × neuheit
```

`maxWant` ist die höchste want-Zahl innerhalb des aktuellen Kandidatenpools, nicht ein
globaler Wert. Damit bleibt die Normalisierung auch dann sinnvoll, wenn eine Ader
insgesamt weniger begehrt ist als eine andere.

`neuheit` ist 1 für unentschiedene Releases und 0 für Releases, die bereits mit ♥ oder ✗
entschieden wurden oder in der Collection liegen. Ein mit ↓ zurückgestelltes Release hat
`neuheit = 0` bis zu seinem Wiedervorlagedatum und danach wieder 1 — es kehrt also
regulär in die Bewertung zurück.

Die Nachfrage geht mit höchstens 30 % ein — andernfalls verdrängen die begehrtesten
Platten alles andere.

**Entscheidungen verschieben Gewichte:**

| Aktion | Wirkung |
|---|---|
| ♥ | +0.25 auf Artist und Label des Release; Release wird Expansions-Seed |
| ✗ | −0.15 auf Artist und Label |
| ↓ später | neutral, Wiedervorlage nach 30 Tagen |
| in Collection vorhanden | +0.18 (implizites Signal, schwächer als bewusstes ♥) |

Knotengewichte werden auf `[0.0, 2.0]` begrenzt, damit einzelne Adern nicht entgleisen.

**Vielfalt-Bremse:** höchstens 3 Releases desselben Labels in Folge in der Queue.

## Ablauf

```
Start
 └─ Token aus Keychain → Collection + Wantlist synchronisieren
     └─ GraphEngine berechnet Scores aus dem Store          (kein Netz)
         └─ QueueBuilder: Top 50, Vielfalt-Bremse angewandt
             └─ fehlende Release-Details nachladen
                — nur für Queue-Einträge, nicht für den ganzen Graphen
                 └─ Karte anzeigen, erstes Video ab 0:00, 60-Sekunden-Fenster
                     └─ Entscheidung ✗ ↓ ♥
                         ├─ Store: decision schreiben
                         ├─ bei ♥: Wantlist-POST über die Outbox
                         └─ bei ♥: Expansion — Aliase, Gruppen und Labels
                             des Artists holen, neue Knoten und Kanten anlegen
                                 └─ neu bewerten, Queue nachfüllen
```

**Lazy Hydration** ist zentral: Der Graph wächst über die günstigen Listen-Endpunkte
(`/artists/{id}/releases`, `/labels/{id}/releases`), die Label, Jahr und Titel bereits
mitliefern. Die teuren Einzelabrufe (`/releases/{id}` für want-Zahl, Videos, Tracklist)
erfolgen ausschließlich für Releases, die tatsächlich in der Queue landen.

## Discogs-Anbindung

Authentifizierung über **Personal Access Token** (`Authorization: Discogs token=…`).
Kein OAuth-Flow, keine Zugangsdaten des Nutzers in der App.

| Endpunkt | Zweck |
|---|---|
| `GET /artists/{id}` | Aliase, Gruppen |
| `GET /artists/{id}/releases` | Releases mit Label und Jahr |
| `GET /labels/{id}/releases` | Labelkatalog |
| `GET /releases/{id}` | want/have, Videos, Tracklist, Styles |
| `GET /database/search` | Seeds auflösen |
| `GET /users/{user}/collection/folders/0/releases` | Collection lesen |
| `GET /users/{user}/wants` | Wantlist lesen |
| `PUT /users/{user}/wants/{release_id}` | Wantlist schreiben |

Rate-Limit: 60 Anfragen pro Minute authentifiziert. Ein Token-Bucket drosselt vorab;
die Antwort-Header `X-Discogs-Ratelimit-Remaining` korrigieren den Füllstand nach.
Ein eigener User-Agent ist Pflicht.

## Audio

Discogs liefert an jedem Release die verknüpften YouTube-Videos mit. Wiedergabe über
eine `WKWebView` mit der YouTube IFrame Player API; die WebView ist nicht sichtbar und
dient nur als Abspielmotor. Transport, Fortschritt und Tastatursteuerung sind nativ in
SwiftUI und sprechen die WebView über JavaScript-Aufrufe an (`playVideo`, `pauseVideo`,
`seekTo`).

Standardfenster: 60 Sekunden ab Videostart. Läuft es ab, pausiert die Wiedergabe und die
Karte bleibt stehen — sie springt nicht selbsttätig weiter, damit keine Entscheidung
verpasst wird. Weiterhören verlängert um jeweils 60 Sekunden. Die Fensterlänge ist in den
Einstellungen zwischen 30 und 120 Sekunden einstellbar.

Mehrere Videos pro Release sind als Tracklist durchschaltbar; ein Wechsel setzt das
Zeitfenster zurück.

## Fehlerbehandlung

| Fall | Verhalten |
|---|---|
| 429 Rate-Limit | Token-Bucket bremst vorab; bei Treffer exponentielles Backoff, Statuszeile zeigt Drosselung |
| Offline | Queue läuft aus dem Cache weiter; Entscheidungen gehen in die Outbox und werden später nachgezogen |
| Release ohne Video | Kennzeichnung „kein Preview", ans Ende sortiert; per Filter ausblendbar |
| YouTube-Video gesperrt oder entfernt | automatisch zum nächsten Video des Release; ist keins übrig, als preview-los markieren |
| Token ungültig oder fehlend | Einstellungen öffnen mit klarem Hinweis; App bleibt aus dem Cache lesefähig |
| Discogs-Schreibvorgang scheitert | Outbox behält den Eintrag, erneuter Versuch mit Backoff; Fehler nach 5 Versuchen sichtbar gemeldet |

## Tests

Schwerpunkt auf `GraphEngine`, weil dessen Fehler unsichtbar bleiben und sich über die
Zeit aufsummieren.

- **GraphEngine** — reine Unit-Tests gegen einen Fixture-Graphen: Dämpfung je Kantentyp,
  Tiefenbegrenzung, Gewichtsgrenzen, Wirkung der Entscheidungsarten, Vielfalt-Bremse,
  Determinismus bei gleicher Eingabe.
- **DiscogsAPI** — Tests gegen aufgezeichnete JSON-Fixtures, kein Live-Netz. Als Fixtures
  dienen die vorhandenen Dumps aus der manuellen Vorarbeit.
- **Store** — Migrationen und Round-Trip je Entität.
- **Outbox** — Wiederholung nach simuliertem Netzausfall, Versuchszähler, Aufgabe nach
  Höchstzahl.

Keine UI-Snapshot-Tests.

## Bootstrap

Die JSON-Dumps der manuellen Vorarbeit (`dig_profile.json`, `dig_labels.json`) werden
einmalig importiert. Damit startet die App mit vier Seeds, deren Alias-Karte und sechs
bereits erschlossenen Labels statt bei null.

## Offene Punkte

Keine. Der Entwurf ist freigegeben.
