import SwiftUI
import TrainingCore

struct SetEntryView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    @State private var reps = ""
    @State private var left = ""
    @State private var right = ""
    private enum Field: Hashable { case reps, left, right }
    @FocusState private var focused: Field?
    private var movement: Movement { model.movement(for: row) }
    private var count: Int { model.log(for: row.movementID)?.actualSets.count ?? 0 }
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
            return ActualSet(reps: l ?? r ?? 0, leftReps: l, rightReps: r)
        }
        return number(reps).map { ActualSet(reps: $0) }
    }
    private var actual: ActualSet? {
        guard let observed = observation, observed.reps > 0 || (observed.leftReps ?? 0) > 0 || (observed.rightReps ?? 0) > 0 else { return nil }
        return observed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((model.log(for: row.movementID)?.actualSets ?? []).enumerated()), id: \.offset) { index, set in
                Text(movement.repCounting == .perSide ? "Set \(index + 1): left \(set.leftReps.map(String.init) ?? "unrecorded"), right \(set.rightReps.map(String.init) ?? "unrecorded")" : "Set \(index + 1): \(set.reps) reps")
                    .accessibilityIdentifier("set.actual.\(index)")
            }
            if !model.handled(row.movementID), count < row.sets.count, row.kind != .paused, model.log(for: row.movementID)?.problem == Problem.none {
                Text("Set \(count + 1) of \(row.sets.count)").font(.headline)
                if movement.repCounting == .perSide {
                    TextField("Left reps performed", text: $left).focused($focused, equals: .left).accessibilityLabel("Left reps performed").accessibilityIdentifier("set.left-reps")
                    TextField("Right reps performed", text: $right).focused($focused, equals: .right).accessibilityLabel("Right reps performed").accessibilityIdentifier("set.right-reps")
                    Text("An unfinished or unequal side is kept as partial.").font(.caption)
                } else { TextField("Reps performed", text: $reps).focused($focused, equals: .reps).accessibilityLabel("Reps performed").accessibilityIdentifier("set.reps") }
                Button("Save performed set") {
                    guard let actual else { return }
                    focused = nil
                    Task {
                        await model.run {
                            try await model.recordSet(movementID: row.movementID, index: count, actual: actual)
                            reps = ""; left = ""; right = ""; pendingActual = nil
                        }
                    }
                }
                .disabled(model.blockedWorkingMovementIDs.contains(row.movementID) || actual == nil || model.busy || (movement.loadingMode == .externalLoad && model.log(for: row.movementID)?.actualLoad == nil))
                .accessibilityIdentifier("set.save")
            }
        }
        .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
        .onChange(of: [reps, left, right]) { pendingActual = observation }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = nil }.accessibilityIdentifier("keyboard.done") } }
    }
}
