import SwiftUI
import TrainingCore

/// Immutable issued goals alongside independently recorded observations. This is
/// also the shared comparison presentation for final review; it never replans.
struct WorkoutComparisonRows: View {
    let row: ExercisePrescription
    let log: ExerciseLog?
    let repCounting: RepCounting
    let loadingMode: LoadingMode
    var identifierPrefix = ""
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                goalWeight
                actualWeight
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                    VStack(alignment: .leading, spacing: 4) {
                        goalText(goal, index: index)
                        actualText(index: index)
                    }
                }
            }.font(.subheadline)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Goal").font(.subheadline.bold())
                    Text("Actual").font(.subheadline.bold())
                }
                GridRow { goalWeight; actualWeight }.font(.subheadline)
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                    GridRow { goalText(goal, index: index); actualText(index: index) }.font(.subheadline)
                }
            }
        }
    }
    private var goalWeight: some View {
        Text("Goal weight: \(weight(row.load))").accessibilityIdentifier(identifierPrefix + "summary.goal-weight")
    }
    private var actualWeight: some View {
        Text("Actual weight: \(weight(log?.actualLoad))").accessibilityIdentifier(identifierPrefix + "summary.actual-weight")
    }
    private func goalText(_ goal: SetPrescription, index: Int) -> some View {
        Text("Set \(index + 1) · goal \(goal.targetReps.map(String.init) ?? "up to \(goal.repCeiling)") reps\(repCounting == .perSide ? " per side" : "")")
            .accessibilityIdentifier(identifierPrefix + "summary.slot.\(index)")
    }
    @ViewBuilder private func actualText(index: Int) -> some View {
        if let actual = log?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element {
            Text(actualText(actual, index: index)).accessibilityIdentifier(identifierPrefix + "set.actual.\(index)")
        } else if log?.skippedSetIndices?.contains(index) == true {
            Text("Set \(index + 1): skipped").accessibilityIdentifier(identifierPrefix + "set.skipped.\(index)")
        } else {
            Text("Set \(index + 1): unrecorded").accessibilityIdentifier(identifierPrefix + "set.unrecorded.\(index)")
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
