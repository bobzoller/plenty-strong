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
                    if let envelope = model.completedEnvelope, case let .workout(event, _) = envelope.command {
                        let issued = MovementPrescriptionSummary.issuedWorkout(envelope: envelope, history: model.snapshot.history)
                        ForEach(event.exercises, id: \.movementID) { log in
                            VStack(alignment: .leading) {
                                Text(MovementPrescriptionSummary.effectiveMovement(state: issued?.state ?? envelope.returnedState, variantID: log.movementID)?.name ?? "Movement").font(.headline)
                                if let row = issued?.displayed.exercises.first(where: { $0.movementID == log.movementID }) {
                                    let issuedMovement = issued.flatMap { MovementPrescriptionSummary.effectiveMovement(state: $0.state, variantID: row.movementID) }
                                    Text("Today's goal: \(MovementPrescriptionSummary.goal(row, policy: issued?.policy, repCounting: issuedMovement?.repCounting ?? .total))").accessibilityIdentifier("workout.completed-goal.\(log.movementID)")
                                    let issuedLoad = row.load.map { "Issued load: \(MovementPrescriptionSummary.load($0))" } ?? issuedMovement.map { $0.loadingMode == .externalLoad ? "Issued load: no numeric load prescribed" : "Issued load: bodyweight / your setup — no numeric load inferred" } ?? "Issued load unavailable — movement metadata unverified"
                                    Text(issuedLoad)
                                        .accessibilityIdentifier("workout.completed-issued-load.\(log.movementID)")
                                } else {
                                    Text("Recorded goal unavailable")
                                    Text("Issued load unavailable — original prescription unverified").accessibilityIdentifier("workout.completed-issued-load.\(log.movementID)")
                                }
                                Text(log.actualSets.isEmpty ? "Actual: no performed sets" : "Actual: \(WorkoutDetailView.reps(log))").accessibilityIdentifier("workout.completed-actual.\(log.movementID)")
                                let loadingMode = MovementPrescriptionSummary.effectiveMovement(state: issued?.state ?? envelope.returnedState, variantID: log.movementID)?.loadingMode
                                Text(log.actualLoad.map { "Actual load: \(MovementPrescriptionSummary.load($0))" } ?? (loadingMode != nil && loadingMode != .externalLoad ? "Actual load: bodyweight / your setup — no numeric load recorded" : "Actual load: not recorded"))
                                    .accessibilityIdentifier("workout.completed-actual-load.\(log.movementID)")
                                Text("Outcome: \(log.status.rawValue)")
                                if envelope.returnedState.exercises[log.movementID]?.starterState?.doseStage == .established,
                                   issued?.displayed.exercises.first(where: { $0.movementID == log.movementID })?.sets.count == 2 {
                                    Text("Ready for 3 sets; keep the same weight and establish your baseline.").accessibilityIdentifier("workout.completed-set-growth")
                                }
                            }
                        }
                        Text("Next saved prescription").font(.headline)
                        Text("Its calendar date is a suggestion. This workout stays next until completed.")
                        Text("Next: \(envelope.returnedPrescription.slotID), \(envelope.returnedPrescription.date.iso8601)").accessibilityIdentifier("workout.next-prescription")
                        ForEach(envelope.returnedPrescription.exercises, id: \.movementID) { row in
                            VStack(alignment: .leading) {
                                Text(MovementPrescriptionSummary.effectiveMovement(state: envelope.returnedState, variantID: row.movementID)?.name ?? "Movement").font(.headline)
                                if row.kind == .paused { Text("Paused") }
                                else { Text(MovementPrescriptionSummary.goal(row, policy: MovementPrescriptionSummary.make(row: row, state: envelope.returnedState, history: model.snapshot.history, draft: nil).policy, repCounting: MovementPrescriptionSummary.effectiveMovement(state: envelope.returnedState, variantID: row.movementID)?.repCounting ?? .total)).accessibilityIdentifier("workout.next-goal.\(row.movementID)") }
                                if let load = row.load { Text("Prescription: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                            }
                        }
                    } else {
                        Text("Saved completion details unavailable — open History to view the retained original record.")
                    }
                    Button("Back to Today", action: close)
                } else if model.snapshot.draft == nil {
                    Text("No saved workout draft is available. Return to Today to prepare it again.")
                    Button("Back to Today", action: close)
                } else if model.needsDateChoice {
                    Text("This workout belongs to \(model.snapshot.draft!.date.iso8601) in \(model.snapshot.draft!.timeZoneID).")
                    Text("Keep the original date and observations as history, or explicitly discard this draft and restart the same next workout with a new session date.")
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
            VStack(alignment: .leading, spacing: 6) {
                if !model.finished, !model.needsDateChoice, movementIndex < rows.count, model.snapshot.draft != nil {
                    let row = rows[movementIndex]
                    ViewThatFits(in: .horizontal) {
                        HStack { stopButtons(row) }
                        VStack(alignment: .leading) { stopButtons(row) }
                    }.disabled(model.busy || model.log(for: row.movementID)?.problem != Problem.none)
                }
                if model.busy { ProgressView("Saving workout…").accessibilityIdentifier("workout.busy") }
                if let error = model.errorText { Text(error).foregroundStyle(.red).accessibilityIdentifier("save.error") }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
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
        if model.snapshot.state.exercises[row.movementID]?.starterState?.doseStage == .introductory {
            Text("Starting with 2 sets").accessibilityIdentifier("movement.introductory")
        } else if model.snapshot.state.exercises[row.movementID]?.starterState?.doseStage == .established, row.phase == .baseline {
            Text("Ready for 3 sets; keep the same weight and establish your baseline.").accessibilityIdentifier("movement.established-baseline")
        }
        if let choice = try? StarterProgramCatalog.choice(for: model.snapshot.state.config),
           let details = try? StarterProgramPresentation.details(choice: choice, goal: model.snapshot.state.config.goal),
           let cues = details.cuesByMovementID[row.baseMovementID ?? row.movementID] {
            DisclosureGroup("Movement cues") { ForEach(cues, id: \.self) { Text($0) } }
        }
        if row.phase == .baseline { Text("Baseline — this setup has its own starting point").accessibilityIdentifier("movement.baseline") }
        if model.canChangePreparation, pendingActual == nil { Button("Movement setup") { showingSetup = true }.accessibilityIdentifier("movement.setup") }
        if row.kind == .paused {
            Text("Paused — no working sets. A new setup cannot clear the safety pause.").accessibilityIdentifier("movement.paused")
        } else {
            PrescriptionComparisonView(summary: .make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft), repCounting: metadata.repCounting)
            if row.kind == .setupReview {
                Text("Choose a manageable saved setup or create a new setup. To restart this setup's baseline, return to Today and use Settings. Existing history and safety remain.")
                if model.canChangePreparation { Button("Review movement setup") { showingSetup = true }.accessibilityIdentifier("movement.review-setup") }
            }
            if metadata.loadingMode == .externalLoad {
                if let prescribed = row.load { Text("Prescription: \(prescribed.amount) \(prescribed.unit.rawValue) \(prescribed.basis == .perImplement ? "per hand" : "total"). Confirm the actual load below.") }
                Text(log?.actualLoad.map { "Confirmed: \($0.amount) \($0.unit.rawValue) \($0.basis == .perImplement ? "per hand" : "total")" } ?? (model.handled(row.movementID) ? "Actual load unrecorded; original observations retained" : "Confirm actual dumbbell load before recording sets"))
                if log?.actualSets.isEmpty == true, !model.handled(row.movementID) {
                    if let prescribed = row.load {
                        Button("Confirm prescribed load: \(MovementPrescriptionSummary.load(prescribed))") {
                            Task { await model.run { try await model.confirmLoad(movementID: row.movementID, load: prescribed) } }
                        }.accessibilityIdentifier("load.confirm-prescribed")
                    }
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
                if log?.actualSets.isEmpty == false, !model.handled(row.movementID) {
                    Button("Different loads used — keep as partial") { Task { await model.run { try await model.recordMixedLoads(movementID: row.movementID); pendingActual = nil } } }.disabled(pendingActual != nil).accessibilityIdentifier("load.mixed")
                }
            } else { Text("Bodyweight / your setup — no numeric load is inferred") }
        }
        Text("Stopping early to preserve effort or control is correct. Actual reps are recorded independently.")
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
        if !row.sets.isEmpty, log?.actualSets.isEmpty == false, (model.nextSetIndex(for: row.movementID) == nil || model.handled(row.movementID)) { EffortPicker(model: model, movementID: row.movementID) }

        if model.handled(row.movementID) { Button("Next movement") { movementIndex += 1; pendingActual = nil }.accessibilityIdentifier("movement.next") }
    }
    private func statusButton(_ title: String, status: LogStatus, id: String, row: ExercisePrescription) -> some View {
        Button(title) { Task { await model.run { try await model.recordStatus(movementID: row.movementID, status: status, pendingActual: pendingActual); pendingActual = nil } } }.accessibilityIdentifier(id)
    }
    @ViewBuilder private func stopButtons(_ row: ExercisePrescription) -> some View {
        Button("Pain — stop") { problem(.pain, row: row) }.accessibilityIdentifier("problem.pain")
        Button("Loss of control — stop") { problem(.controlLost, row: row) }.accessibilityIdentifier("problem.control_lost")
    }
    private func problem(_ problem: Problem, row: ExercisePrescription) {
        Task { await model.run { try await model.recordProblem(movementID: row.movementID, problem: problem, pendingActual: pendingActual); pendingActual = nil } }
    }
}
