import Foundation
import Observation
import TrainingCore

/// Value snapshots only: the repository remains the sole owner/writer of models.
@MainActor @Observable final class WorkoutViewModel {
    private(set) var snapshot: StoreSnapshot { didSet { scratchContextChanged() } }
    var errorText: String?
    private var runningUIAction = false
    let operations: TrainingOperationGate
    var busy: Bool { runningUIAction || operations.busy }
    var reviewStep: WorkoutStep? { didSet { scratchContextChanged() } }
    private var reconciledResumeStep: WorkoutStep? { didSet { scratchContextChanged() } }
    var visibleStep: WorkoutStep? { reviewStep ?? snapshot.draft?.flow?.forward ?? reconciledResumeStep }
    private(set) var finished = false
    private var submitted: (CompletedWorkout, WorkoutSlot, Int)?
    private var finishOperation: Task<FinalizationReceipt, any Error>?
    private var retainedOriginalDate = false
    private var rejectedRepair: (original: WorkoutDraft, repaired: WorkoutDraft)?
    let repository: TrainingRepository
    let timeZoneID: String
    let now: () -> Date
    private let activatesExactPolicy: Bool
    #if DEBUG
    var restoreBeforeAdoptionForTesting: (@MainActor () async throws -> Void)?
    #endif

    init(repository: TrainingRepository, snapshot: StoreSnapshot, timeZoneID: String, now: @escaping () -> Date = Date.init, operations: TrainingOperationGate? = nil, activatesExactPolicy: Bool = false, scratchStore: WorkoutScratchStore? = nil, scratchStoreID: String? = nil) {
        self.repository = repository; self.snapshot = snapshot; self.timeZoneID = timeZoneID; self.now = now
        self.operations = operations ?? TrainingOperationGate()
        self.activatesExactPolicy = activatesExactPolicy
        configureScratch(store: scratchStore, storeID: scratchStoreID)
        if let pending = snapshot.draft?.pendingFinish {
            submitted = (pending.event, pending.next, pending.expectedRevision)
        }
    }
    var entryDraft = SetEntryDraft() {
        didSet {
            guard !settingScratchEntry else { return }
            guard submitted == nil, snapshot.draft?.pendingFinish == nil, operations.contextEnabled else {
                settingScratchEntry = true; entryDraft = oldValue; settingScratchEntry = false
                return
            }
            scratchGeneration += 1
            queueScratchSave()
        }
    }
    private var scratchStore: WorkoutScratchStore?
    private var scratchStoreID: String?
    private var scratchDraftID: UUID?
    private var scratchContext: WorkoutScratchKey?
    private var scratchGeneration: UInt64 = 0
    private var scratchEpoch: UInt64 = 0
    private var settingScratchEntry = false
    private var scratchBase: Task<UInt64, any Error>?
    private var scratchWrite: Task<Void, any Error>?
    /// Transient UI ownership, including edits that intentionally return to blank.
    struct EntryOwnership: Equatable {
        fileprivate let epoch: UInt64
        fileprivate let generation: UInt64
        fileprivate let step: WorkoutStep?
        fileprivate let key: WorkoutScratchKey?
    }
    var entryOwnership: EntryOwnership {
        EntryOwnership(epoch: scratchEpoch, generation: scratchGeneration, step: visibleStep, key: currentScratchKey())
    }

