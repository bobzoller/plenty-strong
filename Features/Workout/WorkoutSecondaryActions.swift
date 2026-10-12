import SwiftUI
import TrainingCore

/// A single entry point keeps outcomes tied to the current cursor and safety to
/// the named source. All persistence remains in the existing model commands.
struct WorkoutSecondaryActions: View {
    let model: WorkoutViewModel
    let step: WorkoutStep
    let row: ExercisePrescription
    @Binding var pendingActual: ActualSet?
    @State private var showingActions = false
    @State private var correctingLoad = false

    private var sourceName: String { model.movement(for: row).name ?? "Movement" }
    private var reviewing: Bool { model.reviewStep != nil }
    private var workingEntry: Bool {
        guard !reviewing else { return false }
        if case .set = step { return true }
        return false
    }
    private var hasTypedInput: Bool {
        workingEntry && [model.entryDraft.reps, model.entryDraft.left, model.entryDraft.right].contains { !$0.isEmpty }
    }
    private var sourceEditable: Bool {
        !model.handled(row.movementID) && model.log(for: row.movementID)?.problem == Problem.none
    }
    private var skipTarget: (row: ExercisePrescription, index: Int?)? {
        guard !reviewing, !hasTypedInput, pendingActual == nil else { return nil }
        switch step {
        case let .set(id, index): return id == row.movementID && sourceEditable ? (row, index) : nil
        case let .rest(_, _, .set(id, index)): return id == row.movementID && sourceEditable ? (row, index) : nil
        case let .rest(_, _, .introduction(id)):
            guard let next = model.snapshot.draft?.displayed.exercises.first(where: { $0.movementID == id }),
                  !model.handled(id), model.log(for: id)?.actualSets.isEmpty == true else { return nil }
            return (next, nil)
        case .introduction: return sourceEditable && model.log(for: row.movementID)?.actualSets.isEmpty == true ? (row, nil) : nil
        default: return nil
        }
    }
    private var canCorrectLoad: Bool {
        !reviewing && sourceEditable && row.kind != .paused && model.movement(for: row).loadingMode == .externalLoad
    }
    private var canEndSource: Bool {
        guard !reviewing, sourceEditable else { return false }
        if case .rest(_, _, .introduction) = step { return false }
        return true
    }
    private var hasAvailableActions: Bool {
        if canEndSource || canCorrectLoad || model.log(for: row.movementID)?.problem == Problem.none { return true }
        guard let target = skipTarget else { return false }
        return target.index == nil || [3, 4, 5].contains(model.snapshot.state.schemaVersion)
    }
    var body: some View {
        if hasAvailableActions {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                showingActions = true
            } label: {
                Text("Skip").frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing).contentShape(Rectangle())
            }.accessibilityIdentifier("workout.skip")
                .disabled(model.busy || model.snapshot.health != .ready || model.hasAmbiguousFinish || model.finished)
                .confirmationDialog("Workout actions", isPresented: $showingActions, titleVisibility: .visible) {
                    if let target = skipTarget {
                        if let index = target.index, [3, 4, 5].contains(model.snapshot.state.schemaVersion) {
                            Button("Skip Set \(index + 1)") { perform { try await model.skipSet(movementID: target.row.movementID, index: index) } }
                                .accessibilityIdentifier("set.skip")
                        } else if target.index == nil {
                            Button("Skip \(model.movement(for: target.row).name ?? "movement")") { perform { try await model.recordStatus(movementID: target.row.movementID, status: .skipped) } }
                                .accessibilityIdentifier("movement.skip")
                        }
                    }
                    if canEndSource {
                        Button("Keep \(sourceName) as partial") { outcome(.partial) }.accessibilityIdentifier("movement.partial-action")
                        Button("Stop \(sourceName)") { outcome(.stopped) }.accessibilityIdentifier("movement.stop")
                    }
                    Button("Pain — stop \(sourceName)") { safety(.pain) }.accessibilityIdentifier("problem.pain")
                        .disabled(model.log(for: row.movementID)?.problem != Problem.none)
                    Button("Loss of control — stop \(sourceName)") { safety(.controlLost) }.accessibilityIdentifier("problem.control_lost")
                        .disabled(model.log(for: row.movementID)?.problem != Problem.none)
                    if canCorrectLoad {
                        Button("Incorrect load — keep observations and stop") { correctingLoad = true }.accessibilityIdentifier("load.correct")
                        if [3, 4, 5].contains(model.snapshot.state.schemaVersion), model.log(for: row.movementID)?.actualSets.isEmpty == false, !hasTypedInput, pendingActual == nil {
                            Button("Different loads used — keep as partial") { perform { try await model.recordMixedLoads(movementID: row.movementID) } }
                                .accessibilityIdentifier("load.mixed")
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Safety and load reports apply to \(sourceName). Entered reps are retained when ending this movement.")
                }
                .alert("Correct recorded load?", isPresented: $correctingLoad) {
                    Button("Cancel", role: .cancel) {}
                    Button("Keep observations; stop this movement") { perform { try await model.stopForLoadCorrection(movementID: row.movementID, pendingActual: workingEntry ? pendingActual : nil) } }
                } message: {
                    Text("The saved load and reps are retained as partial work. Choose the corrected load at this movement's next workout. A new attempt in this workout is unavailable.")
                }
        }
    }
    private func outcome(_ status: LogStatus) {
        perform { try await model.recordStatus(movementID: row.movementID, status: status, pendingActual: workingEntry ? pendingActual : nil) }
    }
    private func safety(_ problem: Problem) {
        perform { try await model.recordProblem(movementID: row.movementID, problem: problem, pendingActual: workingEntry ? pendingActual : nil) }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !hasTypedInput || pendingActual != nil else {
            model.errorText = "Enter valid nonnegative reps before saving this outcome. Your text is retained."
            return
        }
        Task { await model.run {
            try await action()
            // A correction/review never consumes replacement text as a new set.
            if workingEntry { pendingActual = nil }
        } }
    }
}
