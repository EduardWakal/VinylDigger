import Foundation

/// How much each kind of evidence about the user's taste counts.
///
/// The order matters more than the numbers. A track the user marked while
/// listening is the strongest statement they make — they heard it and kept it.
/// Putting a record on the wantlist is a decision about a whole record, some of
/// which will be filler. Owning it says the taste was right once but says nothing
/// about now. "Later" is barely a signal. A discard is the only negative one.
public enum TasteSignal {
    public static let trackLike = 0.45
    public static let wantlist = 0.22
    public static let owned = 0.15
    public static let later = 0.04
    public static let discard = -0.18

    /// Several liked tracks on one record say more than one, but not five times
    /// more — a favourite EP must not outweigh five different records.
    public static func trackLikeWeight(count: Int) -> Double {
        guard count > 0 else { return 0 }
        let n = Double(count)
        return trackLike * (n / (1 + n)) * 2
    }

    public static func decisionWeight(_ kind: DecisionKind) -> Double {
        switch kind {
        case .love: return wantlist
        case .later: return later
        case .discard: return discard
        }
    }
}