    /// Configuration happens before a composition publishes a new model.
    func configureScratch(store: WorkoutScratchStore?, storeID: String?) {
        scratchStore = store; scratchStoreID = storeID
        scratchEpoch += 1; scratchGeneration = 0
        scratchDraftID = snapshot.draft?.id
        scratchContext = currentScratchKey()
        if let store, let id = snapshot.draft?.id {
            scratchBase = Task { try await store.generation(draftID: id) }
        } else { scratchBase = nil }
    }
    private func currentScratchKey() -> WorkoutScratchKey? {
        guard let storeID = scratchStoreID, scratchStore != nil,
              let draft = snapshot.draft, draft.pendingFinish == nil, submitted == nil,
              case let .set(id, index) = visibleStep,
              let row = draft.displayed.exercises.first(where: { $0.movementID == id }), row.sets.indices.contains(index),
              let log = draft.logs.first(where: { $0.movementID == id }),
              !(log.skippedSetIndices ?? []).contains(index) else { return nil }
        let actual = log.actualSets.enumerated().first { ($0.element.setIndex ?? $0.offset) == index }?.element
        guard reviewStep != nil || actual == nil else { return nil }
        let roots = snapshot.history.filter {
            guard $0.programID == draft.programID, $0.parentEnvelopeHash == nil, case .initialize = $0.command else { return false }
            return true
        }
        guard roots.count == 1 else { return nil }
        return WorkoutScratchKey(storeID: storeID, datasetID: roots[0].datasetID, programID: draft.programID,
            draftID: draft.id, prescriptionID: draft.displayed.id, step: .set(movementID: id, index: index),
            expectedObservationHash: actual.flatMap { try? BackupService.hash($0) },
            expectedOutcome: "\(log.status.rawValue):\(log.problem.rawValue):\(handled(id))")
    }
    private func scratchContextChanged() {
        guard scratchStore != nil else { return }
        // A frozen/ambiguous Finish locks edits, but a failed transaction must
        // retain the visible text until accepted Finish removes this draft.
        if snapshot.draft != nil, submitted != nil || snapshot.draft?.pendingFinish != nil { return }
        let next = currentScratchKey()
        guard next != scratchContext else { return }
        let old = scratchContext
        scratchEpoch += 1; scratchGeneration += 1
        if let store = scratchStore, let old {
            let base = scratchBase, generation = scratchGeneration
            let task = Task { try await store.invalidate(draftID: old.draftID, throughGeneration: try Self.scratchSequence(base: try await base?.value ?? 0, ordinal: generation), expectedKey: old) }
            scratchWrite = task
            surfaceScratchFailure(task, ownership: entryOwnership)
        }
        scratchContext = next
        if scratchDraftID != snapshot.draft?.id {
            scratchDraftID = snapshot.draft?.id; scratchGeneration = 0
            if let store = scratchStore, let draft = snapshot.draft {
                scratchBase = Task { try await store.generation(draftID: draft.id) }
            } else { scratchBase = nil }
        }
        settingScratchEntry = true; entryDraft = SetEntryDraft(); settingScratchEntry = false
    }
    private nonisolated static func scratchSequence(base: UInt64, ordinal: UInt64) throws -> UInt64 {
        let (value, overflow) = base.addingReportingOverflow(ordinal)
        guard !overflow else { throw EngineError(code: "scratch_generation_exhausted", field: "scratch") }
        return value
    }
    private func queueScratchSave() {
        guard scratchGeneration > 0, let store = scratchStore, let key = scratchContext, key == currentScratchKey() else { return }
        let entry = entryDraft, ordinal = scratchGeneration, base = scratchBase
        let task = Task { try await store.save(WorkoutScratch(generation: try Self.scratchSequence(base: try await base?.value ?? 0, ordinal: ordinal), key: key, entry: entry)) }
        scratchWrite = task
        surfaceScratchFailure(task, ownership: entryOwnership)
    }
    private func surfaceScratchFailure(_ task: Task<Void, any Error>, ownership: EntryOwnership) {
        Task { [weak self] in
            do { try await task.value }
            catch {
                guard let self, self.operations.contextEnabled, self.entryOwnership == ownership else { return }
                self.errorText = "Workout input could not be saved locally. Your entered text is retained. \(error)"
            }
        }
    }
    func flushScratch() async throws {
        let ownership = entryOwnership
        queueScratchSave()
        do { try await scratchWrite?.value }
        catch {
            if operations.contextEnabled, entryOwnership == ownership, !Task.isCancelled {
                errorText = "Workout input could not be saved locally. Your entered text is retained. \(error)"
            }
            throw error
        }
    }
    func suspendScratch() { scratchEpoch += 1 }
    @discardableResult func restoreScratch() async throws -> Bool {
        guard let store = scratchStore, let key = currentScratchKey() else { return false }
        let epoch = scratchEpoch, ordinal = scratchGeneration
        let restored = try await store.load(key: key)
        guard !Task.isCancelled, operations.contextEnabled, epoch == scratchEpoch, ordinal == scratchGeneration, currentScratchKey() == key, let restored else { return false }
        // The persisted watermark was captured before any new text writes.
        _ = try await scratchBase?.value
        guard !Task.isCancelled, operations.contextEnabled, epoch == scratchEpoch, ordinal == scratchGeneration, currentScratchKey() == key else { return false }
        settingScratchEntry = true; entryDraft = restored.entry; settingScratchEntry = false
        return true
    }
    /// Opens recorded correction input; called by the correction screen's task.
    func openCorrectionEntry(movementID: String, index: Int) async -> Bool {
        guard !Task.isCancelled, operations.contextEnabled, reviewStep == .set(movementID: movementID, index: index),
              let actual = log(for: movementID)?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element else { return false }
        let ownership = entryOwnership
        var restored = false
        do { restored = try await restoreScratch() }
        catch {
            guard !Task.isCancelled, operations.contextEnabled, entryOwnership == ownership else { return false }
            errorText = "Correction input could not be opened. Saved observations are retained. \(error)"
        }
        guard !Task.isCancelled, operations.contextEnabled, entryOwnership == ownership,
              log(for: movementID)?.actualSets.enumerated().first(where: { ($0.element.setIndex ?? $0.offset) == index })?.element == actual else { return false }
        if !restored, entryDraft == SetEntryDraft() {
            entryDraft = SetEntryDraft(reps: String(actual.reps), left: actual.leftReps.map(String.init) ?? "", right: actual.rightReps.map(String.init) ?? "", reason: actual.missedGoalReason)
        }
        return true
    }
    private func removeScratch(draftID: UUID) async {
        guard let store = scratchStore else { return }
        do {
            try await store.remove(draftID: draftID)
            settingScratchEntry = true; entryDraft = SetEntryDraft(); settingScratchEntry = false
        }
        catch { errorText = "Finished workout input could not be removed locally. \(error)" }
    }
    var hasAmbiguousFinish: Bool { submitted != nil && !finished }
    /// Read-only identity projection of this model's accepted frozen Finish.
    /// Later Settings changes may replace snapshot.state but not this payload.
    var completedEnvelope: JournalEnvelope? {
        guard finished, let (event, next, _) = submitted else { return nil }
        let matches = snapshot.history.filter { envelope in
            guard envelope.programID == snapshot.state.config.programID,
                  envelope.eventID == event.eventID,
                  case let .workout(recorded, savedNext) = envelope.command else { return false }
            return recorded == event && savedNext == next
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func adoptRecoverySnapshot(_ value: StoreSnapshot, operation: TrainingOperationGate.Lease) throws {
        try operations.requireOwnership(operation)
        guard value.state.config.programID == snapshot.state.config.programID, value.draft == snapshot.draft else { throw EngineError(code: "recovery_draft_binding", field: "draft") }
        snapshot = value
    }
    var programID: UUID { UUID(uuidString: snapshot.state.config.programID)! }
    var canDiscardDraft: Bool { submitted == nil && snapshot.draft?.logs.contains { $0.problem != .none } != true }
    var canChangePreparation: Bool { (submitted == nil || finished) && !(snapshot.draft?.hasObservations ?? false) }
    var canOfferEasierWorkout: Bool {
        canChangePreparation && snapshot.history.contains { envelope in
            guard envelope.programID == snapshot.state.config.programID,
                  case let .workout(event, _) = envelope.command else { return false }
            return event.exercises.contains { !$0.actualSets.isEmpty }
        }
    }
    var needsDateChoice: Bool {
        guard let draft = snapshot.draft, draft.pendingFinish == nil, submitted == nil, !retainedOriginalDate,
              let today = try? CalendarContext(timeZoneID: draft.timeZoneID).localDate(at: now()) else { return false }
        return today != draft.date
    }
    func movement(for row: ExercisePrescription) -> Movement {
        if let movement = MovementPrescriptionSummary.effectiveMovement(state: snapshot.state, variantID: row.movementID) { return movement }
        // Unsupported roots never enter training, but rendering remains defensive.
        return Movement(id: row.baseMovementID ?? row.movementID, name: row.baseMovementID ?? row.movementID,
            primaryMuscles: [], secondaryMuscles: [], minimumRir: 2, availableLoads: [])
    }
    private func admittedMovement(for row: ExercisePrescription) async throws -> Movement {
        let state = snapshot.state
        guard let movement = await Task.detached(priority: .userInitiated, operation: {
            MovementPrescriptionSummary.effectiveMovement(state: state, variantID: row.movementID)
        }).value else {
            throw EngineError(code: "invalid_variant", field: "movementID")
        }
        return movement
    }
    private(set) var blockedWorkingMovementIDs: Set<String> = []
    func refreshWorkingAdmission(operation: TrainingOperationGate.Lease) async throws {
        try operations.requireOwnership(operation)
        try await refreshWorkingAdmissionBody()
    }
    private func refreshWorkingAdmissionBody() async throws {
        let value = snapshot
        let admission = try await repository.workingAdmission(for: value.state)
        blockedWorkingMovementIDs = try await Task.detached(priority: .userInitiated) {
            try Self.workingRestrictions(snapshot: value, roots: admission.roots, rules: admission.rules)
        }.value
    }
    private nonisolated static func workingRestrictions(snapshot: StoreSnapshot, roots: [StoreSnapshot], rules: Ruleset) throws -> Set<String> {
        let rows = snapshot.draft?.displayed.exercises ?? snapshot.state.activePrescription.exercises
        var restrictions: [String: MovementSafetyState] = [:]
        for current in roots {
            // Only verified current ready projections contribute safety. Cleared
            // ancestors and unrelated corrupt roots never become inferred pauses.
            guard current.health == .ready else { continue }
            for movement in current.state.config.movements {
                let base = movement.id, safety = current.state.baseSafety?[movement.id]
                let paused = safety?.paused == true || current.state.exercises.contains { key, value in
                    (current.state.config.variants?[key]?.baseMovementID ?? key) == base && value.mode == .paused
                } || current.draft?.logs.contains { ($0.baseMovementID ?? $0.movementID) == base && $0.problem != .none } == true
                let old = restrictions[base]
                restrictions[base] = MovementSafetyState(paused: paused || old?.paused == true,
                    minimumRir: max(movement.minimumRir, max(safety?.minimumRir ?? 0, old?.minimumRir ?? 0)), sourceEventIDs: [])
            }
        }
        guard let parameters = rules.parameters else { throw EngineError(code: "missing_parameters", field: "rules") }
        return Set(rows.compactMap { row in
            let base = row.baseMovementID ?? row.movementID
            let localFloor = max(MovementPrescriptionSummary.effectiveMovement(state: snapshot.state, variantID: row.movementID)?.minimumRir ?? 2, max(snapshot.state.baseSafety?[base]?.minimumRir ?? 0,
                snapshot.draft?.sessionMode == .easier ? parameters.easierMinimumRir : parameters.normalMinimumRir))
            guard let restriction = restrictions[base], restriction.paused || restriction.minimumRir > localFloor else { return nil }
            return row.movementID
        })
    }
    private func requireWorkingExposure(_ row: ExercisePrescription) async throws {
        try await refreshWorkingAdmissionBody()
        guard !blockedWorkingMovementIDs.contains(row.movementID) else { throw EngineError(code: "retained_safety_restriction", field: row.baseMovementID ?? row.movementID) }
    }
    func log(for id: String) -> ExerciseLog? { snapshot.draft?.logs.first { $0.movementID == id } }
    func handled(_ id: String) -> Bool { snapshot.draft?.acknowledgedMovementIDs?.contains(id) == true }
    func run(_ action: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        runningUIAction = true; errorText = nil
        defer { runningUIAction = false }
        do { try await action() }
        catch let error as EngineError { errorText = message(for: error) }
        catch { errorText = "Could not save on this device. Your last saved observations are retained. \(error.localizedDescription)" }
    }
    private func message(for error: EngineError) -> String {
        if error.code == "incomplete_workout", error.field == "review" {
            return "Confirm the pending movement summaries in Workout review before finishing."
        }
        return switch error.code {
        case "retained_safety_restriction": "A saved program has a pause or stricter effort reserve for this movement. Additional working sets are unavailable. Keep recorded actuals and choose partial or stopped, then finish safely. Changing programs does not clear safety."
        case "unsupported_training": "This archived program is available for viewing and export. Training is unavailable in the fixed routine."
        case "incomplete_workout": "Choose performed, partial, skipped, or stopped for every movement before finishing."
        case "incomplete_sets": "Completed requires every set and equal positive reps on both sides. Keep unfinished work as partial."
        case "handling_load_mismatch": "This load has not been reviewed for 4–6 reps. Before working sets, use Movement setup to choose standard 8–12 reps or review the saved load. Recorded observations cannot be replaced."
        case "load_confirmation_required": "Choose and confirm the actual load from your dumbbell catalog."
        case "load_correction_required": "Saved sets retain their original load. Use Correct load to keep observations and stop this movement."
        case "problem_requires_finalization": "Keep the original date and observations, handle the remaining movements, and finish so the safety stop is retained."
        case "date_choice_required": "Choose whether to keep the original workout date or discard and restart."
        case "session_already_recorded": "A workout has already been recorded for this local date. Your next workout remains available on a later date."
        case "future_workout": "This workout is scheduled for a future day."
        case "movement_stopped", "working_draft_locked": "This movement is stopped, or working observations have locked preparation. Saved observations are retained."
        default: "Could not save (\(error.code)). Your last saved observations are retained."
        }
    }
    private func requireReady() async throws {
        let value = snapshot
        guard await Task.detached(priority: .userInitiated, operation: { AppTrainingCompatibility.supports(value) }).value else { throw EngineError(code: "unsupported_training", field: "program") }
        guard snapshot.health == .ready else { throw EngineError(code: "store_\(snapshot.health.rawValue)", field: "health") }
    }
    private func editableDraft(allowDateChoice: Bool = false) async throws -> WorkoutDraft {
        try await requireReady()
        guard submitted == nil, let draft = snapshot.draft, draft.pendingFinish == nil else { throw EngineError(code: "draft_unavailable", field: "draft") }
        guard allowDateChoice || !needsDateChoice else { throw EngineError(code: "date_choice_required", field: "date") }
        return draft
    }
    private func save(_ draft: WorkoutDraft, expectedExistingDraft: WorkoutDraft? = nil, authoritativeOutcome: Bool = false) async throws {
        // A guided save binds the forward cursor/deadline to the captured draft,
        // including when another model has already committed this set.
        let expected = expectedExistingDraft ?? (draft.flow != nil ? snapshot.draft : nil)
        let ownership = entryOwnership
        var scratchFailure: (any Error)?
        if scratchContext != nil {
            do { try await flushScratch() }
            catch {
                guard authoritativeOutcome else { throw error }
                guard !Task.isCancelled, operations.contextEnabled, entryOwnership == ownership else {
                    throw EngineError(code: "inactive_context", field: "scratch")
                }
                scratchFailure = error
            }
        }
        // Sidecar tolerance never bypasses repository admission, prefixes or CAS.
        snapshot = try await repository.saveDraft(draft, expectedExistingDraft: expected)
        if let scratchFailure {
            scratchEpoch += 1
            var cleanupFailure = ""
            let base = (try? await scratchBase?.value) ?? 0
            let watermark = (try? Self.scratchSequence(base: base, ordinal: scratchGeneration)) ?? UInt64.max
            do {
                if let key = ownership.key { _ = try await scratchStore?.retire(key: key, throughGeneration: watermark) }
            } catch { cleanupFailure = " Local cleanup also failed; unsaved input cannot be restored until local storage is available: \(error)" }
            scratchBase = Task { watermark }; scratchGeneration = 0; scratchWrite = nil
            errorText = "Your outcome and observations are saved. Workout input from that page could not be saved locally and will not be restored. \(scratchFailure)\(cleanupFailure)"
        }
    }
    /// Missed scheduling and interrupted-return preparation are explicit journal commands.
    func prepareToday() async throws {
        try await operations.perform { _ in try await prepareTodayBody() }
    }
    func prepareToday(operation: TrainingOperationGate.Lease) async throws {
        try operations.requireOwnership(operation)
        try await prepareTodayBody()
    }
    private func prepareTodayBody(asOf: LocalDate? = nil) async throws {
        try await requireReady()
        guard !hasAmbiguousFinish, snapshot.draft?.pendingFinish == nil else { throw EngineError(code: "finish_in_flight", field: "draft") }
        guard snapshot.draft == nil else { return }
        let today = try asOf ?? CalendarContext(timeZoneID: timeZoneID).localDate(at: now())
        // Suggested dates never consume or replace a pending rotation slot.
        snapshot = try await repository.prepareReturn(programID: programID, expectedRevision: snapshot.state.revision, asOf: today)
    }
    func start(easierToday: Bool) async throws {
        try await operations.perform { _ in try await startBody(easierToday: easierToday) }
    }
    func start(easierToday: Bool, operation: TrainingOperationGate.Lease) async throws {
        try operations.requireOwnership(operation)
        try await startBody(easierToday: easierToday)
    }
    private func startBody(easierToday: Bool, retainingLegacyDraftPolicy: Bool = false) async throws {
        try await requireReady()
        guard !hasAmbiguousFinish, snapshot.draft?.pendingFinish == nil else { throw EngineError(code: "finish_in_flight", field: "draft") }
        let startedWithLegacyDraft = retainingLegacyDraftPolicy || (snapshot.draft != nil && snapshot.draft?.startedAtMilliseconds == nil)
        if let existing = snapshot.draft {
            if (existing.sessionMode == .easier) == easierToday { try await refreshWorkingAdmissionBody(); return }
            guard canChangePreparation else { throw EngineError(code: "working_draft_locked", field: "draft") }
            guard !needsDateChoice else { throw EngineError(code: "date_choice_required", field: "date") }
            try await repository.discardDraft(id: existing.id)
            await removeScratch(draftID: existing.id)
            snapshot = try await repository.snapshot(programID: programID)
        }
        guard !hasAmbiguousFinish, finishOperation == nil else { throw EngineError(code: "finish_in_flight", field: "policy") }
        if !startedWithLegacyDraft, snapshot.state.schedulingPolicy == nil {
            snapshot = try await repository.activateFlexibleSchedule(programID: programID, expectedRevision: snapshot.state.revision)
        }
        if activatesExactPolicy, !startedWithLegacyDraft, snapshot.state.schemaVersion == 2 {
            snapshot = try await repository.snapshot(programID: programID)
            guard snapshot.draft == nil else { throw EngineError(code: "policy_activation_draft_locked", field: "draft") }
            let document = try await repository.exportBackup()
            guard let head = document.heads[snapshot.state.config.programID] else { throw BackupService.invalid("activation_head") }
            snapshot = try await repository.activateExactPolicy(programID: programID,
                expectedRevision: snapshot.state.revision, expectedHeadHash: head)
        }
        let start = try SessionTiming.milliseconds(at: now())
        let today = try SessionTiming.localDate(milliseconds: start, timeZoneID: timeZoneID)
        try await prepareTodayBody(asOf: today)
        let flexible = snapshot.state.schedulingPolicy == .flexibleV1
        guard flexible || snapshot.state.activePrescription.date <= today else { throw EngineError(code: "future_workout", field: "date") }
        guard snapshot.state.lastSessionDate == nil || today > snapshot.state.lastSessionDate! else { throw EngineError(code: "session_already_recorded", field: "date") }
        let state = snapshot.state
        let displayed = try await Task.detached(priority: .userInitiated) {
            try prepareWorkout(state: state, rules: RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash), easierToday: easierToday)
        }.value
        let logs = displayed.exercises.map {
            ExerciseLog(movementID: $0.movementID, prescriptionID: displayed.id, status: .partial, actualLoad: nil,
                actualSets: [], finalEffort: .unknown, problem: .none, baseMovementID: $0.baseMovementID, modificationsSnapshot: $0.modificationsSnapshot,
                effortScope: [3, 4].contains(snapshot.state.schemaVersion) ? .allWorkingSets : nil,
                skippedSetIndices: [3, 4].contains(snapshot.state.schemaVersion) ? [] : nil,
                mixedLoads: [3, 4].contains(snapshot.state.schemaVersion) ? false : nil)
        }
        try await save(WorkoutDraft(id: UUID(), programID: snapshot.state.config.programID, expectedRevision: snapshot.state.revision,
            planned: snapshot.state.activePrescription, displayed: displayed, date: flexible ? today : displayed.date, timeZoneID: timeZoneID,
            sessionMode: easierToday ? .easier : .normal, logs: logs, workingSetsStarted: false, acknowledgedMovementIDs: [],
            flow: displayed.exercises.first.map { WorkoutFlow(forward: .introduction(movementID: $0.movementID), reviewedSummaryMovementIDs: []) },
            startedAtMilliseconds: flexible ? start : nil))
        reviewStep = nil; reconciledResumeStep = nil
        submitted = nil; finished = false
        try await refreshWorkingAdmissionBody()
    }
    func resolveDateChange(keepOriginal: Bool) async throws {
        try await operations.perform { _ in try await resolveDateChangeBody(keepOriginal: keepOriginal) }
    }
    private func resolveDateChangeBody(keepOriginal: Bool) async throws {
        guard let draft = snapshot.draft else { return }
        if keepOriginal { retainedOriginalDate = true; return }
        guard canDiscardDraft else { throw EngineError(code: "problem_requires_finalization", field: "draft") }
        try await repository.discardDraft(id: draft.id)
        await removeScratch(draftID: draft.id)
        snapshot = try await repository.snapshot(programID: programID)
        retainedOriginalDate = false; reviewStep = nil; reconciledResumeStep = nil
        try await prepareTodayBody()
    }
    /// Resume never goes through Start, preparation, working exposure or policy activation.
    func resumeGuidedWorkout() async throws {
        try await operations.perform { _ in
            guard let original = snapshot.draft else { throw EngineError(code: "draft_unavailable", field: "draft") }
            if let pending = original.pendingFinish {
                submitted = (pending.event, pending.next, pending.expectedRevision)
                reviewStep = nil
                return
            }
            if submitted != nil { reviewStep = nil; return }
            let flow = try await Task.detached(priority: .userInitiated) { try WorkoutFlowResolver.reconciled(original) }.value
            if original.flow == nil {
                // Presentation must not force date/safety admission or rewrite a parked stop.
                if needsDateChoice || original.logs.contains(where: { $0.problem != .none || $0.status == .stopped }) || original.displayed.exercises.contains(where: { $0.kind == .paused }) {
                    reconciledResumeStep = flow.forward
                } else {
                    _ = try await editableDraft()
                    var draft = original; draft.flow = flow
                    try await save(draft, expectedExistingDraft: original)
                }
            }
            reviewStep = nil
            do { try await restoreScratch() }
            catch { errorText = "Saved workout input could not be opened. The workout is retained. \(error)" }
        }
    }
    func beginMovement(movementID: String) async throws {
        try await operations.perform { _ in
            let original = try await editableDraft()
            var draft = original
            try await reconcileActionFlow(&draft)
            guard reviewStep == nil, draft.flow?.forward == .introduction(movementID: movementID) else { throw EngineError(code: "invalid_workout_step", field: "flow") }
            let i = try index(movementID, draft: draft), row = draft.displayed.exercises[i]
            guard !handled(movementID), draft.logs[i].problem == .none else { throw EngineError(code: "movement_stopped", field: "movementID") }
            if row.sets.isEmpty || row.kind == .paused || row.kind == .setupReview {
                draft.flow?.forward = .summary(movementID: movementID)
            } else {
                try await requireWorkingExposure(row)
                let movement = try await admittedMovement(for: row)
                guard movement.loadingMode != .externalLoad || draft.logs[i].actualLoad != nil else { throw EngineError(code: "load_confirmation_required", field: "load") }
                try requireReviewedHandling(movementID: movementID, load: draft.logs[i].actualLoad)
                guard let slot = nextSetIndex(log: draft.logs[i], row: row) else { throw EngineError(code: "invalid_workout_step", field: "flow") }
                draft.flow?.forward = .set(movementID: movementID, index: slot)
            }
            try await save(draft, expectedExistingDraft: original)
        }
    }
    func advanceRest() async throws {
        try await operations.perform { _ in
            let original = try await editableDraft()
            guard reviewStep == nil, case let .rest(_, _, destination) = original.flow?.forward else { throw EngineError(code: "invalid_workout_step", field: "flow") }
            var draft = original
            switch destination {
            case let .set(id, index): draft.flow?.forward = .set(movementID: id, index: index)
            case let .introduction(id): draft.flow?.forward = .introduction(movementID: id)
            }
            try await save(draft, expectedExistingDraft: original)
        }
    }
    func correctSet(movementID: String, index: Int, replacement: ActualSet, operationID: UUID) async throws {
        try await operations.perform { _ in
            let draft = try await editableDraft()
            let hash = try await Task.detached(priority: .userInitiated) { try BackupService.hash(draft) }.value
            try await flushScratch()
            snapshot = try await repository.correctDraftSet(programID: programID, expectedDraftHash: hash,
                operationID: operationID, movementID: movementID, setIndex: index, replacement: replacement)
            reviewStep = snapshot.draft?.flow?.forward == .workoutReview ? nil : .summary(movementID: movementID)
        }
    }
    /// Final review confirms only an already acknowledged outcome. It never
    /// changes disposition, rewinds the cursor, or qualifies a demoted completion.
    func confirmWorkoutReviewSummary(movementID: String, effort: Effort?) async throws {
        try await operations.perform { _ in
            let original = try await editableDraft()
            guard reviewStep == nil, original.flow?.forward == .workoutReview,
                  (original.acknowledgedMovementIDs ?? []).contains(movementID) else {
                throw EngineError(code: "invalid_workout_step", field: "review")
            }
            let i = try index(movementID, draft: original), log = original.logs[i]
            try await validateSummary(movementID: movementID, effort: effort, status: log.status, draft: original, requiresExplicitEffort: true)
            var draft = original
            if let effort { draft.logs[i].finalEffort = effort }
            if draft.flow?.reviewedSummaryMovementIDs.contains(movementID) != true {
                draft.flow?.reviewedSummaryMovementIDs.append(movementID)
            }
            if draft != original { try await save(draft, expectedExistingDraft: original) }
        }
    }
    func confirmMovementSummary(movementID: String, effort: Effort?, status: LogStatus, reviewing: Bool) async throws {
        try await operations.perform { _ in
            let original = try await editableDraft()
            var draft = original
            try await reconcileActionFlow(&draft)
            let i = try index(movementID, draft: draft)
            let log = draft.logs[i]
            if draft.flow?.reviewedSummaryMovementIDs.contains(movementID) == true,
               log.status == status, effort == nil || effort == log.finalEffort {
                reviewStep = nil
                return
            }
            guard reviewing ? reviewStep == .summary(movementID: movementID) :
                (reviewStep == nil && draft.flow?.forward == .summary(movementID: movementID)) else { throw EngineError(code: "invalid_workout_step", field: "summary") }
            try await validateSummary(movementID: movementID, effort: effort, status: status, draft: draft)
            if reviewing, !handled(movementID), log.status == .partial, log.problem == .none,
               !WorkoutFlowResolver.hasDemotedCompletion(log, draft: draft) {
                guard status == log.status else { throw EngineError(code: "movement_stopped", field: "status") }
                // Backward review of unfinished work confirms effort only. Its
                // explicit outcome and final Summary remain ahead of the cursor.
                var reviewed = original
                if let effort { reviewed.logs[i].finalEffort = effort }
                try await save(reviewed, expectedExistingDraft: original)
                reviewStep = nil
                return
            }
            if let effort { draft.logs[i].finalEffort = effort }
            draft.logs[i].status = status
            acknowledge(movementID, draft: &draft)
            if draft.flow?.reviewedSummaryMovementIDs.contains(movementID) != true { draft.flow?.reviewedSummaryMovementIDs.append(movementID) }
            if !reviewing {
                let projection = draft
                let next = try await Task.detached(priority: .userInitiated) { try WorkoutFlowResolver.afterSummary(projection, sourceIndex: i) }.value
                draft.flow?.forward = next
            }
            try await save(draft, expectedExistingDraft: original)
            reviewStep = nil
        }
    }
    /// Terminates only the admitted forward summary. Outcomes and review cursor
    /// commit together; event finalization and rotation still belong to Finish.
    func stopWorkout(movementID: String, effort: Effort?, status: LogStatus) async throws {
        try await operations.perform { _ in
            let original = try await editableDraft()
            var draft = original
            try await reconcileActionFlow(&draft)
            guard reviewStep == nil, draft.flow?.forward == .summary(movementID: movementID) else {
                throw EngineError(code: "invalid_workout_step", field: "summary")
            }
            let i = try index(movementID, draft: draft)
            try await validateSummary(movementID: movementID, effort: effort, status: status, draft: draft, requiresExplicitEffort: true)
            if let effort { draft.logs[i].finalEffort = effort }
            draft.logs[i].status = status
            acknowledge(movementID, draft: &draft)
            if draft.flow?.reviewedSummaryMovementIDs.contains(movementID) != true { draft.flow?.reviewedSummaryMovementIDs.append(movementID) }
            for other in draft.logs.indices where other != i {
                let log = draft.logs[other], id = log.movementID
                guard !(draft.acknowledgedMovementIDs ?? []).contains(id) else { continue }
                if log.status == .partial, log.problem == .none, !WorkoutFlowResolver.hasDemotedCompletion(log, draft: draft) {
                    draft.logs[other].status = log.actualSets.isEmpty ? .skipped : .partial
                    // Stop is the explicit disposition for empty remaining work.
                    // Performed work keeps its independent pending effort/review.
                    if log.actualSets.isEmpty, draft.flow?.reviewedSummaryMovementIDs.contains(id) != true {
                        draft.flow?.reviewedSummaryMovementIDs.append(id)
                    }
                }
                acknowledge(id, draft: &draft)
            }
            draft.flow?.forward = .workoutReview
            try await save(draft, expectedExistingDraft: original, authoritativeOutcome: true)
        }
    }

    private func validateSummary(movementID: String, effort: Effort?, status: LogStatus, draft: WorkoutDraft, requiresExplicitEffort: Bool = false) async throws {
        let i = try index(movementID, draft: draft), row = draft.displayed.exercises[i], log = draft.logs[i]
        guard !(draft.acknowledgedMovementIDs ?? []).contains(movementID) || status == log.status,
              log.status != .stopped || status == .stopped, log.problem == .none || status == .stopped,
              !WorkoutFlowResolver.hasDemotedCompletion(log, draft: draft) || status == .partial else { throw EngineError(code: "movement_stopped", field: "status") }
        if status == .completed, !(await validCompletion(log, row: row)) { throw EngineError(code: "incomplete_sets", field: "status") }
        guard status != .skipped || log.actualSets.isEmpty else { throw EngineError(code: "partial_required", field: "status") }
        if !log.actualSets.isEmpty, effort == nil,
           requiresExplicitEffort || ([3, 4].contains(snapshot.state.schemaVersion) && log.effortScope == .allWorkingSets) {
            throw EngineError(code: "effort_required", field: "finalEffort")
        }
    }

    /// Reconciliation is authorized by the explicit action, never by parked Resume.
    private func reconcileActionFlow(_ draft: inout WorkoutDraft) async throws {
        guard draft.flow == nil else { return }
        let original = draft
        draft.flow = try await Task.detached(priority: .userInitiated) { try WorkoutFlowResolver.reconciled(original) }.value
    }
    /// Set/outcome and resulting forward cursor are written in the same save.
    private func routeOccupiedSet(_ draft: inout WorkoutDraft, at i: Int, performedIndex: Int?) {
        guard draft.flow != nil else { return }
        let row = draft.displayed.exercises[i]
        guard draft.displayed.exercises.first(where: { !(draft.acknowledgedMovementIDs ?? []).contains($0.movementID) })?.movementID == row.movementID else { return }
        if let next = nextSetIndex(log: draft.logs[i], row: row) {
            if let performedIndex {
                draft.flow?.forward = .rest(sourceMovementID: row.movementID, sourceSetIndex: performedIndex, destination: .set(movementID: row.movementID, index: next))
            } else { draft.flow?.forward = .set(movementID: row.movementID, index: next) }
        } else { draft.flow?.forward = .summary(movementID: row.movementID) }
    }
    private func routeSummary(_ id: String, draft: inout WorkoutDraft) {
        draft.flow?.forward = .summary(movementID: id)
        draft.flow?.reviewedSummaryMovementIDs.removeAll { $0 == id }
    }
    private func index(_ id: String, draft: WorkoutDraft) throws -> Int {
        guard let index = draft.logs.firstIndex(where: { $0.movementID == id }) else { throw EngineError(code: "unknown_movement", field: "movementID") }
        return index
    }
    func confirmLoad(movementID: String, load: Load) async throws {
        try await operations.perform { _ in try await confirmLoadBody(movementID: movementID, load: load) }
    }
    private func confirmLoadBody(movementID: String, load: Load) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        let row = draft.displayed.exercises[i]
        let movement = try await admittedMovement(for: row)
        guard movement.loadingMode == .externalLoad, movement.availableLoads.contains(load) else { throw EngineError(code: "invalid_load", field: "load") }
        guard draft.logs[i].actualSets.isEmpty else {
            if draft.logs[i].actualLoad == load { return }
            throw EngineError(code: "load_correction_required", field: "load")
        }
        guard !handled(movementID), draft.logs[i].problem == .none, row.kind != .paused else { throw EngineError(code: "movement_stopped", field: "load") }
        try requireReviewedHandling(movementID: movementID, load: load)
        draft.logs[i].actualLoad = load
        try await save(draft)
    }
    private func requireReviewedHandling(movementID: String, load: Load?) throws {
        if case let .lowRep(reviewed) = snapshot.state.exercises[movementID]?.starterState?.strengthHandling,
           reviewed != load {
            throw EngineError(code: "handling_load_mismatch", field: "load")
        }
    }
    /// Skips occupy intended slots without fabricating a performed observation.
    func nextSetIndex(for movementID: String) -> Int? {
        guard let draft = snapshot.draft, let i = draft.logs.firstIndex(where: { $0.movementID == movementID }),
              !handled(movementID), draft.logs[i].problem == .none,
              draft.displayed.exercises[i].kind != .paused else { return nil }
        return nextSetIndex(log: draft.logs[i], row: draft.displayed.exercises[i])
    }
    private func nextSetIndex(log: ExerciseLog, row: ExercisePrescription) -> Int? {
        if ![3, 4].contains(snapshot.state.schemaVersion) { return log.actualSets.count < row.sets.count ? log.actualSets.count : nil }
        let occupied = Set(log.actualSets.compactMap(\.setIndex)).union(log.skippedSetIndices ?? [])
        return row.sets.indices.first { !occupied.contains($0) }
    }
    func skipSet(movementID: String, index setIndex: Int) async throws {
        try await operations.perform { _ in try await skipSetBody(movementID: movementID, index: setIndex) }
    }
    private func skipSetBody(movementID: String, index setIndex: Int) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        let row = draft.displayed.exercises[i]
        guard [3, 4].contains(snapshot.state.schemaVersion), row.sets.indices.contains(setIndex) else { throw EngineError(code: "invalid_set", field: "setIndex") }
        if draft.logs[i].skippedSetIndices?.contains(setIndex) == true { return }
        guard !handled(movementID), draft.logs[i].problem == .none, row.kind != .paused else { throw EngineError(code: "movement_stopped", field: "set") }
        guard reviewStep == nil, nextSetIndex(log: draft.logs[i], row: row) == setIndex else { throw EngineError(code: "invalid_set", field: "setIndex") }
        if reconciledResumeStep != nil { try await reconcileActionFlow(&draft) }
        draft.logs[i].skippedSetIndices!.append(setIndex)
        // The movement remains editable until its explicit outcome is chosen.
        routeOccupiedSet(&draft, at: i, performedIndex: nil)
        try await save(draft)
    }
    func recordMixedLoads(movementID: String) async throws {
        try await operations.perform { _ in try await recordMixedLoadsBody(movementID: movementID) }
    }
    private func recordMixedLoadsBody(movementID: String) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        guard [3, 4].contains(snapshot.state.schemaVersion) else { throw EngineError(code: "unsupported_policy", field: "mixedLoads") }
        if draft.logs[i].mixedLoads == true { return }
        guard !handled(movementID), draft.logs[i].problem == .none, draft.displayed.exercises[i].kind != .paused else { throw EngineError(code: "movement_stopped", field: "load") }
        draft.logs[i].mixedLoads = true
        draft.logs[i].status = .partial
        acknowledge(movementID, draft: &draft)
        routeSummary(movementID, draft: &draft)
        try await save(draft)
    }
    private func requireMissReason(_ actual: ActualSet, row: ExercisePrescription, index: Int) throws {
        guard [3, 4].contains(snapshot.state.schemaVersion) else { return }
        if let target = row.sets[index].targetReps, [actual.reps, actual.leftReps, actual.rightReps].compactMap({ $0 }).contains(where: { $0 < target }), actual.missedGoalReason == nil {
            throw EngineError(code: "missed_goal_reason_required", field: "missedGoalReason")
        }
    }
    func recordSet(movementID: String, index setIndex: Int, actual: ActualSet) async throws {
        try await operations.perform { _ in try await recordSetBody(movementID: movementID, index: setIndex, actual: actual) }
    }
    private func recordSetBody(movementID: String, index setIndex: Int, actual: ActualSet) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        var indexedActual = actual
        if [3, 4].contains(snapshot.state.schemaVersion) {
            guard actual.setIndex == nil || actual.setIndex == setIndex else { throw EngineError(code: "invalid_set", field: "setIndex") }
            indexedActual.setIndex = setIndex
        }
        let row = draft.displayed.exercises[i]; let movement = try await admittedMovement(for: row)
        guard row.kind != .paused, draft.logs[i].problem == .none, !handled(movementID) else { throw EngineError(code: "movement_stopped", field: "set") }
        if [3, 4].contains(snapshot.state.schemaVersion) {
            if draft.logs[i].actualSets.first(where: { $0.setIndex == setIndex }) == indexedActual { return }
        } else if setIndex >= 0, setIndex < draft.logs[i].actualSets.count, draft.logs[i].actualSets[setIndex] == indexedActual { return }
        guard reviewStep == nil, row.sets.indices.contains(setIndex), nextSetIndex(log: draft.logs[i], row: row) == setIndex,
              actual.reps >= 0, (actual.leftReps ?? 0) >= 0, (actual.rightReps ?? 0) >= 0,
              [3, 4].contains(snapshot.state.schemaVersion) || actual.reps > 0 || (actual.leftReps ?? 0) > 0 || (actual.rightReps ?? 0) > 0 else { throw EngineError(code: "invalid_set", field: "reps") }
        if movement.repCounting == .total, actual.leftReps != nil || actual.rightReps != nil { throw EngineError(code: "unexpected_side_reps", field: "set") }
        guard movement.loadingMode != .externalLoad || draft.logs[i].actualLoad != nil else { throw EngineError(code: "load_confirmation_required", field: "load") }
        try requireReviewedHandling(movementID: movementID, load: draft.logs[i].actualLoad)
        try requireMissReason(indexedActual, row: row, index: setIndex)
        try await requireWorkingExposure(row)
        if reconciledResumeStep != nil { try await reconcileActionFlow(&draft) }
        draft.logs[i].actualSets.append(indexedActual); draft.workingSetsStarted = true
        // Canonical archives store integer seconds. Round only the UI deadline up
        // (less than one extra rest second), never the clock/date or performed data.
        let deadline = now().addingTimeInterval(TimeInterval(row.restSeconds))
        draft.restDeadline = Date(timeIntervalSinceReferenceDate: ceil(deadline.timeIntervalSinceReferenceDate))
        routeOccupiedSet(&draft, at: i, performedIndex: setIndex)
        try await save(draft)
    }
    func recordEffort(movementID: String, effort: Effort) async throws {
        try await operations.perform { _ in try await recordEffortBody(movementID: movementID, effort: effort) }
    }
    private func recordEffortBody(movementID: String, effort: Effort) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        draft.logs[i].finalEffort = effort
        if [3, 4].contains(snapshot.state.schemaVersion) { draft.logs[i].effortScope = .allWorkingSets }
        try await save(draft)
    }
    func recordProblem(movementID: String, problem: Problem, pendingActual: ActualSet? = nil) async throws {
        try await operations.perform { _ in try await recordProblemBody(movementID: movementID, problem: problem, pendingActual: pendingActual) }
    }
    private func recordProblemBody(movementID: String, problem: Problem, pendingActual: ActualSet? = nil) async throws {
        guard problem != .none else { throw EngineError(code: "problem_cannot_clear", field: "problem") }
        var draft = try await editableDraft(allowDateChoice: true); let i = try index(movementID, draft: draft)
        if draft.logs[i].problem == problem, pendingActual == nil { return }
        if reconciledResumeStep != nil { try await reconcileActionFlow(&draft) }
        guard draft.logs[i].problem == .none || draft.logs[i].problem == problem else { throw EngineError(code: "problem_cannot_change", field: "problem") }
        if draft.logs[i].problem == .none { try await appendPending(pendingActual, at: i, to: &draft) }
        draft.logs[i].problem = problem; draft.logs[i].status = .stopped; draft.workingSetsStarted = true
        acknowledge(movementID, draft: &draft)
        routeSummary(movementID, draft: &draft)
        try await save(draft, authoritativeOutcome: true)
    }
    private func appendPending(_ actual: ActualSet?, at index: Int, to draft: inout WorkoutDraft) async throws {
        guard let actual else { return }
        let row = draft.displayed.exercises[index]
        let metadata = try await admittedMovement(for: row)
        guard !handled(row.movementID), row.kind != .paused, let slot = nextSetIndex(log: draft.logs[index], row: row),
              actual.reps >= 0, (actual.leftReps ?? 0) >= 0, (actual.rightReps ?? 0) >= 0,
              metadata.repCounting == .perSide || (actual.leftReps == nil && actual.rightReps == nil) else {
            throw EngineError(code: "invalid_set", field: "pendingActual")
        }
        // Unknown load/missing side remain unknown. Raw set and outcome commit together.
        var retained = actual
        if [3, 4].contains(snapshot.state.schemaVersion) {
            guard actual.setIndex == nil || actual.setIndex == slot else { throw EngineError(code: "invalid_set", field: "setIndex") }
            retained.setIndex = slot
        }
        draft.logs[index].actualSets.append(retained); draft.workingSetsStarted = true
    }
    private func acknowledge(_ id: String, draft: inout WorkoutDraft) {
        if draft.acknowledgedMovementIDs == nil { draft.acknowledgedMovementIDs = [] }
        if !draft.acknowledgedMovementIDs!.contains(id) { draft.acknowledgedMovementIDs!.append(id) }
    }
    func recordStatus(movementID: String, status: LogStatus, pendingActual: ActualSet? = nil) async throws {
        try await operations.perform { _ in try await recordStatusBody(movementID: movementID, status: status, pendingActual: pendingActual) }
    }
    private func recordStatusBody(movementID: String, status: LogStatus, pendingActual: ActualSet? = nil) async throws {
        var draft = try await editableDraft(); let i = try index(movementID, draft: draft)
        let row = draft.displayed.exercises[i]
        if handled(movementID), draft.logs[i].status == status, pendingActual == nil { return }
        if reconciledResumeStep != nil { try await reconcileActionFlow(&draft) }
        guard !handled(movementID) || status == draft.logs[i].status else { throw EngineError(code: "movement_stopped", field: "status") }
        if status == .completed, let pendingActual, let slot = nextSetIndex(log: draft.logs[i], row: row) {
            try requireMissReason(pendingActual, row: row, index: slot)
        }
        try await appendPending(pendingActual, at: i, to: &draft)
        let log = draft.logs[i]
        if log.problem != .none && status != .stopped { throw EngineError(code: "movement_stopped", field: "status") }
        if status == .completed, !(await validCompletion(log, row: row)) { throw EngineError(code: "incomplete_sets", field: "status") }
        guard status != .skipped || log.actualSets.isEmpty else { throw EngineError(code: "partial_required", field: "status") }
        draft.logs[i].status = status; acknowledge(movementID, draft: &draft)
        routeSummary(movementID, draft: &draft)
        try await save(draft, authoritativeOutcome: status == .partial || status == .stopped)
    }
    func stopForLoadCorrection(movementID: String, pendingActual: ActualSet? = nil) async throws {
        try await operations.perform { _ in try await stopForLoadCorrectionBody(movementID: movementID, pendingActual: pendingActual) }
    }
    private func stopForLoadCorrectionBody(movementID: String, pendingActual: ActualSet? = nil) async throws {
        // Explicit user confirmation, never an overwrite or same-session restart.
        try await recordStatusBody(movementID: movementID, status: .partial, pendingActual: pendingActual)
    }
    private func validCompletion(_ log: ExerciseLog, row: ExercisePrescription) async -> Bool {
        let state = snapshot.state
        return await Task.detached(priority: .userInitiated) {
            guard let metadata = MovementPrescriptionSummary.effectiveMovement(state: state, variantID: row.movementID) else { return false }
            return qualifiesCompletedExercise(log, prescription: row, movement: metadata, schemaVersion: state.schemaVersion)
        }.value
    }
    var canRecoverRejectedCompletion: Bool { rejectedRepair != nil }
    var recoveryMovementNames: [String] {
        guard let repair = rejectedRepair else { return [] }
        return repair.original.displayed.exercises.enumerated().compactMap { i, row in
            repair.original.logs[i].status != repair.repaired.logs[i].status ? movement(for: row).name : nil
        }
    }
    func recoverRejectedCompletion() async throws {
        try await operations.perform { _ in try await recoverRejectedCompletionBody() }
    }
    private func recoverRejectedCompletionBody() async throws {
        try await requireReady()
        guard let repair = rejectedRepair, let (event, _, revision) = submitted else { throw EngineError(code: "recovery_unavailable", field: "draft") }
        let current = try await repository.snapshot(programID: programID)
        guard current.health == .ready, current.state.revision == revision, current.draft == repair.original,
              !current.history.contains(where: { $0.eventID == event.eventID }) else { throw EngineError(code: "recovery_proof_changed", field: "draft") }
        snapshot = try await repository.repairRejectedDraft(programID: programID, expectedDraftHash: try await Task.detached { try BackupService.hash(repair.original) }.value)
        submitted = nil; rejectedRepair = nil
    }
    func changeSetup(_ change: VariantChange) async throws {
        try await operations.perform { _ in try await changeSetupBody(change) }
    }
    private func changeSetupBody(_ change: VariantChange) async throws {
        try await requireReady()
        guard canChangePreparation else { throw EngineError(code: "working_draft_locked", field: "setup") }
        // Setup invalidation and replacement remain within the retained draft's policy lifetime.
        let startedWithLegacyDraft = snapshot.draft != nil && snapshot.draft?.startedAtMilliseconds == nil
        let mode = snapshot.draft?.sessionMode
        let slot = WorkoutSlot(date: snapshot.state.activePrescription.date, slotID: snapshot.state.activePrescription.slotID)
        snapshot = try await repository.applyVariantChange(programID: programID, expectedRevision: snapshot.state.revision, change: change, next: slot, invalidateEmptyDraft: true)
        if let mode { try await startBody(easierToday: mode == .easier, retainingLegacyDraftPolicy: startedWithLegacyDraft) }
    }
    func reviewStrengthHandling(variantID: String, choice: StrengthHandlingChoice) async throws {
        try await operations.perform { _ in
            try await requireReady()
            guard canChangePreparation else { throw EngineError(code: "working_draft_locked", field: "handling") }
            let mode = snapshot.draft?.sessionMode
            let slot = WorkoutSlot(date: snapshot.state.activePrescription.date, slotID: snapshot.state.activePrescription.slotID)
            snapshot = try await repository.applyConfiguration(programID: programID, expectedRevision: snapshot.state.revision,
                change: .reviewStrengthHandling(variantID: variantID, choice: choice), next: slot, invalidateEmptyDraft: true)
            if let mode { try await startBody(easierToday: mode == .easier) }
        }
    }
    func selectBridgeLoadingMode(variantID: String, mode: LoadingMode) async throws {
        try await operations.perform { _ in
            try await requireReady()
            guard canChangePreparation, snapshot.state.schemaVersion == 4,
                  snapshot.state.config.profileID == "starter-glute-v1",
                  let variant = snapshot.state.config.variants?[variantID], variant.baseMovementID == "db_floor_glute_bridge",
                  mode == .bodyweight || mode == .externalLoad else {
                throw EngineError(code: "invalid_loading_override", field: "loadingMode")
            }
            let rules = try RulesetCatalog.resolve(version: snapshot.state.rulesetVersion, hash: snapshot.state.rulesetHash)
            if try resolveEffectiveMovement(config: snapshot.state.config, variantID: variantID, rules: rules).loadingMode == mode { return }
            let candidates = try (snapshot.state.config.variants ?? [:]).values.filter {
                guard $0.baseMovementID == variant.baseMovementID else { return false }
                return try resolveEffectiveMovement(config: snapshot.state.config, variantID: $0.id, rules: rules).loadingMode == mode
            }.sorted { $0.id < $1.id }
            if let saved = candidates.first {
                try await changeSetupBody(.select(baseMovementID: variant.baseMovementID, variantID: saved.id))
            } else {
                guard mode == .bodyweight else { throw EngineError(code: "invalid_loading_override", field: "loadingMode") }
                try await changeSetupBody(.createLoadingMode(baseMovementID: variant.baseMovementID,
                    variantID: UUID().uuidString.lowercased(), modifications: "Bodyweight bridge", mode: .bodyweight))
            }
        }
    }
    // Settings never discard/rebind an active draft or a frozen Finish payload.
    var canEditProgramSettings: Bool { (submitted == nil || finished) && snapshot.draft == nil && snapshot.health == .ready }
    func changeProgram(_ change: ConfigurationChange) async throws {
        try await operations.perform { _ in try await changeProgramBody(change) }
    }
    private func changeProgramBody(_ change: ConfigurationChange) async throws {
        try await requireReady()
        guard canEditProgramSettings else { throw EngineError(code: "working_draft_locked", field: "settings") }
        let slot = WorkoutSlot(date: snapshot.state.activePrescription.date, slotID: snapshot.state.activePrescription.slotID)
        snapshot = try await repository.applyConfiguration(programID: programID, expectedRevision: snapshot.state.revision, change: change, next: slot)
    }
    func changeStarterProgram(choice: StarterProgramChoice, goal: Goal) async throws {
        try await operations.perform { _ in
            try await requireReady()
            guard canEditProgramSettings else { throw EngineError(code: "working_draft_locked", field: "settings") }
            let config = try selectStarterProgram(choice: choice, goal: goal, programID: programID)
            let today = try CalendarContext(timeZoneID: timeZoneID).localDate(at: now())
            var earliest = max(today, snapshot.state.activePrescription.date)
            if let last = snapshot.state.lastSessionDate { earliest = max(earliest, try last.adding(days: 1)) }
            let next = try WorkoutScheduler.nextSlot(onOrAfter: earliest, config: config)
            guard let head = snapshot.history.first(where: { $0.returnedState.revision == snapshot.state.revision }) else {
                throw EngineError(code: "stale_head", field: "history")
            }
            snapshot = try await repository.changeStarterProgram(programID: programID, expectedRevision: snapshot.state.revision,
                expectedHeadHash: head.envelopeHash, choice: choice, goal: goal, next: next)
        }
    }
    func restoreBackup(_ document: BackupDocument) async throws -> ImportReceipt {
        return try await operations.perform { _ in try await restoreBackupBody(document) }
    }
    func restoreBackup(_ document: BackupDocument, operation: TrainingOperationGate.Lease) async throws -> ImportReceipt {
        try operations.requireOwnership(operation)
        return try await restoreBackupBody(document)
    }
    private func restoreBackupBody(_ document: BackupDocument) async throws -> ImportReceipt {
        try await requireReady()
        guard canEditProgramSettings else { throw EngineError(code: "working_draft_locked", field: "backup") }
        let receipt = try await repository.importBackup(document)
        #if DEBUG
        try await restoreBeforeAdoptionForTesting?()
        #endif
        snapshot = try await repository.snapshot(programID: programID)
        return receipt
    }
    func finish() async throws -> FinalizationReceipt {
        // Concurrent Finish callers await the same operation and frozen payload.
        if let finishOperation { return try await finishOperation.value }
        let operation = try operations.begin()
        let task = Task { try await finishBody() }
        finishOperation = task
        defer { finishOperation = nil; operations.end(operation) }
        return try await task.value
    }
    private func finishBody() async throws -> FinalizationReceipt {
        try await requireReady()
        if submitted == nil {
            let draft = try await editableDraft()
            if let acknowledged = draft.acknowledgedMovementIDs {
                guard Set(acknowledged) == Set(draft.displayed.exercises.map(\.movementID)) else { throw EngineError(code: "incomplete_workout", field: "logs") }
            } else {
                guard draft.logs.allSatisfy({ $0.status != .partial || $0.problem != .none }) else { throw EngineError(code: "incomplete_workout", field: "logs") }
            }
            if let flow = draft.flow {
                guard flow.forward == .workoutReview,
                      Set(flow.reviewedSummaryMovementIDs) == Set(draft.displayed.exercises.map(\.movementID)) else {
                    throw EngineError(code: "incomplete_workout", field: "review")
                }
            }
            let capturedNow = now(), config = snapshot.state.config
            submitted = try await Task.detached(priority: .userInitiated) {
                var event = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date, slotID: draft.displayed.slotID,
                    prescriptionID: draft.displayed.id, plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode,
                    exercises: draft.logs, observationAudit: draft.observationAudit)
                let finish = try SessionTiming.milliseconds(at: capturedNow)
                let today = try SessionTiming.localDate(milliseconds: finish, timeZoneID: draft.timeZoneID)
                let next: WorkoutSlot
                if let start = draft.startedAtMilliseconds {
                    event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: start,
                        finishedAtMilliseconds: finish, timeZoneID: draft.timeZoneID)
                    next = try WorkoutScheduler.nextRotation(after: max(today, draft.planned.date), consumedSlotID: draft.planned.slotID, config: config)
                } else {
                    next = try WorkoutScheduler.nextSlot(after: max(today, draft.date), config: config)
                }
                return (event, next, draft.expectedRevision)
            }.value
        }
        let (event, next, revision) = submitted!
        if snapshot.draft?.pendingFinish == nil, let draft = snapshot.draft {
            snapshot = try await repository.freezeDraftFinish(programID: programID, expectedDraftHash: try await Task.detached { try BackupService.hash(draft) }.value,
                submission: PendingWorkoutFinish(event: event, next: next, expectedRevision: revision))
        }
        let ownedDraftID = snapshot.draft?.id
        let receipt = try await repository.finalize(programID: programID, expectedRevision: revision, event: event, next: next)
        if case let .rejected(_, errors) = receipt.result {
            if errors == ["invalid_sets"], receipt.snapshot.health == .ready,
               receipt.snapshot.state.revision == revision,
               let original = snapshot.draft, receipt.snapshot.draft == original,
               original.id.uuidString.lowercased() == event.eventID, original.logs == event.exercises,
               !receipt.snapshot.history.contains(where: { $0.eventID == event.eventID }),
               let pending = original.pendingFinish {
                let state = receipt.snapshot.state
                let repaired = try? await Task.detached(priority: .userInitiated) {
                    try BackupService.rejectedCompletionRepair(original, state: state,
                        rules: RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash), submission: pending)
                }.value
                if let repaired {
                    rejectedRepair = (original, repaired)
                }
            }
            throw EngineError(code: errors.joined(separator: ", "), field: "finish")
        }
        snapshot = receipt.snapshot; finished = true; reviewStep = nil; reconciledResumeStep = nil
        if let ownedDraftID { await removeScratch(draftID: ownedDraftID) }
        return receipt
    }
}

