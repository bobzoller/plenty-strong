import SwiftUI
import TrainingCore

struct SetEntryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    @State private var reps = ""
    @State private var left = ""
    @State private var right = ""
    @State private var missedReason: MissedGoalReason?
    private enum Field: Hashable { case reps, left, right }
    @FocusState private var focused: Field?
    private var movement: Movement { model.movement(for: row) }
    private var nextIndex: Int? { model.nextSetIndex(for: row.movementID) }
    private var exact: Bool { (try? RulesetCatalog.resolve(version: model.snapshot.state.rulesetVersion, hash: model.snapshot.state.rulesetHash)).flatMap { try? ProgramPolicy.resolve(schemaVersion: model.snapshot.state.schemaVersion, rules: $0) }?.usesExactTargets == true }
    private func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let number = Int(text), number >= 0 else { return nil }
        return number
    }
    private var observation: ActualSet? {
        if movement.repCounting == .perSide {
            // Missing sides remain missing; unequal originals are never summed or erased.
            guard left.isEmpty || number(left) != nil, right.isEmpty || number(right) != nil else { return nil }
            let l = number(left), r = number(right)
            guard l != nil || r != nil else { return nil }
            return ActualSet(reps: l ?? r ?? 0, leftReps: l, rightReps: r, missedGoalReason: belowGoal ? missedReason : nil)
        }
        return number(reps).map { ActualSet(reps: $0, missedGoalReason: belowGoal ? missedReason : nil) }
    }
    private var belowGoal: Bool {
        guard exact, let index = nextIndex, row.sets.indices.contains(index), let goal = row.sets[index].targetReps else { return false }
        if movement.repCounting == .perSide { return [number(left), number(right)].compactMap { $0 }.contains { $0 < goal } }
        return number(reps).map { $0 < goal } ?? false
    }
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
                    TextField("Left reps performed", text: $left).focused($focused, equals: .left).accessibilityLabel("Left reps performed").accessibilityIdentifier("set.left-reps")
                    TextField("Right reps performed", text: $right).focused($focused, equals: .right).accessibilityLabel("Right reps performed").accessibilityIdentifier("set.right-reps")
                    Text("An unfinished or unequal side is kept as partial.").font(.caption)
                } else { TextField("Reps performed", text: $reps).focused($focused, equals: .reps).accessibilityLabel("Reps performed").accessibilityIdentifier("set.reps") }
                if belowGoal { MissedGoalReasonPicker(selection: $missedReason) }
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
                .disabled(model.blockedWorkingMovementIDs.contains(row.movementID) || actual == nil || (belowGoal && missedReason == nil) || model.busy || (movement.loadingMode == .externalLoad && model.log(for: row.movementID)?.actualLoad == nil))
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
        .onChange(of: [reps, left, right]) { pendingActual = observation }
        .onChange(of: missedReason) { pendingActual = observation }
        .onChange(of: nextIndex) { clearEntry() }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = nil }.accessibilityIdentifier("keyboard.done") } }
    }
    private func clearEntry() { reps = ""; left = ""; right = ""; missedReason = nil; pendingActual = nil }
}
