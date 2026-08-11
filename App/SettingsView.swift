import SwiftUI
import VinylDiggerKit

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var token = ""
    @State private var username = ""
    @State private var message = ""
    @State private var styles: [String] = []
    @State private var newStyle = ""

    private let secrets = KeychainSecretStore()

    var body: some View {
        Form {
            Section("Discogs") {
                SecureField("Personal Access Token", text: $token)
                    .textContentType(.password)
                TextField("Benutzername", text: $username)
                Text("Token holen unter discogs.com/settings/developers. Er wird im Schlüsselbund abgelegt, nie auf der Festplatte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Discovery-Styles") {
                ForEach(styles, id: \.self) { style in
                    HStack {
                        Text(style)
                        Spacer()
                        Button("Entfernen", role: .destructive) {
                            styles.removeAll { $0 == style }
                            DiscoveryStyles.save(styles)
                            styles = DiscoveryStyles.load()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Style hinzufügen", text: $newStyle)
                    Button("Hinzufügen") { addStyle() }
                        .disabled(newStyle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Genau so schreiben, wie Discogs den Style führt — etwa „Deep House\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Sichern") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("Token löschen", role: .destructive) { clearToken() }
                    Spacer()
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear(perform: load)
    }

    private func load() {
        token = (try? secrets.read(.discogsToken)).flatMap { $0 } ?? ""
        username = (try? secrets.read(.discogsUsername)).flatMap { $0 } ?? ""
        styles = DiscoveryStyles.load()
    }

    private func save() {
        do {
            if token.isEmpty {
                try secrets.delete(.discogsToken)
            } else {
                try secrets.write(token, for: .discogsToken)
            }
            if username.isEmpty {
                try secrets.delete(.discogsUsername)
            } else {
                try secrets.write(username, for: .discogsUsername)
            }
            message = "gesichert"
        } catch {
            message = "Fehler: \(error)"
        }
    }

    private func clearToken() {
        try? secrets.delete(.discogsToken)
        token = ""
        message = "Token gelöscht"
    }

    private func addStyle() {
        guard let cleaned = DiscoveryStyles.clean(newStyle), !styles.contains(cleaned) else { return }
        DiscoveryStyles.save(styles + [cleaned])
        styles = DiscoveryStyles.load()
        newStyle = ""
    }
}
