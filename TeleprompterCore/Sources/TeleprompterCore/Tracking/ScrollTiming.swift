import Foundation

/// Pure timing math for driving the script viewport. The scroll layer owns
/// *how the screen gets there*; these functions convert a target position
/// and the reader's measured pace into a duration.
///
/// The core rule: a faster speaker glides to the next target faster, a slow
/// reader gets a gentler, longer glide. Keep the window tight so a block
/// transition never feels like a teleport (`minDuration`) and never crawls
/// (`maxDuration`).
public enum ScrollTiming {
    /// Fastest possible glide for a block transition.
    public static let minDuration: TimeInterval = 0.25
    /// Longest acceptable glide for a block transition.
    public static let maxDuration: TimeInterval = 1.5
    /// Fallback when the reader's pace isn't measurable yet.
    public static let noVelocityDuration: TimeInterval = 0.2
    /// Beyond ~this many words a block transition is a long move.
    private static let longDistanceWords: Double = 80

    /// Duration to animate a scroll of `words` script words at `velocity`
    /// words/sec. Returns a value in `[minDuration, maxDuration]`.
    ///
    /// Behavior:
    /// - No/zero velocity → `noVelocityDuration` (instant-ish snap).
    /// - Base pace is `1.0 / velocity` seconds (linear: reading twice as fast
    ///   scrolls twice as fast), clamped to the window.
    /// - Long moves (`words > longDistanceWords`) stretch proportionally so a
    ///   far skip still sweeps coherently, then re-clamp at `maxDuration`.
    public static func travelDuration(words: Int, velocity: Double) -> TimeInterval {
        guard velocity > 0 else { return noVelocityDuration }
        let words = Double(max(0, words))
        var duration = 1.0 / velocity
        if words > longDistanceWords {
            duration *= words / longDistanceWords
        }
        return min(max(duration, minDuration), maxDuration)
    }
}