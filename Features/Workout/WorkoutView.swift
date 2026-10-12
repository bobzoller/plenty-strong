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
        // Earlier and legacy corrections adopt Summary before Save pops native Correction.
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
    let completed: (FinalizationReceipt) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var navigation: WorkoutReviewNavigation
    init(model: WorkoutViewModel, close: @escaping () -> Void) {
        self.model = model; self.close = close; self.completed = { _ in }
        _navigation = State(initialValue: WorkoutReviewNavigation(model: model))
    }
    init(model: WorkoutViewModel, close: @escaping () -> Void, navigation: WorkoutReviewNavigation, completed: @escaping (FinalizationReceipt) -> Void = { _ in }) {
        self.model = model; self.close = close; self.completed = completed
        _navigation = State(initialValue: navigation)
    }
    private var path: [WorkoutReviewRoute] { navigation.path }
    @State private var showingSetup = false
    @State private var discarding = false
    @State private var reviewingPending = false
    @State private var repairingCompletion = false
    @State private var pendingActual: ActualSet?
    @State private var reviewEfforts: [String: Effort] = [:]
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
                if model.finished { ProgressView("Opening Today…") }
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
                    if !model.finished, !frozen, forward != .workoutReview || model.snapshot.draft?.flow == nil {
                        Button("Back", systemImage: "chevron.left") { back() }.accessibilityIdentifier("guided.back").disabled(model.busy)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.finished, !frozen, forward != .workoutReview || model.snapshot.draft?.flow == nil {
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
                        GuidedWorkoutFooter(model: model) {
                        Button(row.sets.isEmpty ? (textSize.isAccessibilitySize ? "Review" : "Review outcome") : (textSize.isAccessibilitySize ? "Start" : "Start movement")) {
                            Task { await model.run { try await model.beginMovement(movementID: id) } }
                        }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityLabel(row.sets.isEmpty ? "Review outcome" : "Start movement").accessibilityIdentifier("guided.next")
                            .disabled(model.busy || model.snapshot.health != .ready || (!row.sets.isEmpty && model.requiresMigrationRecovery(id) && !model.migrationRecoveryConfirmed(id)) || (!row.sets.isEmpty && model.movement(for: row).loadingMode == .externalLoad && !preparationWeightIsConfirmed(for: row)))
                        } secondary: {
                            WorkoutSecondaryActions(model: model, step: .introduction(movementID: id), row: row, pendingActual: $pendingActual)
                        }
                    }
            }
        case let .set(id, _):
            if let row = rows.first(where: { $0.movementID == id }) {
                SetEntryView(model: model, row: row, pendingActual: $pendingActual)
            }
        case let .summary(id):
            if let row = rows.first(where: { $0.movementID == id }) { MovementSummaryView(model: model, row: row, reviewing: false, reviewCorrection: { index in pushCorrection(row.movementID, index: index) }) }
        case .rest:
            if let step {
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    GuidedRestView(model: model, step: step)
                }.padding() }
                .safeAreaInset(edge: .bottom) {
                    GuidedWorkoutFooter(model: model) {
                    Button("Next") { Task { await model.run { try await model.advanceRest() } } }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("guided.next").disabled(model.busy || model.snapshot.health != .ready)
                    } secondary: {
                        if let row = currentRow { WorkoutSecondaryActions(model: model, step: step, row: row, pendingActual: $pendingActual) }
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
            .safeAreaInset(edge: .bottom) {
                GuidedWorkoutFooter(model: model) {} secondary: {
                    if let row = currentRow, let step = model.visibleStep { WorkoutSecondaryActions(model: model, step: step, row: row, pendingActual: $pendingActual) }
                }
            }
    }
    private var workoutReview: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            WorkoutSessionModeLabel(model: model)
            Text(frozen ? "Finish pending — retry the exact saved workout" : "Workout review").font(.title2)
            ForEach(rows, id: \.movementID) { row in
                workoutCard(row)
                if row.movementID != rows.last?.movementID { Divider().padding(.vertical, 8) }
            }
            if !frozen, hasPendingReviews {
                Text("Confirm changes and choose effort for each pending movement before finishing.")
                    .font(.subheadline).accessibilityIdentifier("workout.review-required")
            }
        }.padding() }
        .safeAreaInset(edge: .bottom) {
            GuidedWorkoutFooter(model: model) {
            if model.canRecoverRejectedCompletion { Button(textSize.isAccessibilitySize ? "Repair" : "Repair unaccepted completion") { repairingCompletion = true }.accessibilityLabel("Repair unaccepted completion").accessibilityIdentifier("workout.repair-completion").disabled(model.busy) }
            Button(frozen ? "Retry Finish" : "Finish workout") { Task { await model.run {
                let receipt = try await model.finish()
                if model.acceptsCompletion(receipt) { completed(receipt) }
            } } }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("workout.finish").disabled(model.busy || model.snapshot.health != .ready || (!frozen && hasPendingReviews))
            }
        }
    }
    private var hasPendingReviews: Bool {
        guard let flow = model.snapshot.draft?.flow else { return false }
        return rows.contains { !flow.reviewedSummaryMovementIDs.contains($0.movementID) }
    }
    @ViewBuilder private func workoutCard(_ row: ExercisePrescription) -> some View {
        let id = row.movementID, metadata = model.movement(for: row), log = model.log(for: row.movementID)
        let prefix = "workout.card.\(id)."
        let pending = model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(id) == false
        VStack(alignment: .leading, spacing: 12) {
            Text(metadata.name ?? "Movement").font(.headline).accessibilityIdentifier(prefix + "name")
            WorkoutComparisonRows(row: row, log: log, repCounting: metadata.repCounting, loadingMode: metadata.loadingMode, identifierPrefix: prefix, editSet: frozen ? nil : { pushCorrection(id, index: $0) }, editingDisabled: model.busy || model.snapshot.health != .ready)
            Text("Outcome: \(log?.status.rawValue ?? "unrecorded")").accessibilityIdentifier(prefix + "outcome")
            if let problem = log?.problem, problem != .none { Text("Safety: \(problem.rawValue)").accessibilityIdentifier(prefix + "problem") }
            ForEach(Array((log?.actualSets ?? []).enumerated()), id: \.offset) { offset, actual in
                let index = actual.setIndex ?? offset
                if !row.sets.indices.contains(index) { Text("Retained extra observation \(index + 1): \(actual.reps) reps") }
                let corrections = WorkoutDetailView.corrections(audit: model.snapshot.draft?.observationAudit, movementID: id, setIndex: index)
                if !corrections.isEmpty {
                    DisclosureGroup {
                        ForEach(Array(corrections.enumerated()), id: \.element.operationID) { order, correction in
                            Text("Correction \(order + 1). \(WorkoutDetailView.correctionDetail(correction, repCounting: metadata.repCounting))")
                        }
                    } label: { Text("Set \(index + 1) corrections").accessibilityIdentifier(prefix + "corrections.\(index)") }
                }
            }
            if !frozen, pending {
                if log?.actualSets.isEmpty == false {
                    EffortPicker(model: model, movementID: id, selection: Binding(get: { reviewEfforts[id] }, set: { reviewEfforts[id] = $0 }), identifierPrefix: prefix)
                }
                Text("Confirmation required").font(.subheadline).accessibilityIdentifier(prefix + "pending")
                Button("Confirm changes") {
                    Task { await model.run { try await model.confirmWorkoutReviewSummary(movementID: id, effort: reviewEfforts[id]) } }
                }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier(prefix + "confirm")
                    .disabled(model.busy || (log?.actualSets.isEmpty == false && reviewEfforts[id] == nil))
            } else if log?.actualSets.isEmpty == false {
                Text("Effort: \(log?.finalEffort.title ?? "unrecorded")").accessibilityIdentifier(prefix + "effort-saved")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Only an existing review acknowledgement establishes an explicit
            // saved answer. A pending stored unknown is still ambiguous.
            if model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(id) == true, log?.actualSets.isEmpty == false { reviewEfforts[id] = log?.finalEffort }
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
        if model.requiresMigrationRecovery(row.movementID), !row.sets.isEmpty {
            Text("The source program requires recovery before another exposure. Review soreness, pain and control for this movement; import has not confirmed your recovery.")
                .accessibilityIdentifier("movement.source-recovery")
            Button(model.migrationRecoveryConfirmed(row.movementID) ? "Recovery reviewed for this session" : "I have recovered since the last exposure") {
                Task { await model.run { try await model.confirmMigrationRecovery(movementID: row.movementID) } }
            }.disabled(model.migrationRecoveryConfirmed(row.movementID) || model.busy || row.kind == .paused)
                .accessibilityIdentifier("movement.confirm-source-recovery")
            Text("If you have not recovered, skip or stop this movement. Existing safeguards remain.").font(.caption)
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
}
