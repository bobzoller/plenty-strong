import SwiftUI
import TrainingCore

struct ProgramSettingsView: View {
    let model: WorkoutViewModel
    @State private var pending: ConfigurationChange?
    @State private var showingConfirmation = false
    @State private var setupRow: ExercisePrescription?
    var body: some View {
        List {
            if model.snapshot.health != .ready {
                Text("Local storage requires review before program changes. Original training data is retained. Status: \(model.snapshot.health.rawValue)").accessibilityIdentifier("settings.health")
            } else if !model.canEditProgramSettings {
                Text("A saved workout or Finish retry is protected. Return to Today and finish safely. Use an explicit discard only where the workout offers it; a recorded problem must be finalized with its original observations.").accessibilityIdentifier("settings.draft-lock")
            }
            if let error = model.errorText { Text(error).foregroundStyle(.red).accessibilityIdentifier("save.error") }
            Section("Goal") {
                Text(model.snapshot.state.config.goal.title).accessibilityIdentifier("settings.current-goal")
                ForEach(Goal.allCases, id: \.self) { goal in
                    Button(goal.title) { pending = .goal(goal); showingConfirmation = true }
                        .disabled(!model.canEditProgramSettings || model.busy || goal == model.snapshot.state.config.goal)
                        .accessibilityIdentifier("settings.goal.\(goal.rawValue)")
                }
                Text("Goal changes restart baselines. Original work, known loads, setup identities and stricter safety restrictions are retained.")
            }
            Section("Fixed routine") { Text("Sunday · Tuesday · Thursday. Dumbbells 5–80 lb in 5 lb steps; pull-up bar; adjustable bench. Schedule, equipment and base movements are fixed in this version.") }
            Section("Saved setups and safety") {
                ForEach(model.snapshot.state.config.movements, id: \.id) { movement in
                    if let id = model.snapshot.state.config.activeVariantIDs?[movement.id], let state = model.snapshot.state.exercises[id], let variant = model.snapshot.state.config.variants?[id] {
                        DisclosureGroup {
                            Text(variant.modifications.isEmpty ? "Default setup" : variant.modifications)
                            Text("Minimum effort reserve: \(model.snapshot.state.baseSafety?[movement.id]?.minimumRir ?? movement.minimumRir) good reps left. Safety restrictions cannot be loosened here.")
                            Button("Change setup or correct description") {
                                setupRow = ExercisePrescription(movementID: id, kind: state.mode == .paused ? .paused : .working, phase: .normal, load: state.load, sets: [], restSeconds: 0, stopInstruction: "Stop earlier for pain or loss of control.", baseMovementID: movement.id, modificationsSnapshot: variant.modifications)
                            }.accessibilityIdentifier("settings.setup.\(movement.id)")
                            Button("Reset this setup baseline") { pending = .resetSetup(variantID: id); showingConfirmation = true }
                                .accessibilityIdentifier("settings.reset.\(movement.id)")
                            if model.snapshot.state.baseSafety?[movement.id]?.paused == true {
                                Text("Paused across every saved setup. Creating, selecting or resetting a setup cannot bypass the pause.").accessibilityIdentifier("settings.paused.\(movement.id)")
                                Button("Review safe return") { pending = .safeResume(baseMovementID: movement.id, externalClearanceConfirmed: true); showingConfirmation = true }
                                    .accessibilityIdentifier("settings.safe-resume.\(movement.id)")
                            }
                        } label: {
                            Text(movement.name ?? movement.id).accessibilityIdentifier("settings.movement.\(movement.id)")
                        }.disabled(!model.canEditProgramSettings || model.busy)
                    }
                }
            }
        }.navigationTitle("Program")
        .sheet(isPresented: Binding(get: { setupRow != nil }, set: { if !$0 { setupRow = nil } })) {
            if let row = setupRow { MovementSetupView(model: model, row: row) }
        }
        .alert(confirmationTitle, isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button(confirmTitle) {
                guard let change = pending else { return }
                Task { await model.run { try await model.changeProgram(change) }; pending = nil }
            }.accessibilityIdentifier("settings.confirm-change")
        } message: { Text(confirmationMessage) }
    }
    private var confirmationTitle: String {
        if case .safeResume = pending { return "Confirm safe return?" }
        return "Restart baseline?"
    }
    private var confirmTitle: String {
        if case .safeResume = pending { return "I confirm external clearance for a safe return" }
        return "Keep history and restart baseline"
    }
    private var confirmationMessage: String {
        if case .safeResume = pending { return "Resume only after the appropriate external review and clearance for the recorded pain or control problem. Confirming restarts baselines for this base movement; stricter effort restrictions and safety provenance remain." }
        return "Original workout history, known loads and shared safety restrictions will remain. Only the affected comparison windows restart."
    }
}
