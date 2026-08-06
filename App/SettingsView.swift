import SwiftUI
import VinylDiggerKit

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var token = ""
    @State private var username = ""
    @State private var message = ""

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
}
