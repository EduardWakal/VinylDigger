import SwiftUI
import DiggerKit

struct SeedsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var artists: [ArtistRecord] = []
    @State private var labels: [LabelRecord] = []

    var body: some View {
        List {
            Section("Artists nach Gewicht") {
                ForEach(artists, id: \.id) { artist in
                    HStack {
                        Text(artist.name)
                        Spacer()
                        Text(String(format: "%.2f", artist.weight))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Labels nach Gewicht") {
                ForEach(labels, id: \.id) { label in
                    HStack {
                        Text(label.name)
                        Spacer()
                        Text(String(format: "%.2f", label.weight))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear {
            let weights = environment.nodeWeights()
            artists = weights.artists
            labels = weights.labels
        }
    }
}
