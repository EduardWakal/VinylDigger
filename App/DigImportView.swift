import SwiftUI
import VinylDiggerKit

/// Turns a hand-typed dig list into Discogs releases.
///
/// Free text against a catalogue does not match reliably, so nothing is taken
/// over on its own — every line waits for a pick.
struct DigImportView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var rows: [Row] = []
    @State private var searching = false

    struct Row: Identifiable {
        let id = UUID()
        let line: DigLine
        var hits: [DiscogsReleaseSummary] = []
        var accepted: Int?
        var searched = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if rows.isEmpty {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .padding(8)
            } else {
                List($rows) { $row in
                    rowView($row)
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dig-Liste einlesen")
                .font(.headline)
            Text(rows.isEmpty
                 ? "Eine Zeile pro Track, \"Artist - Titel\". Katalognummern und Spurpositionen stören nicht."
                 : "Je Zeile einen Treffer wählen. Nur gewählte Zeilen landen auf der Wantlist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.wrappedValue.line.raw)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                if row.wrappedValue.accepted != nil {
                    Label("übernommen", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if row.wrappedValue.searched && row.wrappedValue.hits.isEmpty {
                    Text("kein Treffer")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(row.wrappedValue.hits, id: \.id) { hit in
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await environment.acceptDigMatch(releaseID: hit.id, summary: hit)
                            row.wrappedValue.accepted = hit.id
                        }
                    } label: {
                        Image(systemName: row.wrappedValue.accepted == hit.id
                              ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(row.wrappedValue.accepted != nil)

                    VStack(alignment: .leading) {
                        Text(hit.title).font(.callout)
                        HStack(spacing: 6) {
                            if let label = hit.label { Text(label) }
                            if let catno = hit.catno { Text(catno) }
                            if let year = hit.year { Text(String(year)) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("↗", destination: URL(string: "https://www.discogs.com/release/\(hit.id)")!)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if rows.isEmpty {
                Button("Aus dem Vault laden") { loadFromVault() }
                Spacer()
                Button("Suchen") { Task { await search() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text(searching
                     ? "sucht…"
                     : "\(rows.filter { $0.accepted != nil }.count) von \(rows.count) übernommen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Neue Liste") { rows = []; text = "" }
            }
            Button("Fertig") { dismiss() }
        }
        .padding(12)
    }

    private func loadFromVault() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Obsidian/Schakal/Musik/Dig/Dig Minimal-House Vinyl.md")
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.isEmpty {
            environment.status = "Dig-Notiz im Vault nicht gefunden"
        }
    }

    private func search() async {
        rows = DigParser.parse(text).map { Row(line: $0) }
        searching = true
        for index in rows.indices {
            let hits = await environment.searchDigLine(rows[index].line)
            rows[index].hits = hits
            rows[index].searched = true
        }
        searching = false
    }
}
