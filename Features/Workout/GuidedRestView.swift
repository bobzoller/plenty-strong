import SwiftUI
import TrainingCore

struct GuidedRestView: View {
    let model: WorkoutViewModel
    let step: WorkoutStep
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rest").font(.largeTitle)
            if let deadline = model.snapshot.draft?.restDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Rest: \(RestTimer(deadline: deadline).remaining(at: model.now())) seconds remaining")
                        .font(.title2).accessibilityIdentifier("rest.remaining")
                }
            }
            Text("Continue when you are ready. Reaching zero keeps you here until you choose Next.")
            if case let .rest(source, _, destination) = step {
                GuidedActualsView(model: model, movementID: source)
                switch destination {
                case let .set(_, index): Text("Next: Set \(index + 1)").font(.headline)
                case let .introduction(id):
                    if let row = model.snapshot.draft?.displayed.exercises.first(where: { $0.movementID == id }) {
                        Text("Next: \(model.movement(for: row).name ?? "Movement")").font(.headline)
                        Text(row.modificationsSnapshot?.isEmpty == false ? row.modificationsSnapshot! : "Default setup")
                        if let load = row.load { Text("Issued load: \(MovementPrescriptionSummary.load(load))") }
                        else { Text("Bodyweight / your setup — no numeric load is inferred") }
                        GuidedMovementCues(model: model, row: row)
                    }
                }
            }
        }
    }
}

struct GuidedActualsView: View {
    let model: WorkoutViewModel
    let movementID: String
    var body: some View {
        if let log = model.log(for: movementID), let row = model.snapshot.draft?.displayed.exercises.first(where: { $0.movementID == movementID }) {
            ForEach(Array(log.actualSets.enumerated()), id: \.offset) { offset, set in
                let index = set.setIndex ?? offset
                Text(model.movement(for: row).repCounting == .perSide ? "Set \(index + 1): left \(set.leftReps.map(String.init) ?? "unrecorded"), right \(set.rightReps.map(String.init) ?? "unrecorded")" : "Set \(index + 1): \(set.reps) reps")
                    .accessibilityIdentifier("set.actual.\(index)")
            }
            ForEach(log.skippedSetIndices ?? [], id: \.self) { index in Text("Set \(index + 1): skipped").accessibilityIdentifier("set.skipped.\(index)") }
        }
    }
}

struct GuidedMovementCues: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    var body: some View {
        if let choice = try? StarterProgramCatalog.choice(for: model.snapshot.state.config),
           let details = try? StarterProgramPresentation.details(choice: choice, goal: model.snapshot.state.config.goal),
           let cues = details.cuesByMovementID[row.baseMovementID ?? row.movementID] {
            DisclosureGroup("Movement cues") { ForEach(cues, id: \.self) { Text($0) } }
        }
    }
}

/// One footer owns the primary action, safety and feedback, including with a keyboard.
struct GuidedWorkoutFooter<Actions: View>: View {
    let model: WorkoutViewModel
    var row: ExercisePrescription?
    @Binding var pendingActual: ActualSet?
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var textSize
    init(model: WorkoutViewModel, row: ExercisePrescription? = nil, pendingActual: Binding<ActualSet?> = .constant(nil), @ViewBuilder actions: () -> Actions) {
        self.model = model; self.row = row; _pendingActual = pendingActual; self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 8) {
            actions
            if let row, !model.hasAmbiguousFinish, !model.finished {
                Group {
                    if textSize.isAccessibilitySize { VStack(spacing: 4) { safetyButtons(row) } }
                    else { HStack(spacing: 16) { safetyButtons(row) } }
                }.font(textSize.isAccessibilitySize ? .caption : .body)
                    .disabled(model.busy || model.snapshot.health != .ready || model.log(for: row.movementID)?.problem != Problem.none)
            }
            if model.busy { ProgressView("Saving workout…").accessibilityIdentifier("workout.busy") }
            if let error = model.errorText {
                ScrollView { Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("save.error") }.frame(maxHeight: 120)
            }
            if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
        }.padding(.horizontal).padding(.vertical, 8).frame(maxWidth: .infinity).background(.regularMaterial)
    }
    @ViewBuilder private func safetyButtons(_ row: ExercisePrescription) -> some View {
        Button(textSize.isAccessibilitySize ? "Pain" : "Pain — stop") { stop(.pain, row: row) }.accessibilityLabel("Pain — stop").accessibilityIdentifier("problem.pain")
            .frame(maxWidth: .infinity, minHeight: 44)
        Button(textSize.isAccessibilitySize ? "Lost control" : "Loss of control — stop") { stop(.controlLost, row: row) }.accessibilityLabel("Loss of control — stop").accessibilityIdentifier("problem.control_lost")
            .frame(maxWidth: .infinity, minHeight: 44)
    }
    private func stop(_ problem: Problem, row: ExercisePrescription) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { await model.run { try await model.recordProblem(movementID: row.movementID, problem: problem, pendingActual: pendingActual); pendingActual = nil } }
    }
}
