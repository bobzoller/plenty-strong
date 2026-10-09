import SwiftUI
import TrainingCore

struct ProgramChoiceView: View {
    @Binding var selection: StarterProgramChoice?
    var identifierPrefix = "onboarding.program"
    var body: some View {
        Text("Choose the emphasis you want. Either program is for anyone.")
        ForEach(StarterProgramChoice.allCases, id: \.self) { choice in
            Button { selection = choice } label: {
                HStack(alignment: .top, spacing: 16) {
                    ProgramChoiceIcon(choice: choice).frame(width: 48, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(choice.title).font(.headline)
                        Text(choice.description).font(.body)
                        if selection == choice { Label("Selected", systemImage: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).padding(.vertical, 8).contentShape(Rectangle())
            }
            .foregroundStyle(selection == choice ? Color.accentColor : Color.primary)
            .accessibilityLabel("\(choice.title). \(choice.description)")
            .accessibilityAddTraits(selection == choice ? [.isButton, .isSelected] : [.isButton])
            .accessibilityIdentifier("\(identifierPrefix).\(choice.rawValue)")
        }
    }
}
