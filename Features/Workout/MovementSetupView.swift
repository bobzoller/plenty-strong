import SwiftUI
import TrainingCore

struct MovementSetupView: View {
    let model: WorkoutViewModel
    let row: ExercisePrescription
    @Environment(\.dismiss) private var dismiss
    @State private var modifications = ""
    private var variants: [MovementVariant] {
        (model.snapshot.state.config.variants ?? [:]).values.filter { $0.baseMovementID == row.baseMovementID }.sorted {
            if $0.modifications.isEmpty != $1.modifications.isEmpty { return $0.modifications.isEmpty }
            return $0.id < $1.id
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Saved setups") {
                    ForEach(variants, id: \.id) { variant in
                        Button(variant.modifications.isEmpty ? "Default setup" : variant.modifications) {
                            apply(.select(baseMovementID: variant.baseMovementID, variantID: variant.id))
                        }.accessibilityIdentifier(variant.modifications.isEmpty ? "setup.select.default" : "setup.select.\(variant.id)")
                    }
                }
                Section("Modifications (optional)") {
                    TextField("Modifications", text: $modifications, axis: .vertical).accessibilityIdentifier("setup.modifications")
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
            .toolbar { Button("Cancel") { dismiss() } }
            .onAppear { modifications = row.modificationsSnapshot ?? "" }
        }
    }
    private func apply(_ change: VariantChange) {
        Task { await model.run { try await model.changeSetup(change); dismiss() } }
    }
}
