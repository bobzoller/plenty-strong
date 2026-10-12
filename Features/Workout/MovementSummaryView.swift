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
    @State private var showingStop = false
    private var needsEffort: Bool { log?.actualSets.isEmpty == false && effort == nil }
    private var canReportSafety: Bool { log?.problem == Problem.none }
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
                if let deadline = model.snapshot.draft?.restDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Rest: \(RestTimer(deadline: deadline).formattedRemaining(at: model.now()))").accessibilityIdentifier("rest.remaining")
                    }
                }
                WorkoutSessionModeLabel(model: model)
                Text("Movement summary").font(.title2).accessibilityIdentifier("movement.summary")
                Text(model.movement(for: row).name ?? "Movement").font(.headline)
                WorkoutComparisonRows(row: row, log: log, repCounting: model.movement(for: row).repCounting, loadingMode: model.movement(for: row).loadingMode, editSet: model.hasAmbiguousFinish ? nil : reviewCorrection, editingDisabled: model.busy || model.snapshot.health != .ready)
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, _ in
                    if log?.actualSets.enumerated().contains(where: { ($0.element.setIndex ?? $0.offset) == index }) == true {
                        let corrections = WorkoutDetailView.corrections(audit: model.snapshot.draft?.observationAudit, movementID: row.movementID, setIndex: index)
                        if !corrections.isEmpty {
                            Text("Corrected · \(corrections.count) \(corrections.count == 1 ? "correction" : "corrections")").accessibilityIdentifier("summary.corrected.\(index)")
                            DisclosureGroup("Set \(index + 1) corrections") {
                                ForEach(Array(corrections.enumerated()), id: \.element.operationID) { order, correction in
                                    Text("Correction \(order + 1). \(WorkoutDetailView.correctionDetail(correction, repCounting: model.movement(for: row).repCounting))")
                                        .accessibilityIdentifier("summary.correction.detail.\(correction.operationID.uuidString)")
                                }
                            }.accessibilityIdentifier("summary.corrections.\(index)")
                        }
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
                if !reviewing, needsEffort, !canReportSafety { Text("Choose effort to confirm this summary or stop the workout.").font(.subheadline).accessibilityIdentifier("summary.effort-required") }
            }.padding()
        }
        .safeAreaInset(edge: .bottom) {
            GuidedWorkoutFooter(model: model) {
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
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || (!legacyReturn && needsEffort))
                .accessibilityLabel(legacyReturn ? "Return to review" : (reviewing ? "Confirm and return" : "Confirm summary")).accessibilityIdentifier("summary.confirm")
            } secondary: {
                if reviewing {
                    WorkoutSecondaryActions(model: model, step: .summary(movementID: row.movementID), row: row, pendingActual: .constant(nil))
                } else if !needsEffort || canReportSafety {
                    Button { showingStop = true } label: {
                        Text("Stop workout").frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing).contentShape(Rectangle())
                    }.accessibilityIdentifier("workout.stop")
                }
            }
        }
        .confirmationDialog("Stop workout?", isPresented: $showingStop, titleVisibility: .visible) {
            Button("Keep results and stop workout") {
                Task { await model.run { try await model.stopWorkout(movementID: row.movementID, effort: effort, status: status) } }
            }.accessibilityIdentifier("workout.stop-confirm").disabled(needsEffort)
            if canReportSafety {
                Button("Pain — stop \(model.movement(for: row).name ?? "movement")") { safety(.pain) }.accessibilityIdentifier("problem.pain")
                Button("Loss of control — stop \(model.movement(for: row).name ?? "movement")") { safety(.controlLost) }.accessibilityIdentifier("problem.control_lost")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(needsEffort ? "Choose effort to stop the workout. You can report pain or loss of control for this movement immediately; its summary stays pending confirmation." : "Keep recorded results, skip empty remaining work, and open workout review. Finish saves the workout. Safety reports stop only this movement.")
        }
        .onAppear {
            if legacyReturn || model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(row.movementID) == true { effort = log?.finalEffort }
        }
        .disabled(model.busy || model.snapshot.health != .ready || model.hasAmbiguousFinish)
    }
    private func safety(_ problem: Problem) {
        Task { await model.run { try await model.recordProblem(movementID: row.movementID, problem: problem) } }
    }
}
