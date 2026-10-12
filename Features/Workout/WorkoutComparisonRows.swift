import SwiftUI
import TrainingCore

/// Immutable issued goals alongside raw observations; editing belongs to callers.
struct WorkoutComparisonRows: View {
    let row: ExercisePrescription
    let log: ExerciseLog?
    let repCounting: RepCounting
    let loadingMode: LoadingMode
    var identifierPrefix = ""
    var editSet: ((Int) -> Void)? = nil
    var editingDisabled = false
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                Text("Weight").font(.subheadline.bold())
                VStack(alignment: .leading) { Text("Goal").bold(); goalWeight; Text("Actual").bold(); actualWeight }
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Set \(index + 1)").bold(); Spacer(); editButton(index: index) }
                        Text("Goal").bold(); goalText(goal, index: index)
                        Text("Actual").bold(); actualText(index: index)
                    }
                }
            }.font(.subheadline)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Set"); Text("Goal"); Text("Actual"); Text("Edit") }.font(.subheadline.bold())
                GridRow { Text("Weight"); goalWeight; actualWeight; Text("") }
                ForEach(Array(row.sets.enumerated()), id: \.offset) { index, goal in
                    GridRow { Text("\(index + 1)"); goalText(goal, index: index); actualText(index: index); editButton(index: index) }
                }
            }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func editButton(index: Int) -> some View {
        if let editSet, actual(index: index) != nil {
            Button { editSet(index) } label: { Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.primary).disabled(editingDisabled)
                .accessibilityLabel("Correct Set \(index + 1)")
                .accessibilityIdentifier((identifierPrefix.isEmpty ? "summary." : identifierPrefix) + "correct.\(index)")
        } else { Text("") }
    }
    private var goalWeight: some View {
        Text(weight(row.load)).accessibilityIdentifier(identifierPrefix + "summary.goal-weight")
    }
    private var actualWeight: some View {
        Text(weight(log?.actualLoad)).accessibilityIdentifier(identifierPrefix + "summary.actual-weight")
    }
    private func goalText(_ goal: SetPrescription, index: Int) -> some View {
        Text("\(goal.targetReps.map(String.init) ?? "Up to \(goal.repCeiling)") reps\(repCounting == .perSide ? " per side" : "")")
            .accessibilityIdentifier(identifierPrefix + "summary.slot.\(index)")
    }
    private func actual(index: Int) -> ActualSet? {
        log?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element
    }
    @ViewBuilder private func actualText(index: Int) -> some View {
        if let actual = actual(index: index) {
            Text(actualText(actual)).accessibilityIdentifier(identifierPrefix + "set.actual.\(index)")
        } else if log?.skippedSetIndices?.contains(index) == true {
            Text("Skipped").accessibilityIdentifier(identifierPrefix + "set.skipped.\(index)")
        } else {
            Text("Unrecorded").accessibilityIdentifier(identifierPrefix + "set.unrecorded.\(index)")
        }
    }
    private func weight(_ load: Load?) -> String {
        if loadingMode == .bodyweight { return "Bodyweight" }
        return load.map(MovementPrescriptionSummary.load) ?? "Unknown load"
    }
    private func actualText(_ actual: ActualSet) -> String {
        if repCounting == .perSide || actual.leftReps != nil || actual.rightReps != nil {
            if actual.leftReps == nil && actual.rightReps == nil {
                return "Recorded \(actual.reps) reps; left unrecorded, right unrecorded"
            }
            return "Left \(actual.leftReps.map(String.init) ?? "unrecorded"), right \(actual.rightReps.map(String.init) ?? "unrecorded")"
        }
        return "\(actual.reps) reps"
    }
}
