import Foundation
import TrainingCore

/// UI text is deliberately separate from durable performed observations.
struct SetEntryDraft: Codable, Equatable, Sendable {
    var reps: String = ""
    var left: String = ""
    var right: String = ""
    var reason: MissedGoalReason? = nil

    mutating func update(reps: String, left: String, right: String, target: Int?, repCounting: RepCounting) {
        self.reps = reps; self.left = left; self.right = right
        if !requiresReason(target: target, repCounting: repCounting) { reason = nil }
    }
    func requiresReason(target: Int?, repCounting: RepCounting) -> Bool {
        guard let target else { return false }
        let values = repCounting == .perSide ? [Self.number(left), Self.number(right)] : [Self.number(reps)]
        return values.compactMap { $0 }.contains { $0 < target }
    }
    func observation(target: Int?, repCounting: RepCounting, exact: Bool) -> ActualSet? {
        let effectiveReason = exact && requiresReason(target: target, repCounting: repCounting) ? reason : nil
        if repCounting == .perSide {
            guard left.isEmpty || Self.number(left) != nil, right.isEmpty || Self.number(right) != nil else { return nil }
            let l = Self.number(left), r = Self.number(right)
            guard l != nil || r != nil else { return nil }
            return ActualSet(reps: l ?? r ?? 0, leftReps: l, rightReps: r, missedGoalReason: effectiveReason)
        }
        return Self.number(reps).map { ActualSet(reps: $0, missedGoalReason: effectiveReason) }
    }
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(text), number >= 0 else { return nil }
        return number
    }
}
