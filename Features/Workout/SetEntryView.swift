import SwiftUI
import TrainingCore

struct SetEntryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    @State private var entry = SetEntryDraft()
    private enum Field: Hashable { case reps, left, right }
    @FocusState private var focused: Field?
    private var movement: Movement { model.movement(for: row) }
    private var nextIndex: Int? { model.nextSetIndex(for: row.movementID) }
    private var exact: Bool { (try? RulesetCatalog.resolve(version: model.snapshot.state.rulesetVersion, hash: model.snapshot.state.rulesetHash)).flatMap { try? ProgramPolicy.resolve(schemaVersion: model.snapshot.state.schemaVersion, rules: $0) }?.usesExactTargets == true }
    private var target: Int? {
        guard let index = nextIndex, row.sets.indices.contains(index) else { return nil }
        return row.sets[index].targetReps
    }
    private var observation: ActualSet? { entry.observation(target: target, repCounting: movement.repCounting, exact: exact) }
    private var belowGoal: Bool { exact && entry.requiresReason(target: target, repCounting: movement.repCounting) }
    private var actual: ActualSet? {
        guard let observed = observation, exact || observed.reps > 0 || (observed.leftReps ?? 0) > 0 || (observed.rightReps ?? 0) > 0 else { return nil }
        return observed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((model.log(for: row.movementID)?.actualSets ?? []).enumerated()), id: \.offset) { index, set in
                Text(movement.repCounting == .perSide ? "Set \((set.setIndex ?? index) + 1): left \(set.leftReps.map(String.init) ?? "unrecorded"), right \(set.rightReps.map(String.init) ?? "unrecorded")" : "Set \((set.setIndex ?? index) + 1): \(set.reps) reps")
                    .accessibilityIdentifier("set.actual.\(set.setIndex ?? index)")
            }
            ForEach(model.log(for: row.movementID)?.skippedSetIndices ?? [], id: \.self) { index in Text("Set \(index + 1): skipped").accessibilityIdentifier("set.skipped.\(index)") }
            if !model.handled(row.movementID), let index = nextIndex, row.kind != .paused, model.log(for: row.movementID)?.problem == Problem.none {
                Text("Set \(index + 1) of \(row.sets.count)").font(.headline)
                if exact, let goal = row.sets[index].targetReps { Text("Set \(index + 1) goal: \(goal) reps\(movement.repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("set.goal") }
                if movement.repCounting == .perSide {
                    TextField("Left reps performed", text: $entry.left).focused($focused, equals: .left).accessibilityLabel("Left reps performed").accessibilityIdentifier("set.left-reps")
                    TextField("Right reps performed", text: $entry.right).focused($focused, equals: .right).accessibilityLabel("Right reps performed").accessibilityIdentifier("set.right-reps")
                    Text("An unfinished or unequal side is kept as partial.").font(.caption)
                } else { TextField("Reps performed", text: $entry.reps).focused($focused, equals: .reps).accessibilityLabel("Reps performed").accessibilityIdentifier("set.reps") }
                if belowGoal { MissedGoalReasonPicker(selection: $entry.reason) }
                Button("Save performed set") {
                    guard let actual else { return }
                    focused = nil
                    Task {
                        await model.run {
                            try await model.recordSet(movementID: row.movementID, index: index, actual: actual)
                            clearEntry()
                        }
                    }
                }
                .disabled(model.blockedWorkingMovementIDs.contains(row.movementID) || actual == nil || (belowGoal && entry.reason == nil) || model.busy || (movement.loadingMode == .externalLoad && model.log(for: row.movementID)?.actualLoad == nil))
                .accessibilityIdentifier("set.save")
                if exact {
                    Button("Skip this set") {
                        focused = nil
                        Task { await model.run { try await model.skipSet(movementID: row.movementID, index: index); clearEntry() } }
                    }.disabled(observation != nil || model.busy).accessibilityIdentifier("set.skip")
                }
            }
        }
        .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
        .onChange(of: [entry.reps, entry.left, entry.right]) {
            entry.update(reps: entry.reps, left: entry.left, right: entry.right, target: target, repCounting: movement.repCounting)
            pendingActual = observation
        }
        .onChange(of: entry.reason) { pendingActual = observation }
        .onChange(of: nextIndex) { clearEntry() }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = nil }.accessibilityIdentifier("keyboard.done") } }
    }
    private func clearEntry() { entry = SetEntryDraft(); pendingActual = nil }
}
