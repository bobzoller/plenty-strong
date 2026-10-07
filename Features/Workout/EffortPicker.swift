import SwiftUI
import TrainingCore

struct EffortPicker: View {
    let model: WorkoutViewModel
    let movementID: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("How hard was that?").font(.headline)
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
