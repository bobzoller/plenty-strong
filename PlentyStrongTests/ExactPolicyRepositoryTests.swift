import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@Suite(.serialized) struct ExactPolicyRepositoryTests {
    @Test func activationAtomicityAndStaleHead() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let original = try await s.repository.exportBackup()
        let snapshot = try await s.repository.snapshot(programID: s.programID)
        await #expect(throws: (any Error).self) {
            try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 9, expectedHeadHash: original.heads[snapshot.state.config.programID]!)
        }
        await #expect(throws: (any Error).self) {
            try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 0, expectedHeadHash: "stale")
        }
        await s.repository.failNextSave()
        await #expect(throws: (any Error).self) {
            try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 0, expectedHeadHash: original.heads[snapshot.state.config.programID]!)
        }
        #expect(try await s.repository.exportBackup() == original)
        let activated = try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 0, expectedHeadHash: original.heads[snapshot.state.config.programID]!)
        #expect(activated.state.schemaVersion == 3 && activated.state.revision == 1)
        #expect(activated.history.first == snapshot.history.first)
        #expect(try await s.repository.counts() == [2,1,0,2,0])
        #expect(try await s.repository.rules(for: activated.state) == RulesetCatalog.exactV1())
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID) == activated)
    }
    @Test func legacyDraftBlocksActivationUntilFinalized() async throws {
        for kind in 0..<3 {
            let s = try await RepositoryTestHarness.make(goal: .size)
            var draft = try await s.draft(empty: kind == 0)
            if kind == 2 { draft.logs[0].status = .stopped; draft.logs[0].problem = .pain }
            try await s.repository.saveDraft(draft)
            let original = try await s.repository.exportBackup()
            await #expect(throws: (any Error).self) {
                try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 0, expectedHeadHash: original.heads[draft.programID]!)
            }
            #expect(try await s.repository.exportBackup() == original)
            var event = s.firstEvent; event.exercises = draft.logs
            if kind == 0 { for i in event.exercises.indices { event.exercises[i].status = .skipped } }
            if kind == 0 { draft.logs = event.exercises; try await s.repository.saveDraft(draft) }
            let finalized = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
            #expect(finalized.snapshot.state.schemaVersion == 2 && finalized.snapshot.draft == nil)
            let legacy = try await s.repository.exportBackup()
            let exact = try await s.repository.activateExactPolicy(programID: s.programID, expectedRevision: 1, expectedHeadHash: legacy.heads[draft.programID]!)
            _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
            #expect(try await s.repository.counts() == [3,1,0,3,0])
            #expect(exact.history[1].command == JournalCommand.workout(completedWorkout: event, next: s.next))
            #expect(legacy.journal.allSatisfy { old in exact.history.contains { (try? BackupService.bytes($0)) == old.bytes } })
        }
    }
}

/// Synthetic exact events are authored explicitly; the frozen legacy harness stays v1.
func exactActivationEvent(state: ProgramState) -> CompletedWorkout {
    var event = RepositoryTestHarness.event(state: state, reps: 8)
    for i in event.exercises.indices {
        event.exercises[i].actualSets = event.exercises[i].actualSets.enumerated().map { index, set in
            var set = set; set.setIndex = index; return set
        }
        event.exercises[i].effortScope = .allWorkingSets
        event.exercises[i].skippedSetIndices = []
        event.exercises[i].mixedLoads = false
    }
    return event
}
func activateSynthetic(_ repository: TrainingRepository, id: UUID) async throws -> StoreSnapshot {
    let snapshot = try await repository.snapshot(programID: id)
    let doc = try await repository.exportBackup()
    return try await repository.activateExactPolicy(programID: id, expectedRevision: snapshot.state.revision, expectedHeadHash: doc.heads[snapshot.state.config.programID]!)
}

