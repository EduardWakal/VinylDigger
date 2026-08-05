import Foundation

public enum NodeKind: String, Codable, Equatable, Sendable {
    case artist
    case label
}

public enum EdgeKind: String, Codable, Equatable, Sendable, CaseIterable {
    case alias
    case group
    case artistToLabel
    case labelToArtist

    /// How much of the parent node's weight survives one hop along this edge.
    public var decay: Double {
        switch self {
        case .alias: return 0.90
        case .group: return 0.70
        case .artistToLabel: return 0.60
        case .labelToArtist: return 0.35
        }
    }
}

public enum DecisionKind: String, Codable, Equatable, Sendable {
    case love
    case discard
    case later

    /// How this decision shifts the weight of the release's artist and label.
    public var weightDelta: Double {
        switch self {
        case .love: return 0.25
        case .discard: return -0.15
        case .later: return 0.0
        }
    }
}
