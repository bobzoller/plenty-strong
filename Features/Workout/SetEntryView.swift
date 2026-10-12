import SwiftUI
import TrainingCore

struct SetEntryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    var correctionIndex: Int? = nil
    var retainsOpenedEntry = false
    var corrected: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var operationID = UUID()
    @FocusState private var focused: Field?
    private enum Field: Hashable { case reps, left, right }
    private var entry: Binding<SetEntryDraft> { Binding(get: { model.entryDraft }, set: { model.entryDraft = $0 }) }
    private var movement: Movement { model.movement(for: row) }
    private var index: Int? { correctionIndex ?? model.nextSetIndex(for: row.movementID) }
    private var exact: Bool { [3, 4, 5].contains(model.snapshot.state.schemaVersion) }
    private var target: Int? { index.flatMap { row.sets.indices.contains($0) ? row.sets[$0].targetReps : nil } }
    private var observation: ActualSet? { model.entryDraft.observation(target: target, repCounting: movement.repCounting, exact: exact) }
    private var belowGoal: Bool { exact && model.entryDraft.requiresReason(target: target, repCounting: movement.repCounting) }
    // Keep correction admission aligned with TrainingRepository.correctDraftSet.
    private var requiresReason: Bool {
        guard belowGoal else { return false }
        guard correctionIndex != nil, let log = model.log(for: row.movementID) else { return true }
        let acknowledged = model.snapshot.draft?.acknowledgedMovementIDs?.contains(row.movementID) == true
        return log.problem == .none && (log.status == .completed || !acknowledged)
    }
    private var parseable: Bool {
        guard let observation else { return false }
        return exact || observation.reps > 0 || (observation.leftReps ?? 0) > 0 || (observation.rightReps ?? 0) > 0
    }
    private var valid: Bool { parseable && (!requiresReason || model.entryDraft.reason != nil) }
    // During editing, Next commits the complete editor before asking for a reason.
    private var canCommit: Bool { parseable && (focused != nil || valid) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            WorkoutSessionModeLabel(model: model)
            Text(model.movement(for: row).name ?? "Movement").font(.title2)
            if let index, row.sets.indices.contains(index) {
                Text(correctionIndex == nil ? "Set \(index + 1) of \(row.sets.count)" : "Correct Set \(index + 1)").font(.headline).accessibilityIdentifier("set.position")
                if let goal = row.sets[index].targetReps {
                    Text("Set \(index + 1) goal: \(goal) reps\(movement.repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("set.goal")
                } else {
                    Text("Set \(index + 1) goal: Up to \(row.sets[index].repCeiling) good reps\(movement.repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("set.goal")
                }
                Text(model.log(for: row.movementID)?.actualLoad.map { "Weight: \(MovementPrescriptionSummary.load($0))" } ?? (movement.loadingMode == .externalLoad ? "Actual load unrecorded" : "Bodyweight / your setup"))
                    .accessibilityIdentifier("set.weight")
                if movement.repCounting == .perSide {
                    TextField("Left reps performed", text: entry.left).focused($focused, equals: .left).accessibilityLabel("Left reps performed").accessibilityIdentifier("set.left-reps")
                    TextField("Right reps performed", text: entry.right).focused($focused, equals: .right).accessibilityLabel("Right reps performed").accessibilityIdentifier("set.right-reps")
                    Text("An unfinished or unequal side is kept as partial.").font(.caption)
                } else {
                    TextField("Reps performed", text: entry.reps).focused($focused, equals: .reps).accessibilityLabel("Reps performed").accessibilityIdentifier("set.reps")
                }
                if belowGoal && focused == nil { MissedGoalReasonPicker(selection: entry.reason, required: requiresReason) }
            }
        }.padding() }
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.busy || model.snapshot.health != .ready)
        .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
        .onChange(of: [model.entryDraft.reps, model.entryDraft.left, model.entryDraft.right]) {
            var updated = model.entryDraft
            updated.update(reps: updated.reps, left: updated.left, right: updated.right, target: target, repCounting: movement.repCounting)
            if updated != model.entryDraft { model.entryDraft = updated }
            pendingActual = observation
        }
        .onChange(of: model.entryDraft.reason) { pendingActual = observation }
        .task {
            if !retainsOpenedEntry, let index = correctionIndex {
                guard await model.openCorrectionEntry(movementID: row.movementID, index: index) else { return }
            }
            guard !Task.isCancelled else { return }
            pendingActual = observation
        }
        .safeAreaInset(edge: .bottom) {
            GuidedWorkoutFooter(model: model) {
                VStack(spacing: 8) {
                Button {
                    focused = nil
                    guard valid, let observation, let index else { return }
                    Task { await model.run {
                        if correctionIndex != nil {
                            try await model.correctSet(movementID: row.movementID, index: index, replacement: observation, operationID: operationID)
                            corrected?()
                        } else { try await model.recordSet(movementID: row.movementID, index: index, actual: observation) }
                        pendingActual = nil
                    } }
                } label: {
                    Text(correctionIndex == nil ? "Next" : (textSize.isAccessibilitySize ? "Save" : "Save correction"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(!canCommit || model.busy || model.snapshot.health != .ready || model.hasAmbiguousFinish || (correctionIndex == nil && (model.blockedWorkingMovementIDs.contains(row.movementID) || (movement.loadingMode == .externalLoad && model.log(for: row.movementID)?.actualLoad == nil))))
                .accessibilityLabel(correctionIndex == nil ? "Next" : "Save correction")
                .accessibilityIdentifier(correctionIndex == nil ? "set.save" : "correction.save")
                if focused != nil {
                    Button { focused = nil } label: {
                        Image(systemName: "keyboard.chevron.compact.down").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .accessibilityLabel("Done").accessibilityIdentifier("keyboard.done")
                }
                }
            } secondary: {
                WorkoutSecondaryActions(model: model, step: .set(movementID: row.movementID, index: index ?? 0), row: row, pendingActual: correctionIndex == nil ? $pendingActual : .constant(nil))
            }
        }
    }
}