extension ExactPolicyRepositoryTests {
    @Test func activationNormalEvidenceIgnoresLaterEasier() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        var state = try await s.repository.snapshot(programID: s.programID).state
        let normal = RepositoryTestHarness.event(state: state, reps: 10)
        let thursday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: state.revision, event: normal, next: thursday)
        state = try await s.repository.snapshot(programID: s.programID).state
        let easier = try prepareWorkout(state: state, rules: RulesetCatalog.fixedV1(), easierToday: true)
        var event = RepositoryTestHarness.event(state: state, reps: 8)
        event.sessionMode = .easier; event.prescriptionID = easier.id
        for i in event.exercises.indices {
            event.exercises[i].prescriptionID = easier.id
            event.exercises[i].actualSets = Array(event.exercises[i].actualSets.prefix(easier.exercises[i].sets.count))
        }
        let sunday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: state.revision, event: event, next: sunday)
        state = try await s.repository.snapshot(programID: s.programID).state
        var partial = RepositoryTestHarness.event(state: state, reps: 8)
        for i in partial.exercises.indices { partial.exercises[i].status = .partial; partial.exercises[i].actualSets = Array(partial.exercises[i].actualSets.prefix(1)) }
        let future = WorkoutSlot(date: try LocalDate(iso8601: "2026-11-05"), slotID: "THU")
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: state.revision, event: partial, next: future)
        let before = try await s.repository.snapshot(programID: s.programID)
        let ids = try policyActivationEvidenceEventIDs(state: before.state, history: before.history)
        #expect(Set(ids) == Set([s.firstEvent.eventID, normal.eventID]))
        let exact = try await activateSynthetic(s.repository, id: s.programID)
        if case let .activatePolicy(_, _, recorded, _) = exact.history.last!.command { #expect(recorded == ids) }
        else { Issue.record("Missing activation command") }
        #expect(exact.state.exercises[normal.exercises[0].movementID]?.exactRepState?.lastSuitableNormalDate == normal.date)
        #expect(exact.state.exercises[normal.exercises[0].movementID]?.interruptedReturn == true)
        #expect(exact.state.activePrescription.exercises.allSatisfy { row in
            exact.state.exercises[row.movementID]?.exactRepState?.lastSuitableNormalDate == nil ? row.phase == .baseline : (row.phase == .returning && row.sets.count == 2)
        })
        let document = try await s.repository.exportBackup()
        for evidence in [[], [event.eventID], ["foreign-event"], ids + ids] {
            var forged = document
            var activation = try JSONDecoder().decode(JournalEnvelope.self, from: forged.journal.last!.bytes)
            activation.command = .activatePolicy(sourceRulesetHash: before.state.rulesetHash, destinationRulesetHash: exact.state.rulesetHash, normalEvidenceEventIDs: evidence, next: future)
            activation.eventHash = try BackupService.eventHash(activation.command)
            activation.envelopeHash = try BackupService.envelopeHash(activation)
            forged.journal[forged.journal.count - 1] = try BackupService.object(activation, id: activation.eventID)
            forged.heads[activation.programID] = activation.envelopeHash
            #expect(throws: (any Error).self) { try BackupService.validate(forged) }
        }
        #expect(throws: (any Error).self) { try policyActivationEvidenceEventIDs(state: before.state, history: Array(before.history.dropFirst())) }
    }
    @MainActor @Test func appStartActivatesWithoutRewritingRetainedDraft() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let now = { Date(timeIntervalSince1970: 1_791_137_000) }
        let app = AppComposition(repository: s.repository, workout: nil, cloudCoordinator: nil)
        app.now = now
        try await app.reloadLocalProductChoices()
        let model = try #require(app.workout)
        try await model.start(easierToday: false)
        #expect(model.snapshot.state.schemaVersion == 3)
        #expect(model.snapshot.draft?.logs.allSatisfy { $0.actualSets.isEmpty && $0.effortScope == .allWorkingSets && $0.skippedSetIndices == [] && $0.mixedLoads == false } == true)
        let old = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await old.draft(empty: true)
        try await old.repository.saveDraft(draft)
        let original = try await old.repository.exportBackup()
        let retainedApp = AppComposition(repository: old.repository, workout: nil, cloudCoordinator: nil)
        retainedApp.now = now
        try await retainedApp.reloadLocalProductChoices()
        try await retainedApp.workout!.start(easierToday: false)
        #expect(retainedApp.workout!.snapshot.state.schemaVersion == 2)
        #expect(try await old.repository.exportBackup() == original)
    }
}

