import SwiftUI
import VinylDiggerKit

/// Asked before a release goes on the wantlist: which tracks are actually good.
///
/// Discogs only knows whole records, so the wantlist entry stays the whole record.
/// The picks are kept locally and end up in the Obsidian note.
struct TrackPickerView: View {
    let card: QueueCard
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(card.artistName) — \(card.title)")
                    .font(.headline)
                Text("Welche Spuren sind gut? Die Platte kommt so oder so ganz auf die Wantlist — Discogs kennt nichts Kleineres.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            List(card.tracks, id: \.youtubeID) { track in
                Button {
                    if chosen.contains(track.youtubeID) {
                        chosen.remove(track.youtubeID)
                    } else {
                        chosen.insert(track.youtubeID)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: chosen.contains(track.youtubeID)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(track.youtubeID)
                                             ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        Text(track.position ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28, alignment: .leading)
                        Text(track.title ?? "ohne Titel")
                            .lineLimit(1)
                        Spacer()
                        if let duration = track.duration {
                            Text(String(format: "%d:%02d", duration / 60, duration % 60))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button("Alle") { chosen = Set(card.tracks.map(\.youtubeID)) }
                Button("Keine") { chosen = [] }
                Spacer()
                Text("\(chosen.count) von \(card.tracks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Abbrechen") { dismiss() }
                Button("♥ Auf die Wantlist") {
                    onConfirm(Array(chosen))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        // Whatever was already starred while listening comes pre-ticked.
        .onAppear { chosen = Set(card.tracks.filter(\.liked).map(\.youtubeID)) }
    }
}
