import SwiftUI
import VinylDiggerKit

/// The record as it appears on screen — sleeve, title, styles, rating, tracks.
/// Shared by the player queue and the discovery tab; neither owns it.
struct RecordCardView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let card: QueueCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CoverView(
                    releaseID: card.releaseID, remote: card.coverURL, store: environment.covers
                )

                VStack(alignment: .leading, spacing: 4) {
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

                    HStack(spacing: 12) {
                        Text(card.styles.joined(separator: " · "))
                        if let rating = card.rating {
                            Label(
                                String(format: "%.2f (%d)", rating, card.ratingCount),
                                systemImage: "star.fill"
                            )
                        }
                        Label("\(card.want)", systemImage: "heart")
                        Link(
                            "Discogs",
                            destination: URL(
                                string: "https://www.discogs.com/release/\(card.releaseID)"
                            )!
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if card.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("kein Preview", systemImage: "speaker.slash")
                    Text("Discogs führt für diese Pressung kein Video — bei einer anderen Pressung derselben Platte kann eines liegen.")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                TrackList(
                    releaseID: card.releaseID,
                    tracks: card.tracks,
                    player: environment.player,
                    onToggleLike: { environment.toggleLike(releaseID: card.releaseID, youtubeID: $0) }
                )
            }

            Text("warum: \(card.reason)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }
}
