import SwiftUI
import TrainingCore

struct EffortPicker: View {
    let model: WorkoutViewModel
    let movementID: String
    private var exact: Bool { model.log(for: movementID)?.effortScope == .allWorkingSets }
    var body: some View {
        VStack(alignment: .leading) {
            Text(exact ? "How hard were the working sets?" : "How hard was that?").font(.headline).accessibilityIdentifier("effort.question")
            if exact {
                Text("Too easy: every set left substantially more reserve than intended. About right: appropriately challenging, with no set too hard. Too hard: at least one set could not preserve the intended reserve. I'm not sure: you cannot judge.")
                    .accessibilityIdentifier("effort.meanings")
            }
            ForEach(Effort.allCases, id: \.self) { effort in
                Button {
                    Task { await model.run { try await model.recordEffort(movementID: movementID, effort: effort) } }
                } label: {
                    HStack {
                        Text(effort.title)
                        if model.log(for: movementID)?.finalEffort == effort { Image(systemName: "checkmark") }
                    }
                }.accessibilityIdentifier("effort.\(effort.rawValue)").disabled(model.busy)
            }
        }
    }
}
extension Effort {
    var title: String {
        switch self { case .tooEasy: "Too easy"; case .onTarget: "About right"; case .tooHard: "Too hard"; case .unknown: "I'm not sure" }
    }
}