extension ExactPolicyRepositoryTests {
    @Test(arguments: [false,true]) func resolvedLegacyHistoryUsesSelectedEvidenceAndUnionedPain(duplicateEventIdentity: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let prefix = try await s.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(prefix)
        let state = try await s.repository.snapshot(programID: s.programID).state
        let selected = RepositoryTestHarness.event(state: state, reps: 10)
        let thursday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 1, event: selected, next: thursday)
        var discarded = RepositoryTestHarness.event(state: state, reps: 10)
        if duplicateEventIdentity { discarded.eventID = selected.eventID }
        discarded.exercises[0].problem = .pain; discarded.exercises[0].status = .stopped
        _ = try await other.finalize(programID: s.programID, expectedRevision: 1, event: discarded, next: thursday)
        let lostState = try await other.snapshot(programID: s.programID).state
        let laterDiscarded = RepositoryTestHarness.event(state: lostState, reps: 10)
        let sunday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        _ = try await other.finalize(programID: s.programID, expectedRevision: 2, event: laterDiscarded, next: sunday)
        let chosenHead = try await s.repository.exportBackup().heads[state.config.programID]!
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await s.repository.exportBackup()))
        let reviewed = Set(proof.quarantined.filter { $0.programID == state.config.programID }.map { BackupService.hash($0.record.bytes) }).sorted()
        let resolved = try await s.repository.resolveConflict(programID: s.programID, expectedHeadHashes: proof.heads[state.config.programID]!,
            selection: BranchSelection(selectedHeadHash: chosenHead, configurationHeadHash: chosenHead, reviewedQuarantineChecksums: reviewed), next: sunday)
        let ids = try policyActivationEvidenceEventIDs(state: resolved.state, history: resolved.history)
        #expect(ids.contains(selected.eventID) && (duplicateEventIdentity || !ids.contains(discarded.eventID)) && !ids.contains(laterDiscarded.eventID))
        #expect(resolved.state.baseSafety![discarded.exercises[0].baseMovementID!]!.paused)
        let activated = try await activateSynthetic(s.repository, id: s.programID)
        #expect(activated.state.baseSafety == resolved.state.baseSafety)
        #expect(activated.state.exercises[selected.exercises[1].movementID]?.exactRepState?.lastSuitableNormalDate == selected.date)
        #expect(throws: (any Error).self) { try policyActivationEvidenceEventIDs(state: resolved.state, history: resolved.history.filter { $0.eventID != laterDiscarded.eventID }) }
    }
}

