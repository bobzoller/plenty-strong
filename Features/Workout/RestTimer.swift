import Foundation

/// A deadline, not a ticking counter: background time does not pause rest.
struct RestTimer {
    var deadline: Date?
    func remaining(at now: Date) -> Int {
        guard let deadline else { return 0 }
        let seconds = ceil(deadline.timeIntervalSince(now))
        // Clamp before conversion; a corrupt deadline or injected clock must never trap.
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds < Double(Int.max) else { return Int.max }
        return Int(seconds)
    }
}
