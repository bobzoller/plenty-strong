import SwiftUI
import TrainingCore

struct WorkoutView: View {
    let model: WorkoutViewModel
    let close: () -> Void
    @State private var movementIndex = 0
    @State private var showingSetup = false
    @State private var correctingLoad = false
    @State private var discarding = false
    @State private var reviewingPending = false
    @State private var repairingCompletion = false
    @State private var pendingActual: ActualSet?
    private var rows: [ExercisePrescription] { model.snapshot.draft?.displayed.exercises ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.finished {
                    Text("Workout saved on this device").font(.title2).accessibilityIdentifier("workout.saved")
                    Text("Next: \(model.snapshot.state.activePrescription.slotID), \(model.snapshot.state.activePrescription.date.iso8601)").accessibilityIdentifier("workout.next-prescription")
                    ForEach(model.snapshot.state.activePrescription.exercises, id: \.movementID) { row in
                        VStack(alignment: .leading) {
                            Text(model.movement(for: row).name ?? "Movement").font(.headline)
                            if row.kind == .paused { Text("Paused") }
                            else if let set = row.sets.first {
                                Text("\(row.sets.count) sets · Up to \(set.repCeiling) good reps")
                                Text(set.effortInstruction)
                            }
                            if let load = row.load { Text("Prescription: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                        }
                    }
                    Button("Back to Today", action: close)
                } else if model.snapshot.draft == nil {
                    Text("No saved workout draft is available. Return to Today to prepare it again.")
                    Button("Back to Today", action: close)
                } else if model.needsDateChoice {
                    Text("This workout belongs to \(model.snapshot.draft!.date.iso8601) in \(model.snapshot.draft!.timeZoneID).")
                    Text("Keep the original date and observations as history, or explicitly discard this draft and restart at the next scheduled slot.")
                    if movementIndex < rows.count {
                        let row = rows[movementIndex]
                        Text(model.movement(for: row).name ?? "Movement").font(.headline)
                        Button("Pain — stop") { problem(.pain, row: row) }.accessibilityIdentifier("problem.pain")
                            .disabled(model.log(for: row.movementID)?.problem != Problem.none)
                        Button("Loss of control — stop") { problem(.controlLost, row: row) }.accessibilityIdentifier("problem.control_lost")
                            .disabled(model.log(for: row.movementID)?.problem != Problem.none)
                    }
                    Button("Keep original date and observations") { Task { await model.run { try await model.resolveDateChange(keepOriginal: true) } } }.accessibilityIdentifier("workout.keep-original-date")
                    if !model.canDiscardDraft { Text("A safety stop or pending Finish must be retained and finalized. Keep the original date, then handle the remaining movements.") }
                    Button("Discard draft and restart", role: .destructive) { discarding = true }.accessibilityIdentifier("workout.discard-restart").disabled(!model.canDiscardDraft)
                } else if movementIndex < rows.count {
                    let row = rows[movementIndex]
                    Text(model.snapshot.draft?.sessionMode == .easier ? "Easier workout" : "Normal workout").accessibilityIdentifier("workout.session-mode")
                    if model.canChangePreparation, pendingActual == nil {
                        Button("I need an easier workout today") { Task { await model.run { try await model.start(easierToday: true) } } }
                            .accessibilityIdentifier("workout.easier")
                    }
                    movement(row)
                } else {
                    Text("Review complete. Every movement has an explicit outcome.")
                    if model.canRecoverRejectedCompletion {
                        Button("Repair unaccepted completion") { repairingCompletion = true }.accessibilityIdentifier("workout.repair-completion")
                    }
                    Button("Finish workout") { Task { await model.run { _ = try await model.finish() } } }
                        .accessibilityIdentifier("workout.finish")
                    Button("Review movements") { movementIndex = 0 }
                }
                if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
            }.padding().disabled(model.busy || model.snapshot.health != .ready)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.errorText {
                Text(error).foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial).accessibilityIdentifier("save.error")
            }
        }
        .toolbar {
            if !model.finished {
                Button("Review saved movements", systemImage: "list.bullet") {
                    if movementIndex != 0, pendingActual != nil { reviewingPending = true }
                    else { movementIndex = 0 }
                }.labelStyle(.iconOnly).accessibilityIdentifier("workout.review")
                Button("Back to Today", systemImage: "xmark", action: close).labelStyle(.iconOnly).accessibilityIdentifier("workout.close")
            }
        }
        .sheet(isPresented: $showingSetup) {
            if movementIndex < rows.count { MovementSetupView(model: model, row: rows[movementIndex]) }
        }
        .alert("Correct recorded load?", isPresented: $correctingLoad) {
            Button("Cancel", role: .cancel) {}
            Button("Keep observations; stop this movement") {
                if movementIndex < rows.count { Task { await model.run { try await model.stopForLoadCorrection(movementID: rows[movementIndex].movementID, pendingActual: pendingActual); pendingActual = nil } } }
            }
        } message: {
            Text("The saved load and reps are retained as partial work. Choose the corrected load at this movement's next workout. A new attempt in this workout is unavailable.")
        }
        .alert("Keep entered reps before reviewing?", isPresented: $reviewingPending) {
            Button("Cancel", role: .cancel) {}
            Button("Keep entry as partial and review") {
                if movementIndex < rows.count {
                    let id = rows[movementIndex].movementID
                    Task { await model.run { try await model.recordStatus(movementID: id, status: .partial, pendingActual: pendingActual); pendingActual = nil; movementIndex = 0 } }
                }
            }
        } message: { Text("The entered observations will be saved as partial work before leaving this movement.") }
        .alert("Repair unaccepted completion?", isPresented: $repairingCompletion) {
            Button("Cancel", role: .cancel) {}
            Button("Keep observations and repair outcomes") { Task { await model.run { try await model.recoverRejectedCompletion() } } }
        } message: {
            Text("Affected movements: \(model.recoveryMovementNames.joined(separator: ", ")). Performed observations become partial; empty movements without problems become skipped. Original reps, loads and problems are retained. This does not qualify completed work.")
        }
        .alert("Discard saved observations?", isPresented: $discarding) {
            Button("Cancel", role: .cancel) {}
            Button("Discard and restart", role: .destructive) {
                Task { await model.run { try await model.resolveDateChange(keepOriginal: false); close() } }
            }
        }
        .onAppear { movementIndex = rows.firstIndex { !model.handled($0.movementID) } ?? rows.count }
    }
    @ViewBuilder private func movement(_ row: ExercisePrescription) -> some View {
        let metadata = model.movement(for: row)
        let log = model.log(for: row.movementID)
        Text("\(movementIndex + 1) of \(rows.count) · \(metadata.name ?? "Movement")").font(.title2)
        Text(row.modificationsSnapshot?.isEmpty == false ? row.modificationsSnapshot! : "Default setup").accessibilityIdentifier("movement.modifications")
        if model.blockedWorkingMovementIDs.contains(row.movementID) {
            Text("Additional working sets are unavailable: a saved program has a pause or stricter effort reserve for this movement. Keep any already-performed reps as partial or stopped, then finish safely. Changing programs does not clear safety.").accessibilityIdentifier("movement.retained-safety")
        }
        if row.phase == .baseline { Text("Baseline — this setup has its own starting point").accessibilityIdentifier("movement.baseline") }
        if model.canChangePreparation, pendingActual == nil { Button("Movement setup") { showingSetup = true }.accessibilityIdentifier("movement.setup") }
        if row.kind == .paused {
            Text("Paused — no working sets. A new setup cannot clear the safety pause.").accessibilityIdentifier("movement.paused")
        } else if let set = row.sets.first {
            VStack(alignment: .leading) {
                Text("Up to \(set.repCeiling) good reps\(metadata.repCounting == .perSide ? " per side" : " total")").font(.headline)
                Text(set.effortInstruction)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("movement.instruction")
            if metadata.loadingMode == .externalLoad {
                if let prescribed = row.load { Text("Prescription: \(prescribed.amount) \(prescribed.unit.rawValue) \(prescribed.basis == .perImplement ? "per hand" : "total"). Confirm the actual load below.") }
                Text(log?.actualLoad.map { "Confirmed: \($0.amount) \($0.unit.rawValue) \($0.basis == .perImplement ? "per hand" : "total")" } ?? (model.handled(row.movementID) ? "Actual load unrecorded; original observations retained" : "Confirm actual dumbbell load before recording sets"))
                if log?.actualSets.isEmpty == true, !model.handled(row.movementID) {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(metadata.availableLoads, id: \.amount) { load in
                                Button("\(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") {
                                    Task { await model.run { try await model.confirmLoad(movementID: row.movementID, load: load) } }
                                }.accessibilityIdentifier("load.choose.\(load.amount)")
                            }
                        }
                    }
                } else if !model.handled(row.movementID) { Button("Correct load") { correctingLoad = true }.accessibilityIdentifier("load.correct") }
            } else { Text("Bodyweight / your setup — no numeric load is inferred") }
        }
        VStack(alignment: .leading) {
            Text("Pain or loss of control? Stop this movement now.")
            Button("Pain — stop") { problem(.pain, row: row) }.accessibilityIdentifier("problem.pain")
            Button("Loss of control — stop") { problem(.controlLost, row: row) }.accessibilityIdentifier("problem.control_lost")
        }.disabled(log?.problem != Problem.none)
        SetEntryView(model: model, row: row, pendingActual: $pendingActual).id(row.movementID)
        if let deadline = model.snapshot.draft?.restDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("Rest: \(RestTimer(deadline: deadline).remaining(at: model.now())) seconds remaining")
                    .accessibilityIdentifier("rest.remaining")
            }
        }
        if log?.problem != Problem.none {
            Text("Stopped for \(log?.problem == .pain ? "pain" : "loss of control"). Observations are saved.").accessibilityIdentifier("movement.stopped")
        } else if model.handled(row.movementID), log?.status == .partial {
            Text("Partial — saved observations retained").accessibilityIdentifier("movement.partial")
        }
        if !model.handled(row.movementID) {
            if log?.actualSets.count == row.sets.count, !row.sets.isEmpty { statusButton("All sets performed", status: .completed, id: "movement.complete", row: row) }
            statusButton("Keep as partial", status: .partial, id: "movement.partial-action", row: row)
            if log?.actualSets.isEmpty == true, pendingActual == nil { statusButton("Skip movement", status: .skipped, id: "movement.skip", row: row) }
            statusButton("Stop movement", status: .stopped, id: "movement.stop", row: row)
        }
        if !row.sets.isEmpty, log?.actualSets.isEmpty == false, (log?.actualSets.count == row.sets.count || model.handled(row.movementID)) { EffortPicker(model: model, movementID: row.movementID) }

        if model.handled(row.movementID) { Button("Next movement") { movementIndex += 1; pendingActual = nil }.accessibilityIdentifier("movement.next") }
    }
    private func statusButton(_ title: String, status: LogStatus, id: String, row: ExercisePrescription) -> some View {
        Button(title) { Task { await model.run { try await model.recordStatus(movementID: row.movementID, status: status, pendingActual: pendingActual); pendingActual = nil } } }.accessibilityIdentifier(id)
    }
    private func problem(_ problem: Problem, row: ExercisePrescription) {
        Task { await model.run { try await model.recordProblem(movementID: row.movementID, problem: problem, pendingActual: pendingActual); pendingActual = nil } }
    }
}