extension ExactPolicyRepositoryTests {
    @MainActor @Test func legacyEmptySetupChangesRetainPolicyUntilSubsequentDraftFreeStart() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await s.draft(empty: true)
        try await s.repository.saveDraft(draft)
        let repository = try await s.reopened()
        let app = AppComposition(repository: repository, workout: nil, cloudCoordinator: nil)
        app.now = { Date(timeIntervalSince1970: 1_791_137_000) }
        try await app.reloadLocalProductChoices()
        let model = try #require(app.workout)
        #expect(model.snapshot.draft == draft)
        let row = try #require(draft.displayed.exercises.first)
        let base = try #require(row.baseMovementID)
        let changes: [VariantChange] = [
            .create(baseMovementID: base, variantID: "retained-legacy-setup", modifications: "Altered setup"),
            .correctDescription(variantID: "retained-legacy-setup", modifications: "Corrected setup"),
            .select(baseMovementID: base, variantID: row.movementID)
        ]
        for (index, change) in changes.enumerated() {
            let previous = try #require(model.snapshot.draft)
            try await model.changeSetup(change)
            let replacement = try #require(model.snapshot.draft)
            #expect(replacement.id != previous.id && replacement.sessionMode == draft.sessionMode)
            #expect(model.snapshot.state.schemaVersion == 2)
            #expect(replacement.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps == nil } })
            #expect(replacement.logs.allSatisfy { $0.effortScope == nil && $0.actualSets.isEmpty && $0.skippedSetIndices == nil && $0.mixedLoads == nil })
            #expect(model.snapshot.history.count == index + 2)
            #expect(model.snapshot.history.allSatisfy { if case .activatePolicy = $0.command { false } else { true } })
        }
        #expect(model.snapshot.state.config.variants?["retained-legacy-setup"]?.modifications == "Corrected setup")
        #expect(model.snapshot.state.config.activeVariantIDs?[base] == row.movementID)
        try await model.resolveDateChange(keepOriginal: false)
        try await model.start(easierToday: false)
        #expect(model.snapshot.state.schemaVersion == 3)
        #expect(model.snapshot.draft?.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps != nil } } == true)
        #expect(model.snapshot.history.count == 5)
        try await model.start(easierToday: false)
        #expect(model.snapshot.history.filter { if case .activatePolicy = $0.command { true } else { false } }.count == 1)
        await repository.close()
    }
    @MainActor @Test func legacyEmptyModeSwitchRetainsPolicyUntilSubsequentDraftFreeStart() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await s.draft(empty: true)
        try await s.repository.saveDraft(draft)
        let app = AppComposition(repository: s.repository, workout: nil, cloudCoordinator: nil)
        app.now = { Date(timeIntervalSince1970: 1_791_137_000) }
        try await app.reloadLocalProductChoices()
        let model = try #require(app.workout)
        try await model.start(easierToday: true)
        #expect(model.snapshot.state.schemaVersion == 2)
        let replaced = try #require(model.snapshot.draft)
        #expect(replaced.sessionMode == .easier && replaced.id != draft.id)
        #expect(replaced.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps == nil } })
        #expect(replaced.logs.allSatisfy { $0.effortScope == nil && $0.actualSets.isEmpty && $0.skippedSetIndices == nil && $0.mixedLoads == nil })
        #expect(model.snapshot.history.count == 1)
        try await model.resolveDateChange(keepOriginal: false)
        try await model.start(easierToday: false)
        #expect(model.snapshot.state.schemaVersion == 3)
        #expect(model.snapshot.draft?.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps != nil } } == true)
        #expect(model.snapshot.history.count == 2)
    }
    @MainActor @Test func exactStartBindsOrdinarySetIndexWithoutChangingRawValues() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let initial = try await s.repository.snapshot(programID: s.programID)
        let model = WorkoutViewModel(repository: s.repository, snapshot: initial, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: 1_791_137_000) }, activatesExactPolicy: true)
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide }!
        if let load = row.load { try await model.confirmLoad(movementID: row.movementID, load: load) }
        let raw = ActualSet(reps: 4, leftReps: 4, rightReps: 3, missedGoalReason: .timeInterruption)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: raw)
        var indexed = raw; indexed.setIndex = 0
        #expect(model.log(for: row.movementID)?.actualSets == [indexed])
        let saved = try await s.repository.exportBackup()
        var conflicting = raw; conflicting.setIndex = 0
        await #expect(throws: (any Error).self) { try await model.recordSet(movementID: row.movementID, index: 1, actual: conflicting) }
        #expect(try await s.repository.exportBackup() == saved)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: raw)
        #expect(try await s.repository.exportBackup() == saved)
    }
}
