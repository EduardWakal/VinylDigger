import Foundation

/// One line of a hand-typed dig list.
public struct DigLine: Equatable, Sendable {
    /// The line as written, so the user can recognise it in the review list.
    public let raw: String
    public let artist: String?
    public let title: String

    public init(raw: String, artist: String?, title: String) {
        self.raw = raw
        self.artist = artist
        self.title = title
    }
}

/// Pulls artist and title out of lines that were typed by hand while listening.
///
/// The input is messy on purpose — catalogue numbers in front, sleeve positions,
/// bracketed labels at the end. Nothing here is guessed beyond splitting: whatever
/// cannot be separated stays in the title, and the search deals with it.
public enum DigParser {
    private static let separators = [" - ", " – ", " — "]

    public static func parse(_ text: String) -> [DigLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }

            var body = stripCataloguePrefix(raw)
            body = stripTrailingBracket(body)

            guard let range = separators.compactMap({ body.range(of: $0) }).min(by: {
                $0.lowerBound < $1.lowerBound
            }) else {
                return DigLine(raw: raw, artist: nil, title: body)
            }

            let artist = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty, !title.isEmpty else {
                return DigLine(raw: raw, artist: nil, title: body)
            }
            return DigLine(raw: raw, artist: artist, title: title)
        }
    }

    /// Drops "BCR035 : " and "B1. " style openers.
    private static func stripCataloguePrefix(_ value: String) -> String {
        if let colon = value.range(of: " : ") {
            return String(value[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let pattern = #"^[A-Z]{1,2}\d{1,2}\.\s+"#
        if let match = value.range(of: pattern, options: .regularExpression) {
            return String(value[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// Drops a trailing "[VL011]" — that is the label's catalogue number, not the title.
    private static func stripTrailingBracket(_ value: String) -> String {
        guard value.hasSuffix("]"), let open = value.lastIndex(of: "[") else { return value }
        return String(value[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
