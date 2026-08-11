import SwiftUI
import VinylDiggerKit

struct StatsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var artists: [ArtistRecord] = []
    @State private var labels: [LabelRecord] = []
    @State private var likes: [LikedTrack] = []
    @State private var openTracks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()

            List {
                Section("Gemochte Tracks (\(likes.count))") {
                    if likes.isEmpty {
                        Text("Noch keine. Im Player das Herz neben einer Spur klicken, oder L drücken.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(likes, id: \.youtubeID) { like in
                        HStack(spacing: 8) {
                            Text(like.trackPosition ?? "—")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(like.trackTitle ?? "ohne Titel")
                                Text("\(like.artistName) · \(like.releaseTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let label = like.labelName {
                                Text(label).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("Labels nach Gewicht") {
                    ForEach(labels, id: \.id) { label in
                        WeightRow(
                            name: label.name,
                            computed: label.weight,
                            manual: label.manualWeight,
                            onChange: { environment.setManualWeight($0, label: label.id); reload() }
                        )
                    }
                }

                Section("Artists nach Gewicht") {
                    ForEach(artists, id: \.id) { artist in
                        WeightRow(
                            name: artist.name,
                            computed: artist.weight,
                            manual: artist.manualWeight,
                            onChange: { environment.setManualWeight($0, artist: artist.id); reload() }
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear(perform: reload)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await environment.exportDigSession()
                    reload()
                }
            } label: {
                Label("Dig-Session (\(openTracks))", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(openTracks == 0)
            .help("Die seit dem letzten Export markierten Tracks als eigene Notiz in den Vault")

            Button {
                Task { await environment.exportRecords() }
            } label: {
                Label("Platten + Tracklisten", systemImage: "arrow.up.doc.on.clipboard")
            }
            .help("Wantlist mit vollständiger Trackliste je Platte in den Vault")

            Divider().frame(height: 18)

            Button {
                Task {
                    await environment.suggestFromWantlist()
                    reload()
                }
            } label: {
                Label("Neue Vorschläge", systemImage: "sparkle.magnifyingglass")
            }
            .help("Graph aus Wantlist und gemochten Tracks erweitern und neu gewichten")

            Spacer()

            Text(environment.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
    }

    private func reload() {
        let weights = environment.nodeWeights()
        artists = weights.artists
        labels = weights.labels
        likes = environment.likedTracks()
        openTracks = environment.openDigSessionCount()
    }
}

/// A graph weight with the option to pin it by hand. Empty field means the graph
/// decides again.
private struct WeightRow: View {
    let name: String
    let computed: Double
    let manual: Double?
    let onChange: (Double?) -> Void

    @State private var text = ""

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(String(format: "%.2f", computed))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(manual == nil ? .secondary : .tertiary)

            TextField("auto", text: $text)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { onChange(Double(text.replacingOccurrences(of: ",", with: "."))) }

            Button {
                text = ""
                onChange(nil)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Wieder dem Graph überlassen")
            .opacity(manual == nil ? 0 : 1)
            .disabled(manual == nil)
        }
        // Keeps the field and the reset button clear of the scroll bar.
        .padding(.trailing, 12)
        .onAppear { text = manual.map { String(format: "%.2f", $0) } ?? "" }
    }
}
