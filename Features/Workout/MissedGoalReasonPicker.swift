import SwiftUI
import TrainingCore

struct MissedGoalReasonPicker: View {
    @Binding var selection: MissedGoalReason?
    var required = true
    var body: some View {
        VStack(alignment: .leading) {
            Text(required ? "Why did you stop before the goal?" : "Reason, if known (optional)").font(.headline).accessibilityIdentifier("set.miss-question")
            ForEach(MissedGoalReason.allCases, id: \.self) { reason in
                Button { selection = reason } label: {
                    HStack { Text(reason.title); if selection == reason { Image(systemName: "checkmark") } }
                }.accessibilityIdentifier("reason.\(reason.rawValue)").accessibilityAddTraits(selection == reason ? .isSelected : [])
            }
        }
    }
}
extension MissedGoalReason {
    var title: String {
        switch self { case .effortLimit: "Effort limit"; case .timeInterruption: "Time or interruption"; case .otherUnknown: "Other / I'm not sure" }
    }
}
