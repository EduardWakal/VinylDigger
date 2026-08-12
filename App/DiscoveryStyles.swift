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

    /// The axis key joins style, window and page with a pipe, so a style carrying
    /// one would garble the line shown on the card. Returns nil for anything that
    /// is empty once cleaned.
    static func clean(_ style: String) -> String? {
        let cleaned = style
            .replacingOccurrences(of: "|", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func save(_ styles: [String]) {
        UserDefaults.standard.set(styles.compactMap(clean), forKey: key)
    }
}
