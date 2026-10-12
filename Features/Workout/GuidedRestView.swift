import SwiftUI
import TrainingCore

struct WorkoutSessionModeLabel: View {
    let model: WorkoutViewModel
    var body: some View {
        if !model.finished, let draft = model.snapshot.draft, draft.sessionMode == .easier {
            Text("Easier workout")
                .accessibilityIdentifier("workout.session-mode")
        }
    }
}

struct GuidedRestView: View {
    let model: WorkoutViewModel
    let step: WorkoutStep
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkoutSessionModeLabel(model: model)
            Text("Rest").font(.largeTitle)
            if let deadline = model.snapshot.draft?.restDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Rest: \(RestTimer(deadline: deadline).remaining(at: model.now())) seconds remaining")
                        .font(.largeTitle.bold()).monospacedDigit().accessibilityIdentifier("rest.remaining")
                }
            }
            if case let .rest(_, _, destination) = step {
                switch destination {
                case let .set(id, index):
                    Text("Next: Set \(index + 1)").font(.headline)
                    if let row = model.snapshot.draft?.displayed.exercises.first(where: { $0.movementID == id }), row.sets.indices.contains(index) {
                        let movement = model.movement(for: row), goal = row.sets[index]
                        Text("Goal: \(goal.targetReps.map(String.init) ?? "up to \(goal.repCeiling)") reps\(movement.repCounting == .perSide ? " per side" : "")")
                            .accessibilityIdentifier("rest.next-goal")
                        Text(model.log(for: id)?.actualLoad.map { "Weight: \(MovementPrescriptionSummary.load($0))" } ?? weightPlaceholder(movement.loadingMode))
                            .accessibilityIdentifier("rest.next-weight")
                        GuidedMovementCues(model: model, row: row)
                    }
                case let .introduction(id):
                    if let row = model.snapshot.draft?.displayed.exercises.first(where: { $0.movementID == id }) {
                        Text("Next: \(model.movement(for: row).name ?? "Movement")").font(.headline)
                        Text(row.modificationsSnapshot?.isEmpty == false ? row.modificationsSnapshot! : "Default setup")
                        Text(row.load.map { "Issued load: \(MovementPrescriptionSummary.load($0))" } ?? weightPlaceholder(model.movement(for: row).loadingMode))
                            .accessibilityIdentifier("rest.next-weight")
                        GuidedMovementCues(model: model, row: row)
                    }
                }
            }
        }
    }
    private func weightPlaceholder(_ mode: LoadingMode) -> String {
        switch mode {
        case .externalLoad: "Weight: Unknown load"
        case .bodyweight: "Bodyweight / your setup — no numeric load is inferred"
        case .userManagedAssistance: "Your assistance setup — no numeric load is inferred"
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

/// Callers supply primary and secondary actions; saving feedback stays pinned.
struct GuidedWorkoutFooter<Actions: View, Secondary: View>: View {
    let model: WorkoutViewModel
    let actions: Actions
    let secondary: Secondary
    init(model: WorkoutViewModel, @ViewBuilder actions: () -> Actions, @ViewBuilder secondary: () -> Secondary) {
        self.model = model; self.actions = actions(); self.secondary = secondary()
    }
    var body: some View {
        VStack(spacing: 8) {
            actions
            secondary
            if model.busy { ProgressView("Saving workout…").accessibilityIdentifier("workout.busy") }
            if let error = model.errorText {
                ScrollView { Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("save.error") }.frame(maxHeight: 120)
            }
            if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
        }.padding(.horizontal).padding(.vertical, 8).frame(maxWidth: .infinity).background(.regularMaterial)
    }
}
extension GuidedWorkoutFooter where Secondary == EmptyView {
    init(model: WorkoutViewModel, @ViewBuilder actions: () -> Actions) {
        self.init(model: model, actions: actions, secondary: { EmptyView() })
    }
}
