import SwiftUI
import TrainingCore

struct OnboardingView<Restore: View>: View {
    let composition: AppComposition
    let operationInProgress: Bool
    let confirm: (Goal) async -> Void
    @ViewBuilder var restore: () -> Restore
    @State private var selected: Goal?
    @State private var saving = false
    var body: some View {
        Form {
            Section { NavigationLink("Restore an existing JSON backup", destination: restore).disabled(operationInProgress).accessibilityIdentifier("onboarding.restore") }
            Section { NavigationLink("Optional iCloud recovery") { CloudRecoveryView(composition: composition) }.accessibilityIdentifier("onboarding.cloud-recovery") }
            Section("Your goal") {
                ForEach(Goal.allCases, id: \.self) { goal in
                    Button { selected = goal } label: {
                        HStack { Text(goal.title); Spacer(); if selected == goal { Image(systemName: "checkmark") } }
                    }
                    .accessibilityIdentifier("onboarding.goal.\(goal.rawValue)")
                    .accessibilityAddTraits(selected == goal ? [.isSelected] : [])
                }
            }
            Section("Your routine") {
                Text("Sunday · Tuesday · Thursday")
                Text("Required: dumbbells in 5 lb steps, 5–80 lb per dumbbell; a pull-up bar; an adjustable bench.")
                    .accessibilityIdentifier("onboarding.equipment")
                Text("Dumbbell loads are per hand unless the movement says total. Reps on each side are recorded separately. Starting weights are your choice; no performed reps are filled in.")
                Text("Modifications is optional text describing your setup. Each saved setup keeps its own baseline and history.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(saving ? "Saving…" : "Confirm goal and routine") {
                    guard let selected, !saving, !operationInProgress else { return }
                    saving = true
                    Task { await confirm(selected); saving = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil || saving || operationInProgress)
                .accessibilityIdentifier("onboarding.confirm")
                Text("No account, no subscription, no telemetry. Training works locally on this device.").font(.footnote)
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}
extension Goal {
    var title: String {
        switch self { case .fatLoss: "Fat loss"; case .size: "Size"; case .strength: "Strength"; case .maintenance: "Maintenance" }
    }
}
