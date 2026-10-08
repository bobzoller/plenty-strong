import SwiftUI
import TrainingCore

struct WorkoutDetailView: View {
    let envelope: JournalEnvelope
    let variantID: String?
    var history: [JournalEnvelope] = []
    static func reps(_ log: ExerciseLog) -> String {
        if log.actualSets.contains(where: { $0.setIndex != nil }) {
            return MovementPrescriptionSummary.reps(log.actualSets, repCounting: log.actualSets.contains(where: { $0.leftReps != nil || $0.rightReps != nil }) ? .perSide : .total)
        }
        return log.actualSets.map { set in
            if set.leftReps != nil || set.rightReps != nil { return "Left \(set.leftReps.map(String.init) ?? "unrecorded"), right \(set.rightReps.map(String.init) ?? "unrecorded")" }
            return String(set.reps)
        }.joined(separator: ", ")
    }
    private func effort(_ value: Effort) -> String {
        switch value { case .tooEasy: "Too easy"; case .onTarget: "Right effort"; case .tooHard: "Too hard"; case .unknown: "Not recorded" }
    }
    private func problem(_ value: Problem) -> String {
        switch value { case .none: "None"; case .pain: "Pain"; case .controlLost: "Loss of control" }
    }
    static func coverage(_ event: CompletedWorkout) -> String {
        let sets = event.exercises.reduce(0) { $0 + $1.actualSets.count }
        return "\(sets) recorded sets · \(event.exercises.filter { $0.status == .completed }.count) completed, \(event.exercises.filter { $0.status == .partial }.count) partial, \(event.exercises.filter { $0.status == .skipped }.count) skipped, \(event.exercises.filter { $0.status == .stopped }.count) stopped movements"
    }
    var body: some View {
        List {
            if case let .workout(event, _) = envelope.command {
                let issued = MovementPrescriptionSummary.issuedWorkout(envelope: envelope, history: history)
                let savedRules = try? RulesetCatalog.resolve(version: envelope.rulesetVersion, hash: envelope.rulesetHash)
                let savedPolicy = savedRules.flatMap { try? ProgramPolicy.resolve(schemaVersion: envelope.schemaVersion, rules: $0) }
                Section("Recorded workout · \(event.date.iso8601)") {
                    if envelope.returnedState.config.goal == .maintenance { Text("Stable good reps at the right effort support maintenance. An increase is not required.").accessibilityIdentifier("history.maintenance") }
                    Text(Self.coverage(event)).accessibilityIdentifier("history.coverage")
                    Text(event.sessionMode == .easier ? "Easier work is recorded without progression qualification." : "Actuals below are what was recorded, independent of future targets.")
                    if savedPolicy == .fixedExactV1 { Text("These exact rep changes are evidence-informed product adaptations, not scientifically validated forecasts.").accessibilityIdentifier("history.policy-basis") }
                }
                let logs = event.exercises.filter { variantID == nil || $0.movementID == variantID }
                ForEach(Array(logs.enumerated()), id: \.element.movementID) { index, log in
                    Section(envelope.returnedState.config.movements.first { $0.id == (log.baseMovementID ?? log.movementID) }?.name ?? log.baseMovementID ?? log.movementID) {
                        Text(log.modificationsSnapshot?.isEmpty == false ? log.modificationsSnapshot! : "Default setup").accessibilityIdentifier("history.setup.\(log.movementID)")
                        if let issued, let row = issued.displayed.exercises.first(where: { $0.movementID == log.movementID }) {
                            let counting = issued.state.config.movements.first { $0.id == row.baseMovementID }?.repCounting ?? .total
                            Text("Goal issued for this workout").font(.headline)
                            Text(MovementPrescriptionSummary.goal(row, policy: issued.policy, repCounting: counting)).accessibilityIdentifier(index == 0 ? "history.issued-goal" : "history.issued-goal.\(log.movementID)")
                            if let load = row.load { Text("Issued load: \(MovementPrescriptionSummary.load(load))") }
                            if event.sessionMode == .easier, let planned = issued.planned.exercises.first(where: { $0.movementID == log.movementID }) {
                                Text("Retained planned normal goal: \(MovementPrescriptionSummary.goal(planned, policy: issued.policy, repCounting: counting))").accessibilityIdentifier("history.planned-goal.\(log.movementID)")
                            }
                        } else { Text("Issued goal unavailable — the original prescription reference could not be verified").accessibilityIdentifier("history.issued-unavailable") }
                        Text("Actual").font(.headline)
                        if let load = log.actualLoad { Text("Actual load: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                        else { Text("Actual load: no numeric load recorded") }
                        Text(log.actualSets.isEmpty ? "No sets recorded" : Self.reps(log))
                            .accessibilityLabel(log.actualSets.isEmpty ? "No sets recorded" : Self.reps(log))
                            .accessibilityIdentifier(index == 0 ? "history.actual-reps" : "history.actual-reps.\(log.movementID)")
                        Text("Outcome: \(log.status.rawValue). Effort: \(effort(log.finalEffort)). Problem: \(problem(log.problem)).")
                        Text(log.effortScope == .allWorkingSets ? "Effort scope: all working sets" : "Legacy effort scope: final set / original record")
                        if let row = issued?.displayed.exercises.first(where: { $0.movementID == log.movementID }) {
                            Text("Issued phase: \(row.phase.rawValue); session: \(event.sessionMode.rawValue)")
                        }
                        if log.actualSets.contains(where: { $0.leftReps != nil || $0.rightReps != nil }) { Text("Reps are shown separately for each side; they are never added together.") }
                        if let skipped = log.skippedSetIndices, !skipped.isEmpty { Text("Skipped sets: \(skipped.map { String($0 + 1) }.joined(separator: ", "))") }
                        if log.mixedLoads == true { Text("Different loads used — noncomparable partial work") }
                        ForEach(Array(log.actualSets.enumerated()), id: \.offset) { offset, actual in
                            if let reason = actual.missedGoalReason { Text("Set \((actual.setIndex ?? offset) + 1) stopped early: \(reason.title)") }
                        }
                        if let target = envelope.returnedState.exercises[log.movementID] {
                            Text("Next target for this setup when saved").font(.headline)
                            if target.mode != .paused {
                                Text("Saved dose: \(target.nextSetOverride ?? target.normalSets) sets")
                                if let load = target.load { Text("Saved target load: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                            }
                            if savedPolicy == .fixedExactV1 {
                                if let nextRow = envelope.returnedPrescription.exercises.first(where: { $0.movementID == log.movementID }) {
                                    Text("Next issued goal when saved").font(.headline)
                                    Text(MovementPrescriptionSummary.goal(nextRow, policy: savedPolicy, repCounting: envelope.returnedState.config.movements.first { $0.id == log.baseMovementID }?.repCounting ?? .total)).accessibilityIdentifier(index == 0 ? "history.next-goal" : "history.next-goal.\(log.movementID)")
                                } else { Text("This setup was not in the next issued workout.") }
                                if let retained = target.exactRepState?.normalTargets {
                                    Text("Retained normal goals when saved: \(retained.map(String.init).joined(separator: " / ")) reps").accessibilityIdentifier(index == 0 ? "history.retained-goal" : "history.retained-goal.\(log.movementID)")
                                }
                            } else if savedPolicy != nil {
                                Text(target.mode == .paused ? "Paused — no working sets" : "Up to \(target.repCeiling) good reps")
                                    .accessibilityIdentifier(index == 0 ? "history.next-rep-ceiling" : "history.next-rep-ceiling.\(log.movementID)")
                            } else { Text("Saved goal unavailable — unsupported stored policy") }
                        }
                        DisclosureGroup("Stored record details") {
                            Text("Original setup identity: \(log.movementID)").font(.caption).textSelection(.enabled)
                            Text("Original base movement: \(log.baseMovementID ?? log.movementID)").font(.caption).textSelection(.enabled)
                        }.accessibilityIdentifier("history.stored-details.\(log.movementID)")
                        ForEach(Array(envelope.decisions.filter { $0.movementID == log.movementID }.enumerated()), id: \.offset) { _, decision in
                            DecisionExplanationView(decision: decision)
                        }
                    }
                }
                Section("Stored versions") { Text("Rules: \(envelope.rulesetVersion)"); Text("Profile: \(envelope.profileID)"); Text("Source: \(envelope.sourceProfileID)") }
            }
        }.navigationTitle("Workout details")
    }
}
