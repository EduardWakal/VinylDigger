import Foundation

/// The styles the discovery tab searches. Kept in UserDefaults rather than the
/// database — it is a setting, not data, and the settings window is where the
/// user goes looking for it.
enum DiscoveryStyles {
    private static let key = "discoveryStyles"

    static let defaults = [
        "Tech House", "House", "Deep House", "Minimal", "Progressive House"
    ]

    static func load() -> [String] {
        guard let stored = UserDefaults.standard.stringArray(forKey: key) else { return defaults }
        return stored
    }

    static func save(_ styles: [String]) {
        let cleaned = styles
            // The axis key joins style, window and page with a pipe, so a style
            // carrying one would garble the line shown on the card.
            .map { $0.replacingOccurrences(of: "|", with: " ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(cleaned, forKey: key)
    }
}
