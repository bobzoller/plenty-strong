import SwiftUI
import TrainingCore

enum WorkoutReviewRoute: Hashable {
    case summary(String)
    case correction(String, Int)
}

struct MovementSummaryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    let reviewing: Bool
    var reviewCorrection: ((Int) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    @State private var effort: Effort?
    private var legacyReturn: Bool { reviewing && model.snapshot.draft?.flow == nil && model.handled(row.movementID) }
    private var log: ExerciseLog? { model.log(for: row.movementID) }
    private var status: LogStatus {
        guard let log else { return .partial }
        if reviewing || model.handled(row.movementID) || log.problem != .none || log.status == .stopped { return log.status }
        if log.actualSets.isEmpty { return .skipped }
        return qualifiesCompletedExercise(log, prescription: row, movement: model.movement(for: row), schemaVersion: model.snapshot.state.schemaVersion) ? .completed : .partial
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Movement summary").font(.title2).accessibilityIdentifier("movement.summary")
                Text(model.movement(for: row).name ?? "Movement").font(.headline)
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                    let actual = log?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set \(index + 1) · goal \(goal.targetReps.map(String.init) ?? "up to \(goal.repCeiling)") reps\(model.movement(for: row).repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("summary.slot.\(index)")
                        if let actual {
                            Text(model.movement(for: row).repCounting == .perSide ? "Set \(index + 1): left \(actual.leftReps.map(String.init) ?? "unrecorded"), right \(actual.rightReps.map(String.init) ?? "unrecorded")" : "Set \(index + 1): \(actual.reps) reps").accessibilityIdentifier("set.actual.\(index)")
                            Button("Correct Set \(index + 1)") { reviewCorrection?(index) }
                                .accessibilityIdentifier("summary.correct.\(index)").disabled(model.busy || model.hasAmbiguousFinish)
                        } else if log?.skippedSetIndices?.contains(index) == true {
                            Text("Set \(index + 1): skipped").accessibilityIdentifier("set.skipped.\(index)")
                        } else { Text("Set \(index + 1): unrecorded").accessibilityIdentifier("set.unrecorded.\(index)") }
                    }
                }
                ForEach(Array((log?.actualSets ?? []).enumerated()).filter { !row.sets.indices.contains($0.element.setIndex ?? $0.offset) }, id: \.offset) { offset, actual in
                    Text("Retained extra observation \(offset + 1): \(actual.reps) reps")
                }
                Text("Outcome: \(status.rawValue)").accessibilityIdentifier("summary.outcome")
                if log?.problem != Problem.none {
                    Text("Stopped for \(log?.problem == .pain ? "pain" : "loss of control"). Observations are saved.").accessibilityIdentifier("movement.stopped")
                } else if status == .partial { Text("Partial — saved observations retained").accessibilityIdentifier("movement.partial") }
                if log?.actualSets.isEmpty == false { EffortPicker(model: model, movementID: row.movementID, selection: $effort) }
                else { Text("No performed sets. No effort answer is required.") }
                PrescriptionComparisonView(summary: .make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft), repCounting: model.movement(for: row).repCounting)
                if let deadline = model.snapshot.draft?.restDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Rest: \(RestTimer(deadline: deadline).remaining(at: model.now())) seconds remaining").accessibilityIdentifier("rest.remaining")
                    }
                }
            }.padding()
        }
        .safeAreaInset(edge: .bottom) {
            GuidedWorkoutFooter(model: model, row: row) {
            Button(legacyReturn ? (textSize.isAccessibilitySize ? "Return" : "Return to review") : (textSize.isAccessibilitySize ? "Confirm" : (reviewing ? "Confirm and return" : "Confirm summary"))) {
                Task { await model.run {
                    if legacyReturn {
                        try await model.flushScratch()
                        if let effort, effort != log?.finalEffort { try await model.recordEffort(movementID: row.movementID, effort: effort) }
                        guard model.operations.contextEnabled else { return }
                        model.reviewStep = nil; dismiss()
                    } else {
                        try await model.confirmMovementSummary(movementID: row.movementID, effort: effort, status: status, reviewing: reviewing)
                        if reviewing { dismiss() }
                    }
                } }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || (!legacyReturn && log?.actualSets.isEmpty == false && effort == nil))
                .accessibilityLabel(legacyReturn ? "Return to review" : (reviewing ? "Confirm and return" : "Confirm summary")).accessibilityIdentifier("summary.confirm")
            }
        }
        .onAppear {
            if legacyReturn || model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(row.movementID) == true { effort = log?.finalEffort }
        }
        .disabled(model.busy || model.snapshot.health != .ready || model.hasAmbiguousFinish)
    }
}
