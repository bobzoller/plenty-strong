import SwiftUI
import TrainingCore

/// Immutable issued goals alongside independently recorded observations. This is
/// also the shared comparison presentation for final review; it never replans.
struct WorkoutComparisonRows: View {
    let row: ExercisePrescription
    let log: ExerciseLog?
    let repCounting: RepCounting
    let loadingMode: LoadingMode

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Goal").font(.subheadline.bold())
                Text("Actual").font(.subheadline.bold())
            }
            GridRow {
                Text("Goal weight: \(weight(row.load))").accessibilityIdentifier("summary.goal-weight")
                Text("Actual weight: \(weight(log?.actualLoad))").accessibilityIdentifier("summary.actual-weight")
            }.font(.subheadline)
            ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                GridRow {
                    Text("Set \(index + 1) · goal \(goal.targetReps.map(String.init) ?? "up to \(goal.repCeiling)") reps\(repCounting == .perSide ? " per side" : "")")
                        .accessibilityIdentifier("summary.slot.\(index)")
                    if let actual = log?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element {
                        Text(actualText(actual, index: index)).accessibilityIdentifier("set.actual.\(index)")
                    } else if log?.skippedSetIndices?.contains(index) == true {
                        Text("Set \(index + 1): skipped").accessibilityIdentifier("set.skipped.\(index)")
                    } else {
                        Text("Set \(index + 1): unrecorded").accessibilityIdentifier("set.unrecorded.\(index)")
                    }
                }.font(.subheadline)
            }
        }
    }
    private func weight(_ load: Load?) -> String {
        if loadingMode == .bodyweight { return "Bodyweight" }
        return load.map(MovementPrescriptionSummary.load) ?? "Unknown load"
    }
    private func actualText(_ actual: ActualSet, index: Int) -> String {
        if repCounting == .perSide || actual.leftReps != nil || actual.rightReps != nil {
            return "Set \(index + 1): left \(actual.leftReps.map(String.init) ?? "unrecorded"), right \(actual.rightReps.map(String.init) ?? "unrecorded")"
        }
        return "Set \(index + 1): \(actual.reps) reps"
    }
}
