import Foundation

/// One slice of time to search in. `from` and `to` are both nil for the whole
/// catalogue.
public struct DiscoveryWindow: Equatable, Sendable {
    public let label: String
    public let from: Int?
    public let to: Int?

    public init(label: String, from: Int?, to: Int?) {
        self.label = label
        self.from = from
        self.to = to
    }
}

/// What a single search asks for.
public struct DiscoveryAxis: Equatable, Sendable {
    public let style: String
    public let window: DiscoveryWindow
    public let page: Int

    public init(style: String, window: DiscoveryWindow, page: Int) {
        self.style = style
        self.window = window
        self.page = page
    }

    public var key: String { "\(style)|\(window.label)|\(page)" }
}

public struct DiscoveryCursor: Equatable, Sendable {
    public var styleIndex: Int
    public var windowIndex: Int
    public var page: Int

    public init(styleIndex: Int, windowIndex: Int, page: Int) {
        self.styleIndex = styleIndex
        self.windowIndex = windowIndex
        self.page = page
    }

    public static let start = DiscoveryCursor(styleIndex: 0, windowIndex: 0, page: 1)
}

/// Walks styles and time windows in a fixed order, one step per refresh.
///
/// Styles turn over fastest, then windows, and only when both are exhausted does
/// the page advance. Ordering it the other way round would show five slices of the
/// same style in a row.
public enum DiscoveryRotation {
    public static func windows(now: Date) -> [DiscoveryWindow] {
        var calendar = Calendar(identifier: .gregorian)
        // Pin the time zone so window bounds do not depend on the machine's local zone.
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let year = calendar.component(.year, from: now)
        return [
            DiscoveryWindow(label: "All-Time", from: nil, to: nil),
            DiscoveryWindow(label: "90er", from: 1990, to: 1999),
            DiscoveryWindow(label: "2000er", from: 2000, to: 2009),
            DiscoveryWindow(label: "2010er", from: 2010, to: 2019),
            DiscoveryWindow(label: "aktuell", from: year - 2, to: year)
        ]
    }

    public static func next(
        styles: [String], cursor: DiscoveryCursor, now: Date
    ) -> (axis: DiscoveryAxis, next: DiscoveryCursor)? {
        guard !styles.isEmpty else { return nil }
        let windows = self.windows(now: now)

        // A stored cursor can outlive the style list it was written against.
        let styleIndex = styles.indices.contains(cursor.styleIndex) ? cursor.styleIndex : 0
        let windowIndex = windows.indices.contains(cursor.windowIndex) ? cursor.windowIndex : 0
        let page = max(cursor.page, 1)

        let axis = DiscoveryAxis(
            style: styles[styleIndex], window: windows[windowIndex], page: page
        )

        var nextStyle = styleIndex + 1
        var nextWindow = windowIndex
        var nextPage = page
        if nextStyle >= styles.count {
            nextStyle = 0
            nextWindow += 1
            if nextWindow >= windows.count {
                nextWindow = 0
                nextPage += 1
            }
        }

        return (axis, DiscoveryCursor(styleIndex: nextStyle, windowIndex: nextWindow, page: nextPage))
    }
}
