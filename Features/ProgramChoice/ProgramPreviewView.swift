import SwiftUI
import TrainingCore

struct ProgramPreviewView: View {
    let choice: StarterProgramChoice
    let goal: Goal
    var body: some View {
        List {
            if let details = try? StarterProgramPresentation.details(choice: choice, goal: goal) {
                Section(details.title) {
                    Text(details.description)
                    Text("Goal: \(goal.title)")
                    Text("Sunday · Tuesday · Thursday")
                    if !details.duration.isEmpty { Text(details.duration).accessibilityIdentifier("program.preview.duration") }
                    ForEach(details.equipment, id: \.self) { Text($0) }
                    Text("Dumbbell loads are per hand unless the movement says total. A single dumbbell uses its total weight. Bodyweight has no numeric load. Per-side reps stay separate; a set completed on both sides counts once.")
                }
                if choice == .wholeBodyGlutes {
                    Section("Starting with 2 sets") {
                        Text("Every movement starts with 2 working sets. Size and strength can reach 3 sets for RDL, press, row and suitcase squat after two qualifying normal exposures in the same context. Keep the same weight and establish your baseline. Fat loss and maintenance retain 2 sets.")
                        Text("36 starting sets weekly (12 / 12 / 12). Established size and strength: 44 sets (15 / 13 / 16).")
                    }
                }
                Section("Weekly muscle exposure") {
                    ForEach(details.coverageRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.muscle).font(.headline)
                            Text("Starting: \(row.initialWork)")
                            Text("Established size: \(row.establishedWork)")
                            Text("Days per week: \(row.days)")
                        }
                    }
                }
                Section("Coverage and setup limitations") { ForEach(details.limitations, id: \.self) { Text($0) } }
                Section("Movement cues") {
                    if let definition = try? StarterProgramCatalog.definition(choice) {
                        ForEach(definition.movements, id: \.id) { movement in
                            if let cues = details.cuesByMovementID[movement.id] {
                                DisclosureGroup(movement.name ?? movement.id) { ForEach(cues, id: \.self) { Text($0) } }
                            }
                        }
                    }
                }
            } else { Text("Program preview unavailable. The stored definition could not be verified.") }
        }.navigationTitle("Program preview")
    }
}