/// MainActor ownership spans actor hops and authoritative snapshot adoption.
/// Leases are passed only to explicit nested composition workflows.
@MainActor @Observable final class TrainingOperationGate {
    struct Lease { fileprivate let id: UUID }
    private var owner: UUID?
    #if DEBUG
    var contextEnabled = true
    #else
    let contextEnabled = true
    #endif
    var afterRelease: (@MainActor () -> Void)?
    private var deferred: (@MainActor (Lease) async -> Void)?
    func whenIdle(_ action: @escaping @MainActor (Lease) async -> Void) {
        deferred = action
        runDeferred()
    }
    private func runDeferred() {
        #if DEBUG
        guard contextEnabled else { return }
        #endif
        guard owner == nil, let action = deferred else { return }
        deferred = nil
        let lease = try! begin()
        Task { await action(lease); end(lease, notify: false) }
    }
    var busy: Bool { owner != nil }
    func perform<Result>(_ action: @MainActor (Lease) async throws -> Result) async throws -> Result {
        let lease = try begin()
        defer { end(lease) }
        return try await action(lease)
    }
    fileprivate func begin() throws -> Lease {
        #if DEBUG
        guard contextEnabled else { throw EngineError(code: "inactive_context", field: "operation") }
        #endif
        guard owner == nil else { throw EngineError(code: "operation_in_progress", field: "operation") }
        let lease = Lease(id: UUID()); owner = lease.id
        return lease
    }
    fileprivate func end(_ lease: Lease, notify: Bool = true) {
        precondition(owner == lease.id)
        owner = nil
        if notify { afterRelease?() }
        runDeferred()
    }
    func requireOwnership(_ lease: Lease) throws {
        guard owner == lease.id else { throw EngineError(code: "operation_in_progress", field: "operation") }
    }
}
