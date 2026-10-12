import Foundation

/// A deadline, not a ticking counter: background time does not pause rest.
struct RestTimer {
    var deadline: Date?
    func formattedRemaining(at now: Date) -> String {
        let seconds = remaining(at: now)
        let minutes = String(seconds / 60), remainder = String(seconds % 60)
        return (minutes.count < 2 ? "0" + minutes : minutes) + ":" + (remainder.count < 2 ? "0" + remainder : remainder)
    }
    func remaining(at now: Date) -> Int {
        guard let deadline else { return 0 }
        let seconds = ceil(deadline.timeIntervalSince(now))
        // Clamp before conversion; a corrupt deadline or injected clock must never trap.
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds < Double(Int.max) else { return Int.max }
        return Int(seconds)
    }
}
