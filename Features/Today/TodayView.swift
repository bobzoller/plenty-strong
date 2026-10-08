import SwiftUI
import TrainingCore

struct TodayView: View {
    let model: WorkoutViewModel
    let optionalServicesUnavailable: Bool
    let start: () -> Void
    var body: some View {
        List {
            Section("\(model.snapshot.state.config.goal.title) routine") {
                Text("Sunday · Tuesday · Thursday").accessibilityIdentifier("today.schedule")
                Text("Next workout: \(model.snapshot.draft?.date.iso8601 ?? model.snapshot.state.activePrescription.date.iso8601)")
                if optionalServicesUnavailable { Text("Optional services unavailable. Local training is available.").accessibilityIdentifier("today.offline") }
                if model.snapshot.draft != nil { Text("Your saved workout can be resumed with its original observations and date.") }
                if model.snapshot.decisions.contains(where: { $0.explanationKey == "workout_rescheduled" }) { Text("Missed slots were rescheduled without recording a completed workout.") }
            }
            if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
            if model.snapshot.health == .mixedPolicyConflict { Text("Recovery histories use different training policies. All original branches are retained and working admission is blocked. Export originals for review; choosing or dropping a branch is currently unsupported.").accessibilityIdentifier("store.mixed-policy-conflict") }
            if let error = model.errorText { Text(error).foregroundStyle(.red).accessibilityIdentifier("save.error") }
            Button(model.snapshot.draft == nil ? "Start workout" : "Resume workout") {
                Task {
                    await model.run {
                        try await model.start(easierToday: model.snapshot.draft?.sessionMode == .easier)
                        start()
                    }
                }
            }.disabled(model.busy || model.snapshot.health != .ready)
                .accessibilityIdentifier("today.start")
            Section("Prescription") {
                ForEach((model.snapshot.draft?.displayed ?? model.snapshot.state.activePrescription).exercises, id: \.movementID) { row in
                    VStack(alignment: .leading) {
                        Text(model.movement(for: row).name ?? "Movement").font(.headline)
                        if model.blockedWorkingMovementIDs.contains(row.movementID) { Text("Additional work unavailable: another saved program has a pause or stricter effort reserve. Recorded observations can be kept and finished safely.") }
                        PrescriptionComparisonView(summary: .make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft), repCounting: model.movement(for: row).repCounting)
                        if row.kind == .setupReview { Text("Review this movement in Movement setup, or reset its baseline in Settings. A new setup keeps its own history and cannot clear a safety pause.") }
                    }
                }
            }

        }
    }
}
