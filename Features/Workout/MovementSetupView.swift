import SwiftUI
import TrainingCore

struct MovementSetupView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Environment(\.dismiss) private var dismiss
    @State private var modifications = ""
    @State private var handlingAmount: String?
    @FocusState private var editingModifications: Bool
    private var handlingLoad: Load? { model.movement(for: row).availableLoads.first { $0.amount == handlingAmount } }
    private var variants: [MovementVariant] {
        (model.snapshot.state.config.variants ?? [:]).values.filter { $0.baseMovementID == row.baseMovementID }.sorted {
            if $0.modifications.isEmpty != $1.modifications.isEmpty { return $0.modifications.isEmpty }
            return $0.id < $1.id
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if model.snapshot.state.config.profileID == "starter-glute-v1", row.baseMovementID == "db_floor_glute_bridge" {
                    Section("Bridge setup check") {
                        Text("Some adjustable dumbbells are too bulky or uncomfortable to secure on the pelvis. Use bodyweight if a dumbbell cannot be secured comfortably. Keep ribs down and extend your hips without arching your lower back.")
                        Button("Use a dumbbell") { selectMode(.externalLoad) }.accessibilityIdentifier("setup.bridge.dumbbell")
                        Button("Use bodyweight") { selectMode(.bodyweight) }.accessibilityIdentifier("setup.bridge.bodyweight")
                        Text("Each loading choice is a separate saved setup. Bodyweight has no numeric load; a dumbbell bridge uses one dumbbell's total weight.")
                    }
                }
                if model.snapshot.state.config.profileID == "starter-glute-v1", model.snapshot.state.config.goal == .strength,
                   ["incline_db_press_30", "chest_supported_db_row_30_neutral", "suitcase_db_squat"].contains(row.baseMovementID ?? "") {
                    Section("Strength handling check") {
                        Text("Practice unloaded or lightly loaded. Choose a load you can handle safely with controlled technique and about two good reps left. No working sets are issued until you choose a range.")
                        if let saved = model.snapshot.state.exercises[row.movementID]?.load {
                            Text("Saved load: \(MovementPrescriptionSummary.load(saved))")
                        } else {
                            Picker("Load for 4–6 reps", selection: $handlingAmount) {
                                Text("Choose a load").tag(Optional<String>.none)
                                ForEach(model.movement(for: row).availableLoads, id: \.amount) { load in
                                    Text(MovementPrescriptionSummary.load(load)).tag(Optional(load.amount))
                                }
                            }.accessibilityIdentifier("setup.handling-load")
                        }
                        Button("Use standard 8–12 reps") { review(.standardRange) }.accessibilityIdentifier("setup.handling.standard")
                        Button("I can safely handle this load for 4–6 reps") {
                            if let load = model.snapshot.state.exercises[row.movementID]?.load ?? handlingLoad { review(.lowRep(load: load)) }
                        }.disabled(model.snapshot.state.exercises[row.movementID]?.load == nil && handlingLoad == nil)
                            .accessibilityIdentifier("setup.handling.low-rep")
                        Text("Changing the load or setup requires another handling review. Grip, positioning and dumbbell clearance can limit loading.")
                    }
                }
                Section("Saved setups") {
                    ForEach(variants, id: \.id) { variant in
                        Button(variant.modifications.isEmpty ? "Default setup" : variant.modifications) {
                            apply(.select(baseMovementID: variant.baseMovementID, variantID: variant.id))
                        }.accessibilityIdentifier(variant.modifications.isEmpty ? "setup.select.default" : "setup.select.\(variant.id)")
                    }
                }
                Section("Modifications (optional)") {
                    TextField("Modifications", text: $modifications, axis: .vertical).focused($editingModifications).accessibilityIdentifier("setup.modifications")
                    Text("Describe your setup in your own words. New setups start with a separate baseline and no assumed load. Descriptions do not calculate resistance.")
                    Button("New setup") {
                        apply(.create(baseMovementID: row.baseMovementID!, variantID: UUID().uuidString.lowercased(), modifications: modifications))
                    }.disabled(modifications.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modifications.count > 200)
                        .accessibilityIdentifier("setup.new")
                    if row.modificationsSnapshot?.isEmpty == false {
                        Button("Correct description") {
                            apply(.correctDescription(variantID: row.movementID, modifications: modifications))
                        }.disabled(modifications.count > 200 || modifications.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("setup.correct-description")
                    }
                    Text("Correct description keeps this setup's identity and progress. Previous workout labels are retained.")
                }
            }
            .disabled(model.busy || !model.canChangePreparation)
            .safeAreaInset(edge: .bottom) {
                if let error = model.errorText { Text(error).foregroundStyle(.red).padding().background(.regularMaterial).accessibilityIdentifier("save.error") }
            }
            .navigationTitle("Movement setup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingModifications = false }.accessibilityIdentifier("setup.keyboard-done")
                }
            }
            .onAppear { modifications = row.modificationsSnapshot ?? "" }
        }
    }
    private func review(_ choice: StrengthHandlingChoice) {
        Task { await model.run { try await model.reviewStrengthHandling(variantID: row.movementID, choice: choice); dismiss() } }
    }
    private func selectMode(_ mode: LoadingMode) {
        Task { await model.run { try await model.selectBridgeLoadingMode(variantID: row.movementID, mode: mode); dismiss() } }
    }
    private func apply(_ change: VariantChange) {
        Task { await model.run { try await model.changeSetup(change); dismiss() } }
    }
}
