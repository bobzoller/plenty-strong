import SwiftUI
import TrainingCore

struct EffortPicker: View {
    let model: WorkoutViewModel
    let movementID: String
    @Binding var selection: Effort?
    var identifierPrefix = ""
    private var exact: Bool { model.log(for: movementID)?.effortScope == .allWorkingSets }
    var body: some View {
        VStack(alignment: .leading) {
            Text(exact ? "How hard were the working sets?" : "How hard was that?").font(.headline).accessibilityIdentifier(identifierPrefix + "effort.question")
            Picker(selection: $selection) {
                Text("Choose effort…").tag(nil as Effort?).accessibilityIdentifier(identifierPrefix + "effort.placeholder")
                ForEach(Effort.allCases, id: \.self) { effort in
                    Text(effort.title).tag(Optional(effort)).accessibilityIdentifier(identifierPrefix + "effort.\(effort.rawValue)")
                }
            } label: { Text("Effort") }
                .pickerStyle(.menu).labelsHidden().accessibilityIdentifier(identifierPrefix + "effort.picker").disabled(model.busy)
            DisclosureGroup {
                Text(exact ?
                     "Too easy: every set left substantially more reserve than intended. About right: appropriately challenging, with no set too hard. Too hard: at least one set could not preserve the intended reserve. I'm not sure: you cannot judge." :
                     "For the final working set: Too easy means you could have done several more good reps. About right means challenging, with roughly two good reps left. Too hard means you reached your limit or could not leave a couple of good reps. I'm not sure means you cannot judge.")
                    .accessibilityIdentifier(identifierPrefix + "effort.meanings")
            } label: {
                Text("What do these mean?").accessibilityIdentifier(identifierPrefix + "effort.meanings-disclosure")
            }
        }
    }
}
extension Effort {
    var title: String {
        switch self { case .tooEasy: "Too easy"; case .onTarget: "About right"; case .tooHard: "Too hard"; case .unknown: "I'm not sure" }
    }
}
