import SwiftUI
import TrainingCore

struct OnboardingView<Restore: View>: View {
    let composition: AppComposition
    let operationInProgress: Bool
    let confirm: (StarterProgramChoice, Goal) async -> Void
    @ViewBuilder var restore: () -> Restore
    @State private var selected: Goal?
    @State private var emphasis: StarterProgramChoice?
    @State private var saving = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Form {
            Section { NavigationLink("Restore an existing JSON backup", destination: restore).disabled(operationInProgress).accessibilityIdentifier("onboarding.restore") }
            Section { NavigationLink("Optional iCloud recovery") { CloudRecoveryView(composition: composition) }.accessibilityIdentifier("onboarding.cloud-recovery") }
            Section("Your emphasis") { ProgramChoiceView(selection: $emphasis) }
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
                if let emphasis, let selected {
                    NavigationLink("Preview this program") { ProgramPreviewView(choice: emphasis, goal: selected) }
                        .accessibilityIdentifier("onboarding.preview")
                    Text(emphasis == .upperBody ? "Required: dumbbells in 5 lb steps, 5–80 lb per dumbbell; a pull-up bar; an adjustable bench." : "Required: dumbbells in 5 lb steps, 5–80 lb per dumbbell; an adjustable bench.")
                        .accessibilityIdentifier("onboarding.equipment")
                }
                Text("Dumbbell loads are per hand unless the movement says total. Reps on each side are recorded separately. Each set has a rep goal. Starting weights are your choice; actual reps stay blank until you enter them.")
                Text("Modifications is optional text describing your setup. Each saved setup keeps its own baseline and history.")
            }
            if dynamicTypeSize.isAccessibilitySize { Section { confirmation } }
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                confirmation.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
    }
    private var confirmation: some View {
        VStack(spacing: 8) {
            Button(saving ? "Saving…" : "Confirm emphasis and goal") {
                guard let emphasis, let selected, !saving, !operationInProgress else { return }
                saving = true
                Task { await confirm(emphasis, selected); saving = false }
            }
            .buttonStyle(.borderedProminent)
            .disabled(emphasis == nil || selected == nil || saving || operationInProgress)
            .accessibilityIdentifier("onboarding.confirm")
            Text("No account, no subscription, no telemetry. Training works locally on this device.").font(.footnote)
        }
    }
}
extension Goal {
    var title: String {
        switch self { case .fatLoss: "Fat loss"; case .size: "Size"; case .strength: "Strength"; case .maintenance: "Maintenance" }
    }
}
