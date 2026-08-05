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

public struct NodeID: Hashable, Sendable {
    public let kind: NodeKind
    public let id: Int

    public init(kind: NodeKind, id: Int) {
        self.kind = kind
        self.id = id
    }
}

public struct GraphEdge: Equatable, Sendable {
    public let from: NodeID
    public let to: NodeID
    public let kind: EdgeKind

    public init(from: NodeID, to: NodeID, kind: EdgeKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}

public struct WeightAdjustment: Equatable, Sendable {
    public let node: NodeID
    public let delta: Double

    public init(node: NodeID, delta: Double) {
        self.node = node
        self.delta = delta
    }
}
