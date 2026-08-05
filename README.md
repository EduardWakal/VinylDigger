# VinylDigger

A macOS app for auditioning records: it grows a taste graph from a handful of seed
artists, scores Discogs releases against it, and plays the YouTube preview so every
record gets a decision — wantlist, later, or gone.

Personal tool, not App Store material. macOS 14+.

## What is inside

| Path | Contents |
| --- | --- |
| `App/` | SwiftUI app: queue, settings, seeds, history, YouTube player |
| `VinylDiggerKit/` | Swift package: Discogs client, SQLite store, graph, scoring, outbox |
| `docs/superpowers/` | Design spec and the implementation plan the code was built from |

The interesting parts of the package:

- **Graph** — seed artists carry weight 1.0; it decays along alias (0.90), group
  (0.70), artist→label (0.60) and label→artist (0.35) edges. Decisions nudge the
  weights: love +0.25, discard −0.15, owned +0.18.
- **Scoring** — `affinity × (0.7 + 0.3 × demand) × novelty`. Owned and decided
  releases score zero, so they never come back until a "later" date has passed.
- **Queue planning** — no more than three consecutive releases from the same label.
- **Outbox** — wantlist writes survive a dead connection: retried with exponential
  backoff, dropped after five attempts.

## Build and run

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
the `.xcodeproj` is generated, not checked in.

```bash
xcodegen generate
open VinylDigger.xcodeproj     # then hit ⌘R
```

Or straight from the command line:

```bash
xcodegen generate
xcodebuild -project VinylDigger.xcodeproj -scheme VinylDigger -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/VinylDigger-*/Build/Products/Debug/VinylDigger.app
```

Tests:

```bash
cd VinylDiggerKit && swift test
```

## First launch

1. Open Settings (⌘,) and enter a Discogs **personal access token**
   (discogs.com/settings/developers) plus your Discogs **username**. Both go into
   the Keychain, never to disk.
2. Restart the app. It imports the seed dumps from `App/Resources`, syncs your
   collection, and fills the queue.
3. Space toggles playback, `+60 s` extends the listening window, and ← ↓ →
   record discard / later / wantlist.

Data lives in `~/Library/Application Support/VinylDigger/vinyldigger.sqlite`. The app
is deliberately not sandboxed so that path stays readable.
