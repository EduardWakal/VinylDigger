import SwiftUI
import VinylDiggerKit

struct HistoryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var entries: [(decision: DecisionRecord, release: ReleaseRecord?)] = []

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(entries, id: \.decision.id) { entry in
                    HStack {
                        Text(symbol(for: entry.decision.kind))
                            .font(.title3)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(entry.release?.title ?? "Release \(entry.decision.releaseID)")
                            Text(entry.release?.artistName ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.decision.decidedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Letzte Entscheidung rückgängig") {
                    Task {
                        await environment.undoLastDecision()
                        entries = environment.recentDecisions()
                    }
                }
                Spacer()
                Text("\(entries.count) Entscheidungen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear { entries = environment.recentDecisions() }
    }

    private func symbol(for kind: DecisionKind) -> String {
        switch kind {
        case .love: return "♥"
        case .discard: return "✗"
        case .later: return "↓"
        }
    }
}
