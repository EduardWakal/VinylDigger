import SwiftUI
import VinylDiggerKit

/// The style charts, one record at a time. Same card as the player, different
/// source: nothing here comes from the taste graph.
struct DiscoveryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 12) {
            if let card = environment.discoveryCard {
                RecordCardView(card: card)

                HStack(spacing: 12) {
                    Button("Auf die Wantlist") {
                        Task { await environment.decideDiscovery(.love) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Nichts für mich") {
                        Task { await environment.decideDiscovery(.discard) }
                    }

                    Button("Später nochmal") {
                        Task { await environment.decideDiscovery(.later) }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Noch keine Vorschläge",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Hol die meistgesuchten Platten deiner Styles.")
                )
            }

            HStack {
                Button("Nachladen") {
                    Task { await environment.refreshDiscovery() }
                }
                Spacer()
                Text(environment.discoveryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
