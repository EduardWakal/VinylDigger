import SwiftUI
import VinylDiggerKit

struct QueueView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if let card = environment.currentCard {
                cardBody(card)
            } else {
                ContentUnavailableView(
                    "Queue leer",
                    systemImage: "opticaldisc",
                    description: Text("Entscheide ein paar Releases, damit der Graph nachwachsen kann.")
                )
                .frame(maxHeight: .infinity)
            }
            Divider()
            controls
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 640)
        .background(PlayerHost(controller: environment.player).frame(width: 1, height: 1))
        .task { await environment.start() }
    }

    private var header: some View {
        HStack {
            Text("\(environment.currentIndex + 1) / \(max(environment.cards.count, 1))")
                .font(.system(.caption, design: .monospaced))
            Spacer()
            Text(environment.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cardBody(_ card: QueueCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.artistName)
                .font(.title2.weight(.semibold))
            Text(card.title)
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let label = card.labelName { Text(label) }
                if let catno = card.catno { Text(catno) }
                if let year = card.year { Text(String(year)) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Text(card.styles.joined(separator: " · "))
                Spacer()
                Label("\(card.want)", systemImage: "heart")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if card.videoIDs.isEmpty {
                Label("kein Preview", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                TransportView(player: environment.player)
            }

            Text("warum: \(card.reason)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("✗ weg") { Task { await environment.decide(.discard) } }
                .keyboardShortcut(.leftArrow, modifiers: [])

            Button("↓ später") { Task { await environment.decide(.later) } }
                .keyboardShortcut(.downArrow, modifiers: [])

            Spacer()

            Button("♥ Wantlist") { Task { await environment.decide(.love) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .disabled(environment.currentCard == nil)
    }
}

/// Observes the player directly — SwiftUI does not follow an ObservableObject
/// held inside another one, so reading it through AppEnvironment would leave the
/// progress bar and the play/pause label frozen.
private struct TransportView: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: min(player.elapsed, player.windowLength),
                total: player.windowLength
            )
            HStack {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("+60 s") { player.extendWindow() }
                Button("nächstes Video") { player.nextVideo() }
                Spacer()
                Text(String(format: "%.0f / %.0f s", player.elapsed, player.windowLength))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
