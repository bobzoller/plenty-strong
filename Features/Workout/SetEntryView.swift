import SwiftUI
import TrainingCore

struct SetEntryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    var correctionIndex: Int? = nil
    var retainsOpenedEntry = false
    var correctLoad: (() -> Void)? = nil
    var corrected: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var operationID = UUID()
    @FocusState private var focused: Field?
    private enum Field: Hashable { case reps, left, right }
    private var entry: Binding<SetEntryDraft> { Binding(get: { model.entryDraft }, set: { model.entryDraft = $0 }) }
    private var movement: Movement { model.movement(for: row) }
    private var index: Int? { correctionIndex ?? model.nextSetIndex(for: row.movementID) }
    private var exact: Bool { [3, 4].contains(model.snapshot.state.schemaVersion) }
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
    private var valid: Bool {
        guard let observation else { return false }
        let positive = exact || observation.reps > 0 || (observation.leftReps ?? 0) > 0 || (observation.rightReps ?? 0) > 0
        return positive && (!requiresReason || model.entryDraft.reason != nil)
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            Text(model.movement(for: row).name ?? "Movement").font(.title2)
            if let index, row.sets.indices.contains(index) {
                Text(correctionIndex == nil ? "Set \(index + 1) of \(row.sets.count)" : "Correct Set \(index + 1)").font(.headline).accessibilityIdentifier("set.position")
                if let goal = row.sets[index].targetReps {
                    Text("Set \(index + 1) goal: \(goal) reps\(movement.repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("set.goal")
                }
                if movement.repCounting == .perSide {
                    TextField("Left reps performed", text: entry.left).focused($focused, equals: .left).accessibilityLabel("Left reps performed").accessibilityIdentifier("set.left-reps")
                    TextField("Right reps performed", text: entry.right).focused($focused, equals: .right).accessibilityLabel("Right reps performed").accessibilityIdentifier("set.right-reps")
                    Text("An unfinished or unequal side is kept as partial.").font(.caption)
                } else {
                    TextField("Reps performed", text: entry.reps).focused($focused, equals: .reps).accessibilityLabel("Reps performed").accessibilityIdentifier("set.reps")
                }
                if belowGoal { MissedGoalReasonPicker(selection: entry.reason, required: requiresReason) }
            }
            PrescriptionComparisonView(summary: .make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft), repCounting: movement.repCounting)
            GuidedActualsView(model: model, movementID: row.movementID)
            if correctionIndex == nil {
                if movement.loadingMode == .externalLoad {
                    Text(model.log(for: row.movementID)?.actualLoad.map { "Confirmed: \(MovementPrescriptionSummary.load($0))" } ?? "Actual load unrecorded")
                    Button("Correct load") { focused = nil; correctLoad?() }.accessibilityIdentifier("load.correct")
                    if model.log(for: row.movementID)?.actualSets.isEmpty == false {
                        Button("Different loads used — keep as partial") { Task { await model.run { try await model.recordMixedLoads(movementID: row.movementID); pendingActual = nil } } }.disabled(observation != nil).accessibilityIdentifier("load.mixed")
                    }
                }
            }
                if exact, correctionIndex == nil {
                    Button("Skip this set") {
                        guard let index else { return }; focused = nil
                        Task { await model.run { try await model.skipSet(movementID: row.movementID, index: index); pendingActual = nil } }
                    }.disabled(observation != nil || model.busy).accessibilityIdentifier("set.skip")
                }
            if correctionIndex == nil {
                Button("Keep as partial") { early(.partial) }.accessibilityIdentifier("movement.partial-action")
                Button("Stop movement") { early(.stopped) }.accessibilityIdentifier("movement.stop")
                if model.log(for: row.movementID)?.actualSets.isEmpty == true, observation == nil {
                    Button("Skip movement") { early(.skipped) }.accessibilityIdentifier("movement.skip")
                }
            }
        }.padding() }
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
            GuidedWorkoutFooter(model: model, row: row, pendingActual: correctionIndex == nil ? $pendingActual : .constant(nil)) {
                HStack(spacing: 12) {
                Button(correctionIndex == nil ? "Next" : (textSize.isAccessibilitySize ? "Save" : "Save correction")) {
                    guard let observation, let index else { return }
                    focused = nil
                    Task { await model.run {
                        if correctionIndex != nil {
                            try await model.correctSet(movementID: row.movementID, index: index, replacement: observation, operationID: operationID)
                            corrected?()
                        } else { try await model.recordSet(movementID: row.movementID, index: index, actual: observation) }
                        pendingActual = nil
                    } }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(!valid || model.busy || model.snapshot.health != .ready || model.hasAmbiguousFinish || (correctionIndex == nil && (model.blockedWorkingMovementIDs.contains(row.movementID) || (movement.loadingMode == .externalLoad && model.log(for: row.movementID)?.actualLoad == nil))))
                .accessibilityLabel(correctionIndex == nil ? "Next" : "Save correction")
                .accessibilityIdentifier(correctionIndex == nil ? "set.save" : "correction.save")
                if focused != nil {
                    Button { focused = nil } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .buttonStyle(.bordered).controlSize(.large).frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Done").accessibilityIdentifier("keyboard.done")
                }
                }
            }
        }
    }
    private func early(_ status: LogStatus) {
        focused = nil
        Task { await model.run { try await model.recordStatus(movementID: row.movementID, status: status, pendingActual: observation); pendingActual = nil } }
    }
}
