import SwiftUI
import TrainingCore

/// Native navigation updates synchronously; scratch adoption waits for durable local input.
@MainActor @Observable final class WorkoutReviewNavigation {
    let model: WorkoutViewModel
    var path: [WorkoutReviewRoute] = []
    var retainsCorrectionEntry = false
    private var epoch = 0
    struct DismissalAttempt {
        fileprivate let epoch: Int
        fileprivate let ownership: WorkoutViewModel.EntryOwnership
        fileprivate let path: [WorkoutReviewRoute]
        fileprivate let entry: SetEntryDraft
    }
    init(model: WorkoutViewModel) { self.model = model }
    func invalidate() { epoch += 1 }
    func presentationReopened() {
        invalidate()
        if Self.step(for: path.last) != model.reviewStep {
            // Resume owns the forward input; discard only obsolete native review chrome.
            path = []; retainsCorrectionEntry = false
        }
    }
    func beginDismissal() -> DismissalAttempt {
        epoch += 1
        return DismissalAttempt(epoch: epoch, ownership: model.entryOwnership, path: path, entry: model.entryDraft)
    }
    private static func step(for route: WorkoutReviewRoute?) -> WorkoutStep? {
        switch route {
        case let .summary(id): .summary(movementID: id)
        case let .correction(id, index): .set(movementID: id, index: index)
        case nil: nil
        }
    }
    private func adopt(_ route: WorkoutReviewRoute?) { model.reviewStep = Self.step(for: route) }
    func push(_ route: WorkoutReviewRoute) async throws {
        epoch += 1; let token = epoch
        try await model.flushScratch()
        guard token == epoch, model.operations.contextEnabled else { return }
        retainsCorrectionEntry = false; adopt(route); path.append(route)
    }
    func clearReview() {
        epoch += 1; path = []; retainsCorrectionEntry = false; model.reviewStep = nil
    }
    func dismissed(attempt: DismissalAttempt? = nil, isCurrentOwner: () -> Bool, isStillDismissed: () -> Bool = { true }, restorePresentation: () -> Void) async {
        guard model.operations.contextEnabled, isCurrentOwner() else { return }
        let attempt = attempt ?? beginDismissal()
        func ownsDismissal() -> Bool {
            !Task.isCancelled && model.operations.contextEnabled && isCurrentOwner() && isStillDismissed()
                && attempt.epoch == epoch && attempt.ownership == model.entryOwnership && attempt.path == path
        }
        guard ownsDismissal() else { return }
        do {
            try await model.flushScratch()
            guard ownsDismissal() else { return }
            clearReview()
        } catch {
            guard ownsDismissal() else { return }
            model.entryDraft = attempt.entry; retainsCorrectionEntry = true
            model.errorText = "Workout input could not be saved. Your text is retained. Retry closing after saving. \(error.localizedDescription)"
            restorePresentation()
        }
    }
    func ownsNativeBack(from oldPath: [WorkoutReviewRoute]) -> Bool {
        guard let current = model.reviewStep else { return false }
        if current == Self.step(for: oldPath.last) { return true }
        // correctSet adopts Summary before its Save callback pops native Correction.
        if case let .correction(id, _) = oldPath.last, current == .summary(movementID: id) { return true }
        return false
    }
    func nativeBack(from oldPath: [WorkoutReviewRoute], to newPath: [WorkoutReviewRoute]) async {
        // A programmatic Resume/correction context change already owns the new page.
        guard ownsNativeBack(from: oldPath) else { return }
        epoch += 1; let token = epoch
        let oldStep = model.reviewStep, entered = model.entryDraft
        do { try await model.flushScratch() }
        catch {
            guard token == epoch, model.operations.contextEnabled, path == newPath else { return }
            model.reviewStep = oldStep; model.entryDraft = entered; retainsCorrectionEntry = true; path = oldPath
            model.errorText = "Could not leave this page because workout input could not be saved. Your text is retained. Retry Back or close after saving. \(error.localizedDescription)"
            return
        }
        guard token == epoch, model.operations.contextEnabled, path == newPath else { return }
        adopt(newPath.last)
    }
}

