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
                ForEach(model.snapshot.state.activePrescription.exercises, id: \.movementID) { row in
                    VStack(alignment: .leading) {
                        Text(model.movement(for: row).name ?? "Movement").font(.headline)
                        if let load = row.load { Text("Prescription: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                        if model.blockedWorkingMovementIDs.contains(row.movementID) { Text("Additional work unavailable: another saved program has a pause or stricter effort reserve. Recorded observations can be kept and finished safely.") }
                        if row.kind == .paused { Text("Paused — no working sets") }
                        else if let set = row.sets.first {
                            Text("\(row.sets.count) sets · Up to \(set.repCeiling) good reps")
                            Text(set.effortInstruction)
                        }
                    }
                }
            }

        }
    }
}
