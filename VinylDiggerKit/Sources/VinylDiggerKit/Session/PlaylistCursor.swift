import Foundation

/// Tracks which video of a release is playing.
///
/// Lives in the kit rather than in PlayerController so the walk through a
/// release can be tested without a web view.
public struct PlaylistCursor: Equatable, Sendable {
    private let videoIDs: [String]
    public private(set) var index: Int

    public init(videoIDs: [String]) {
        self.videoIDs = videoIDs
        self.index = 0
    }

    public var isEmpty: Bool { videoIDs.isEmpty }

    public var current: String? {
        videoIDs.indices.contains(index) ? videoIDs[index] : nil
    }

    /// Moves to the next video, or returns nil when the release is finished.
    public mutating func advance() -> String? {
        guard index + 1 < videoIDs.count else { return nil }
        index += 1
        return videoIDs[index]
    }

    public mutating func select(_ index: Int) -> String? {
        guard videoIDs.indices.contains(index) else { return nil }
        self.index = index
        return videoIDs[index]
    }
}