struct WorkoutView: View {
    let model: WorkoutViewModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var navigation: WorkoutReviewNavigation
    init(model: WorkoutViewModel, close: @escaping () -> Void) {
        self.model = model; self.close = close
        _navigation = State(initialValue: WorkoutReviewNavigation(model: model))
    }
    init(model: WorkoutViewModel, close: @escaping () -> Void, navigation: WorkoutReviewNavigation) {
        self.model = model; self.close = close
        _navigation = State(initialValue: navigation)
    }
    private var path: [WorkoutReviewRoute] { navigation.path }
    @State private var showingSetup = false
    @State private var correctingLoad = false
    @State private var discarding = false
    @State private var reviewingPending = false
    @State private var repairingCompletion = false
    @State private var pendingActual: ActualSet?
    @State private var preparationWeight: Load?
    @State private var preparationWeightContext: String?
    @State private var preparationWeightNeedsConfirmation = false
    private var rows: [ExercisePrescription] { model.snapshot.draft?.displayed.exercises ?? [] }
    private var forward: WorkoutStep? { model.snapshot.draft?.flow?.forward ?? model.visibleStep }
    private var currentRow: ExercisePrescription? {
        let id: String?
        switch model.visibleStep {
        case let .introduction(value), let .summary(value), let .set(value, _): id = value
        case let .rest(source, _, _): id = source
        default: id = nil
        }
        return rows.first { $0.movementID == id }
    }
    private var frozen: Bool { model.hasAmbiguousFinish || model.snapshot.draft?.pendingFinish != nil }
    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            Group {
                if model.finished { ScrollView { VStack(alignment: .leading, spacing: 20) { saved }.padding() } }
                else if model.snapshot.draft == nil { ContentUnavailableView("No saved workout", systemImage: "figure.strengthtraining.traditional") }
                else if model.needsDateChoice { dateChoice }
                else if frozen { workoutReview }
                else { stepView(forward).id(String(describing: forward)).transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))) }
            }
            .navigationTitle("Workout").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WorkoutReviewRoute.self) { route in
                switch route {
                case let .summary(id):
                    if let row = rows.first(where: { $0.movementID == id }) { MovementSummaryView(model: model, row: row, reviewing: true, reviewCorrection: { index in pushCorrection(row.movementID, index: index) }) }
                case let .correction(id, index):
                    if let row = rows.first(where: { $0.movementID == id }) {
                        SetEntryView(model: model, row: row, pendingActual: $pendingActual, correctionIndex: index, retainsOpenedEntry: navigation.retainsCorrectionEntry, corrected: { if !path.isEmpty { navigation.path.removeLast() } })
                            .navigationTitle("Correct Set \(index + 1)")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.finished, !frozen {
                        Button("Back", systemImage: "chevron.left") { back() }.accessibilityIdentifier("guided.back").disabled(model.busy)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.finished, !frozen {
                        Button("Review saved movements", systemImage: "list.bullet") { requestReview() }
                            .labelStyle(.iconOnly).accessibilityIdentifier("workout.review").disabled(model.busy || model.needsDateChoice)
                    }
                    Button("Close workout", systemImage: "xmark") {
                        dismissKeyboard()
                        Task { do { try await model.flushScratch(); if model.operations.contextEnabled { close() } } catch {} }
                    }.labelStyle(.iconOnly).accessibilityIdentifier("workout.close")
                }
            }
        }
        .sheet(isPresented: $showingSetup) { if let row = currentRow { MovementSetupView(model: model, row: row) } }
        .alert("Correct recorded load?", isPresented: $correctingLoad) {
            Button("Cancel", role: .cancel) {}
            Button("Keep observations; stop this movement") {
                if let row = currentRow { Task { await model.run { try await model.stopForLoadCorrection(movementID: row.movementID, pendingActual: pendingActual); pendingActual = nil } } }
            }
        } message: { Text("The saved load and reps are retained as partial work. Choose the corrected load at this movement's next workout. A new attempt in this workout is unavailable.") }
        .alert("Keep entered reps before reviewing?", isPresented: $reviewingPending) {
            Button("Cancel", role: .cancel) {}
            Button("Keep entry as partial and review") {
                if let row = currentRow { Task { await model.run {
                    try await model.recordStatus(movementID: row.movementID, status: .partial, pendingActual: pendingActual)
                    pendingActual = nil
                    try await pushSummary(rows.first?.movementID ?? row.movementID)
                } } }
            }
        } message: { Text("The entered observations will be saved as partial work before leaving this movement.") }
        .alert("Repair unaccepted completion?", isPresented: $repairingCompletion) {
            Button("Cancel", role: .cancel) {}
            Button("Keep observations and repair outcomes") { Task { await model.run { try await model.recoverRejectedCompletion() } } }
        } message: { Text("Affected movements: \(model.recoveryMovementNames.joined(separator: ", ")). Performed observations become partial; empty movements without problems become skipped. Original reps, loads and problems are retained. This does not qualify completed work.") }
        .alert("Discard saved observations?", isPresented: $discarding) {
            Button("Cancel", role: .cancel) {}
            Button("Discard and restart", role: .destructive) { Task { await model.run { try await model.resolveDateChange(keepOriginal: false); close() } } }
        }
        .onChange(of: path) { oldPath, newPath in
            if newPath.count < oldPath.count, navigation.ownsNativeBack(from: oldPath) {
                dismissKeyboard()
                Task { await navigation.nativeBack(from: oldPath, to: newPath); pendingActual = nil }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: String(describing: forward))
    }
    @ViewBuilder private func stepView(_ step: WorkoutStep?) -> some View {
        switch step {
        case let .introduction(id):
            if let row = rows.first(where: { $0.movementID == id }) {
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    if model.snapshot.draft?.sessionMode == .easier { WorkoutSessionModeLabel(model: model) }
                    introduction(row)
                }.padding() }.disabled(model.busy || model.snapshot.health != .ready)
                    .safeAreaInset(edge: .bottom) {
                        GuidedWorkoutFooter(model: model, row: row, pendingActual: $pendingActual) {
                        Button(row.sets.isEmpty ? (textSize.isAccessibilitySize ? "Review" : "Review outcome") : (textSize.isAccessibilitySize ? "Start" : "Start movement")) {
                            Task { await model.run { try await model.beginMovement(movementID: id) } }
                        }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityLabel(row.sets.isEmpty ? "Review outcome" : "Start movement").accessibilityIdentifier("guided.next")
                            .disabled(model.busy || model.snapshot.health != .ready || (!row.sets.isEmpty && model.movement(for: row).loadingMode == .externalLoad && !preparationWeightIsConfirmed(for: row)))
                        }
                    }
            }
        case let .set(id, _):
            if let row = rows.first(where: { $0.movementID == id }) {
                SetEntryView(model: model, row: row, pendingActual: $pendingActual, correctLoad: { correctingLoad = true })
            }
        case let .summary(id):
            if let row = rows.first(where: { $0.movementID == id }) { MovementSummaryView(model: model, row: row, reviewing: false, reviewCorrection: { index in pushCorrection(row.movementID, index: index) }) }
        case .rest:
            if let step {
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    GuidedRestView(model: model, step: step)
                    if let row = currentRow { earlyActions(row); Button("Correct load") { correctingLoad = true }.accessibilityIdentifier("load.correct") }
                }.padding() }
                .safeAreaInset(edge: .bottom) {
                    GuidedWorkoutFooter(model: model, row: currentRow) {
                    Button("Next") { Task { await model.run { try await model.advanceRest() } } }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("guided.next").disabled(model.busy || model.snapshot.health != .ready)
                    }
                }
            }
        case .workoutReview: workoutReview
        case nil: ContentUnavailableView("Workout step unavailable", systemImage: "exclamationmark.triangle")
        }
    }
    private var dateChoice: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            WorkoutSessionModeLabel(model: model)
            if let draft = model.snapshot.draft { Text("This workout belongs to \(draft.date.iso8601) in \(draft.timeZoneID).") }
            Text("Keep the original date and observations as history, or explicitly discard this draft and restart the same next workout with a new session date.")
            Button("Keep original date and observations") { Task { await model.run { try await model.resolveDateChange(keepOriginal: true) } } }.accessibilityIdentifier("workout.keep-original-date")
            if !model.canDiscardDraft { Text("A safety stop or pending Finish must be retained and finalized. Keep the original date, then handle the remaining movements.") }
            Button("Discard draft and restart", role: .destructive) { discarding = true }.accessibilityIdentifier("workout.discard-restart").disabled(!model.canDiscardDraft)
        }.padding() }.disabled(model.busy)
            .safeAreaInset(edge: .bottom) { GuidedWorkoutFooter(model: model, row: currentRow) {} }
    }
    private var workoutReview: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            WorkoutSessionModeLabel(model: model)
            Text(frozen ? "Finish pending — retry the exact saved workout" : "Workout review").font(.title2)
            ForEach(rows, id: \.movementID) { row in
                Text(model.movement(for: row).name ?? "Movement").font(.headline)
                Text("Issued goal: \(MovementPrescriptionSummary.goal(row, policy: MovementPrescriptionSummary.make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft).policy, repCounting: model.movement(for: row).repCounting))")
                GuidedActualsView(model: model, movementID: row.movementID)
                Text("Outcome: \(model.log(for: row.movementID)?.status.rawValue ?? "unrecorded")")
                if !frozen {
                    Button("Review \(model.movement(for: row).name ?? "movement")") { Task { await model.run { try await pushSummary(row.movementID) } } }.accessibilityIdentifier("workout.summary.\(row.movementID)")
                    if let flow = model.snapshot.draft?.flow, !flow.reviewedSummaryMovementIDs.contains(row.movementID) { Text("Summary confirmation required") }
                }
            }
        }.padding() }
        .safeAreaInset(edge: .bottom) {
            GuidedWorkoutFooter(model: model) {
            if model.canRecoverRejectedCompletion { Button(textSize.isAccessibilitySize ? "Repair" : "Repair unaccepted completion") { repairingCompletion = true }.accessibilityLabel("Repair unaccepted completion").accessibilityIdentifier("workout.repair-completion").disabled(model.busy) }
            Button(frozen ? "Retry Finish" : "Finish workout") { Task { await model.run { _ = try await model.finish() } } }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("workout.finish").disabled(model.busy || model.snapshot.health != .ready)
            }
        }
    }
    @ViewBuilder private func introduction(_ row: ExercisePrescription) -> some View {
        let metadata = model.movement(for: row), log = model.log(for: row.movementID)
        let summary = MovementPrescriptionSummary.make(row: row, state: model.snapshot.state, history: model.snapshot.history, draft: model.snapshot.draft)
        Text("\((rows.firstIndex(where: { $0.movementID == row.movementID }) ?? 0) + 1) of \(rows.count) · \(metadata.name ?? "Movement")").font(.title2)
        Text(row.modificationsSnapshot?.isEmpty == false ? row.modificationsSnapshot! : "Default setup").accessibilityIdentifier("movement.modifications")
        VStack(alignment: .leading, spacing: 4) {
            if !row.sets.isEmpty { Text("\(row.sets.count) sets").font(.headline) }
            Text(MovementPrescriptionSummary.goal(row, policy: summary.policy, repCounting: metadata.repCounting))
                .accessibilityIdentifier("movement.goal-reps")
            if let instruction = row.sets.first?.effortInstruction { Text(instruction).accessibilityIdentifier("movement.instruction") }
        }
        if metadata.loadingMode == .externalLoad {
            if !row.sets.isEmpty, log?.actualSets.isEmpty == true, log?.problem == Problem.none, !model.handled(row.movementID), row.kind != .paused {
                Picker("Weight", selection: preparationWeightSelection(for: row)) {
                    Text("Choose weight").tag(nil as Int?)
                    ForEach(Array(metadata.availableLoads.enumerated()), id: \.offset) { index, load in
                        Text(MovementPrescriptionSummary.load(load)).tag(Optional(index))
                            .accessibilityIdentifier("load.option.\(load.amount)")
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("load.picker")
                Button(preparationWeightIsConfirmed(for: row) ? "Weight confirmed" : "Confirm weight") {
                    confirmPreparationWeight(for: row)
                }.buttonStyle(.bordered).accessibilityIdentifier("load.confirm")
                    .disabled(selectedPreparationWeight(for: row) == nil || preparationWeightIsConfirmed(for: row))
            } else if let load = log?.actualLoad {
                Text("Weight: \(MovementPrescriptionSummary.load(load))").accessibilityIdentifier("load.recorded")
            }
        } else { Text("Bodyweight / your setup — no numeric load is inferred") }
        if model.canOfferEasierWorkout {
            Button("I need an easier workout today") { Task { await model.run { try await model.start(easierToday: true) } } }.accessibilityIdentifier("workout.easier")
        }
        if model.canChangePreparation {
            Button("Movement setup") { showingSetup = true }.accessibilityIdentifier("movement.setup")
        }
        if model.blockedWorkingMovementIDs.contains(row.movementID) { Text("Additional working sets are unavailable: a saved program has a pause or stricter effort reserve for this movement. Changing programs does not clear safety.").accessibilityIdentifier("movement.retained-safety") }
        if model.snapshot.state.exercises[row.movementID]?.starterState?.doseStage == .introductory { Text("Starting with 2 sets").accessibilityIdentifier("movement.introductory") }
        else if model.snapshot.state.exercises[row.movementID]?.starterState?.doseStage == .established, row.phase == .baseline { Text("Ready for 3 sets; keep the same weight and establish your baseline.").accessibilityIdentifier("movement.established-baseline") }
        if row.phase == .baseline { Text("Baseline — this setup has its own starting point").accessibilityIdentifier("movement.baseline") }
        GuidedMovementCues(model: model, row: row)
        if let prior = summary.prior {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last time · \(prior.date.iso8601)").font(.headline)
                Text(MovementPrescriptionSummary.reps(prior.actualSets, repCounting: metadata.repCounting)).accessibilityIdentifier("movement.last-reps")
                if let load = prior.actualLoad { Text(MovementPrescriptionSummary.load(load)) }
                ForEach(prior.contextLabels, id: \.self) { Text($0).font(.caption) }
                if let skipped = prior.skippedSetIndices, !skipped.isEmpty { Text("Skipped sets: \(skipped.map { String($0 + 1) }.joined(separator: ", "))") }
            }
        }
        if row.kind == .paused { Text("Paused — no working sets. A new setup cannot clear the safety pause.").accessibilityIdentifier("movement.paused") }
        if row.kind == .setupReview {
            Text("Choose a manageable saved setup or create a new setup. Existing history and safety remain.")
            if model.canChangePreparation { Button("Review movement setup") { showingSetup = true }.accessibilityIdentifier("movement.review-setup") }
        }
        earlyActions(row)
    }
    private func preparationContext(for row: ExercisePrescription) -> String {
        "\(model.snapshot.draft?.displayed.id ?? ""):\(row.movementID)"
    }
    private func selectedPreparationWeight(for row: ExercisePrescription) -> Load? {
        let loads = model.movement(for: row).availableLoads
        let selected = preparationWeightContext == preparationContext(for: row)
            ? preparationWeight : model.log(for: row.movementID)?.actualLoad ?? row.load ?? loads.first
        return selected.flatMap { loads.contains($0) ? $0 : nil }
    }
    private func preparationWeightIsConfirmed(for row: ExercisePrescription) -> Bool {
        let log = model.log(for: row.movementID)
        if log?.actualSets.isEmpty == false { return log?.actualLoad != nil }
        guard let selected = selectedPreparationWeight(for: row), log?.actualLoad == selected else { return false }
        return preparationWeightContext != preparationContext(for: row) || !preparationWeightNeedsConfirmation
    }
    /// Picker indices retain the exact catalog Load without floating-point conversion.
    private func preparationWeightSelection(for row: ExercisePrescription) -> Binding<Int?> {
        Binding(get: {
            selectedPreparationWeight(for: row).flatMap { model.movement(for: row).availableLoads.firstIndex(of: $0) }
        }, set: { index in
            let loads = model.movement(for: row).availableLoads
            preparationWeight = index.flatMap { loads.indices.contains($0) ? loads[$0] : nil }
            preparationWeightContext = preparationContext(for: row)
            preparationWeightNeedsConfirmation = true
        })
    }
    private func confirmPreparationWeight(for row: ExercisePrescription) {
        guard let load = selectedPreparationWeight(for: row) else { return }
        let context = preparationContext(for: row)
        Task { await model.run {
            try await model.confirmLoad(movementID: row.movementID, load: load)
            guard preparationContext(for: row) == context, selectedPreparationWeight(for: row) == load else { return }
            preparationWeight = load; preparationWeightContext = context; preparationWeightNeedsConfirmation = false
        } }
    }
    @ViewBuilder private func earlyActions(_ row: ExercisePrescription) -> some View {
        if !model.handled(row.movementID) {
            Button("Keep as partial") { status(.partial, row: row) }.accessibilityIdentifier("movement.partial-action")
            if model.log(for: row.movementID)?.actualSets.isEmpty == true, pendingActual == nil { Button("Skip movement") { status(.skipped, row: row) }.accessibilityIdentifier("movement.skip") }
            Button("Stop movement") { status(.stopped, row: row) }.accessibilityIdentifier("movement.stop")
        }
    }
    private func status(_ status: LogStatus, row: ExercisePrescription) {
        dismissKeyboard()
        Task { await model.run { try await model.recordStatus(movementID: row.movementID, status: status, pendingActual: pendingActual); pendingActual = nil } }
    }
    private func problem(_ problem: Problem, row: ExercisePrescription) {
        dismissKeyboard()
        Task { await model.run {
            try await model.recordProblem(movementID: row.movementID, problem: problem, pendingActual: path.isEmpty ? pendingActual : nil)
            pendingActual = nil
            if !path.isEmpty { navigation.path.removeAll(); model.reviewStep = nil }
        } }
    }
    private func pushSummary(_ id: String) async throws {
        if path.isEmpty, forward == .summary(movementID: id) { return }
        dismissKeyboard(); try await navigation.push(.summary(id))
    }
    private func pushCorrection(_ id: String, index: Int) {
        dismissKeyboard()
        Task { await model.run {
            try await navigation.push(.correction(id, index))
        } }
    }
    private func requestReview() {
        if pendingActual != nil, path.isEmpty { reviewingPending = true }
        else if let id = rows.first?.movementID { Task { await model.run { try await pushSummary(id) } } }
    }
    private func back() {
        if !path.isEmpty {
            dismissKeyboard(); Task { await model.run { try await model.flushScratch(); navigation.path.removeLast() } }; return
        }
        let id: String?
        switch forward {
        case let .rest(source, _, _): id = source
        case let .set(value, _): id = value
        case let .summary(value):
            if let log = model.log(for: value), let last = log.actualSets.enumerated().map({ $0.element.setIndex ?? $0.offset }).max() {
                pushCorrection(value, index: last); return
            }
            let index = rows.firstIndex { $0.movementID == value } ?? 0
            id = index > 0 ? rows[index - 1].movementID : nil
        case let .introduction(value):
            let index = rows.firstIndex { $0.movementID == value } ?? 0
            id = index > 0 ? rows[index - 1].movementID : nil
        case .workoutReview: id = rows.last?.movementID
        case nil: id = nil
        }
        if pendingActual != nil { reviewingPending = true }
        else if let id { Task { await model.run { try await pushSummary(id) } } }
        else { Task { do { try await model.flushScratch(); if model.operations.contextEnabled { close() } } catch {} } }
    }
    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    @ViewBuilder private var saved: some View {
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
    }
}
