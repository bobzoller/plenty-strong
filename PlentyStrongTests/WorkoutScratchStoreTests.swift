import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor @Suite(.serialized) struct WorkoutScratchStoreTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)") }
    private func key(draft: UUID = UUID(), store: String = "real", hash: String? = nil) -> WorkoutScratchKey {
        WorkoutScratchKey(storeID: store, datasetID: "dataset", programID: "program", draftID: draft,
            prescriptionID: "prescription", step: .set(movementID: "movement", index: 0), expectedObservationHash: hash)
    }
    @Test func staleAndOutOfOrderWritesCannotCrossContext() async throws {
        let url = directory(), store = WorkoutScratchStore(directory: url), k = key()
        try await store.save(WorkoutScratch(generation: 2, key: k, entry: SetEntryDraft(reps: "8")))
        try await store.save(WorkoutScratch(generation: 1, key: k, entry: SetEntryDraft(reps: "7")))
        #expect(try await store.load(key: k)?.entry.reps == "8")
        #expect(try await store.load(key: key(draft: k.draftID, store: "demo")) == nil)
        #expect(try await store.load(key: key(draft: k.draftID, hash: "actual")) == nil)
        try await store.invalidate(draftID: k.draftID, throughGeneration: 3)
        try await store.save(WorkoutScratch(generation: 2, key: k, entry: SetEntryDraft(reps: "stale")))
        #expect(try await WorkoutScratchStore(directory: url).load(key: k) == nil)
        try await store.save(WorkoutScratch(generation: 4, key: k, entry: SetEntryDraft(reps: "9")))
        #expect(try await store.load(key: k)?.entry.reps == "9")
        try await store.remove(draftID: k.draftID)
        try await WorkoutScratchStore(directory: url).save(WorkoutScratch(generation: 99, key: k, entry: SetEntryDraft(reps: "late")))
        #expect(try await store.load(key: k) == nil)
    }
    @Test func corruptAndUnsupportedFilesRejectWithoutDraftMutation() async throws {
        let url = directory(), store = WorkoutScratchStore(directory: url), k = key()
        await #expect(throws: (any Error).self) { try await store.save(WorkoutScratch(version: 99, generation: 1, key: k, entry: SetEntryDraft(reps: "8"))) }
        try await store.save(WorkoutScratch(generation: 1, key: k, entry: SetEntryDraft(reps: "8")))
        let file = try #require(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var scratch = try #require(record["scratch"] as? [String: Any])
        record["generation"] = 0; scratch["generation"] = 0; record["scratch"] = scratch
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        await #expect(throws: (any Error).self) { _ = try await store.load(key: k) }
        try Data("corrupt".utf8).write(to: file)
        await #expect(throws: (any Error).self) { _ = try await store.load(key: k) }
    }
    private func modelKey(_ model: WorkoutViewModel, path: String, hash: String? = nil) throws -> WorkoutScratchKey {
        let draft = try #require(model.snapshot.draft)
        let dataset = try #require(model.snapshot.history.first { $0.parentEnvelopeHash == nil }?.datasetID)
        return WorkoutScratchKey(storeID: path, datasetID: dataset, programID: draft.programID, draftID: draft.id,
            prescriptionID: draft.displayed.id, step: .set(movementID: draft.logs[0].movementID, index: 0), expectedObservationHash: hash)
    }
    @Test func pendingFinishAndDiscardCleanScratch() async throws {
        let f = try await GuidedWorkoutFixture.make(), url = directory(), store = WorkoutScratchStore(directory: url)
        var ready = f.model.snapshot.draft!
        for i in ready.logs.indices { ready.logs[i].status = .skipped }
        ready.acknowledgedMovementIDs = ready.logs.map(\.movementID)
        ready.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: ready.logs.map(\.movementID))
        let snapshot = try await f.repository.saveDraft(ready)
        let model = WorkoutViewModel(repository: f.repository, snapshot: snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: "real")
        let own = try modelKey(model, path: "real"), other = key()
        try await store.save(WorkoutScratch(generation: 1, key: own, entry: SetEntryDraft(reps: "saved text")))
        try await store.save(WorkoutScratch(generation: 1, key: other, entry: SetEntryDraft(reps: "other")))
        model.entryDraft.reps = "visible text"
        await f.repository.failNextSave()
        await #expect(throws: (any Error).self) { _ = try await model.finish() }
        #expect(model.entryDraft.reps == "visible text")
        #expect(try await store.load(key: own)?.entry.reps == "saved text")
        model.entryDraft.reps = "locked change"
        #expect(model.entryDraft.reps == "visible text")
        _ = try await model.finish()
        #expect(model.entryDraft == SetEntryDraft())
        #expect(try await store.load(key: own) == nil)
        #expect(try await store.load(key: other)?.entry.reps == "other")
        try await store.save(WorkoutScratch(generation: 50, key: own, entry: SetEntryDraft(reps: "late")))
        #expect(try await store.load(key: own) == nil)
        await f.repository.close()

        let d = try await GuidedWorkoutFixture.make()
        let discarded = WorkoutViewModel(repository: d.repository, snapshot: d.model.snapshot, timeZoneID: d.model.timeZoneID,
            now: { d.model.now().addingTimeInterval(172800) }, scratchStore: store, scratchStoreID: "real")
        let discardKey = try modelKey(discarded, path: "real")
        try await store.save(WorkoutScratch(generation: 1, key: discardKey, entry: SetEntryDraft(reps: "discard")))
        try await discarded.resolveDateChange(keepOriginal: false)
        #expect(try await store.load(key: discardKey) == nil)
        #expect(try await store.load(key: other)?.entry.reps == "other")
        await d.repository.close()
    }
    @Test func navigationAndSavedActualRejectStaleScratchAndFailureRetainsText() async throws {
        let f = try await GuidedWorkoutFixture.make(), url = directory(), store = WorkoutScratchStore(directory: url)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: "real")
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        try await model.beginMovement(movementID: row.movementID)
        let originalKey = try modelKey(model, path: "real")
        model.entryDraft.reps = "8"; try await model.flushScratch()
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8))
        try await model.flushScratch()
        #expect(model.entryDraft == SetEntryDraft())
        #expect(try await store.load(key: originalKey) == nil)
        let restored = WorkoutViewModel(repository: f.repository, snapshot: model.snapshot, timeZoneID: model.timeZoneID,
            now: model.now, scratchStore: store, scratchStoreID: "real")
        restored.reviewStep = .set(movementID: row.movementID, index: 0)
        let observed = try #require(model.log(for: row.movementID)?.actualSets[0])
        let expected = try modelKey(restored, path: "real", hash: BackupService.hash(observed))
        try await store.save(WorkoutScratch(generation: 99, key: originalKey, entry: SetEntryDraft(reps: "stale actual")))
        try await restored.restoreScratch()
        #expect(restored.entryDraft.reps.isEmpty)
        #expect(try await store.load(key: expected) == nil)
        #expect(restored.log(for: row.movementID)?.actualSets[0] == observed)
        await f.repository.close()

        let broken = directory()
        try Data("file instead of directory".utf8).write(to: broken)
        let b = try await GuidedWorkoutFixture.make()
        let failing = WorkoutViewModel(repository: b.repository, snapshot: b.model.snapshot, timeZoneID: b.model.timeZoneID,
            now: b.model.now, scratchStore: WorkoutScratchStore(directory: broken), scratchStoreID: "broken")
        let bRow = failing.snapshot.draft!.displayed.exercises[0]
        try await failing.confirmLoad(movementID: bRow.movementID, load: #require(failing.movement(for: bRow).availableLoads.first))
        try await failing.beginMovement(movementID: bRow.movementID)
        let before = failing.snapshot
        failing.entryDraft.reps = "unsaved text"
        await #expect(throws: (any Error).self) { try await failing.flushScratch() }
        #expect(failing.entryDraft.reps == "unsaved text" && failing.errorText != nil)
        #expect(failing.snapshot == before)
        await #expect(throws: (any Error).self) { try await failing.skipSet(movementID: bRow.movementID, index: 0) }
        #expect(failing.snapshot == before && failing.entryDraft.reps == "unsaved text")
        #expect(try await b.repository.snapshot(programID: failing.programID) == before)
        await b.repository.close()
    }
    @Test func delayedNavigationInvalidationCannotEraseNextSetEntry() async throws {
        let f = try await GuidedWorkoutFixture.make(), url = directory(), store = WorkoutScratchStore(directory: url)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: "real")
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        try await model.beginMovement(movementID: row.movementID)
        model.entryDraft.reps = "8"; try await model.flushScratch()
        let delay = ScratchNavigationDelay()
        await store.setBeforeInvalidateForTesting { await delay.holdFirst() }
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8))
        await delay.waitUntilEntered()
        try await model.advanceRest()
        #expect(model.visibleStep == .set(movementID: row.movementID, index: 1))
        model.entryDraft.reps = "next set unfinished"; try await model.flushScratch()
        await delay.release()
        let restored = WorkoutViewModel(repository: f.repository, snapshot: model.snapshot, timeZoneID: model.timeZoneID,
            now: model.now, scratchStore: WorkoutScratchStore(directory: url), scratchStoreID: "real")
        try await restored.restoreScratch()
        #expect(restored.entryDraft.reps == "next set unfinished")
        #expect(restored.log(for: row.movementID)?.actualSets.count == 1)
        await f.repository.close()
    }
    @Test func corruptVersionAndExhaustedGenerationPreserveDurableDraft() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await f.model.confirmLoad(movementID: row.movementID, load: #require(f.model.movement(for: row).availableLoads.first))
        try await f.model.beginMovement(movementID: row.movementID)
        let before = f.model.snapshot
        for corruption in ["corrupt", "version"] {
            let url = directory(), store = WorkoutScratchStore(directory: url)
            let k = try modelKey(f.model, path: "real")
            try await store.save(WorkoutScratch(generation: 1, key: k, entry: SetEntryDraft(reps: "8")))
            let file = url.appendingPathComponent(k.draftID.uuidString.lowercased() + ".json")
            if corruption == "corrupt" { try Data("corrupt".utf8).write(to: file) }
            else {
                var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                record["version"] = 99
                try JSONSerialization.data(withJSONObject: record).write(to: file)
            }
            let model = WorkoutViewModel(repository: f.repository, snapshot: before, timeZoneID: f.model.timeZoneID,
                now: f.model.now, scratchStore: store, scratchStoreID: "real")
            try await model.resumeGuidedWorkout()
            #expect(model.snapshot == before && model.entryDraft == SetEntryDraft() && model.errorText != nil)
        }
        let store = WorkoutScratchStore(directory: directory()), k = try modelKey(f.model, path: "real")
        try await store.save(WorkoutScratch(generation: UInt64.max, key: k, entry: SetEntryDraft(reps: "8")))
        let exhausted = WorkoutViewModel(repository: f.repository, snapshot: before, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: "real")
        exhausted.entryDraft.reps = "retained text"
        await #expect(throws: (any Error).self) { try await exhausted.flushScratch() }
        #expect(exhausted.entryDraft.reps == "retained text" && exhausted.snapshot == before)
        #expect(try await f.repository.snapshot(programID: f.model.programID) == before)
        await f.repository.close()
    }
    @Test func corruptRealCompositionReopenKeepsWorkoutReachable() async throws {
        let f = try await GuidedWorkoutFixture.make(), row = f.model.snapshot.draft!.displayed.exercises[0]
        let scratchURL = directory(), path = f.storeURL.standardizedFileURL.path
        let store = WorkoutScratchStore(directory: scratchURL)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: path)
        try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        try await model.beginMovement(movementID: row.movementID)
        model.entryDraft.reps = "unfinished real text"; try await model.flushScratch()
        let before = try await f.repository.exportBackup(), expected = model.snapshot
        let draftID = try #require(model.snapshot.draft?.id)
        await f.repository.close()
        try Data("corrupt sidecar".utf8).write(to: scratchURL.appendingPathComponent(draftID.uuidString.lowercased() + ".json"))
        let reopened = try TrainingRepository.open(at: f.storeURL)
        let composition = AppComposition(repository: reopened, scratchDirectory: scratchURL, scratchStoreID: path)
        composition.now = model.now; composition.timeZoneID = model.timeZoneID
        try await composition.reloadLocalProductChoices()
        let retained = try #require(composition.workout)
        #expect(composition.errorText == nil)
        #expect(retained.errorText != nil)
        #expect(retained.snapshot == expected && retained.entryDraft == SetEntryDraft())
        #expect(retained.log(for: row.movementID)?.actualSets.isEmpty == true)
        composition.showingWorkout = true
        #expect(composition.showingWorkout && composition.workout === retained)
        #expect(try await reopened.exportBackup() == before)
        await reopened.close()
    }
    @Test func backgroundAndContextScratchFailureRetainReachableTextAndFatalState() async throws {
        let f = try await GuidedWorkoutFixture.make(), row = f.model.snapshot.draft!.displayed.exercises[0]
        let broken = directory()
        try Data("file instead of directory".utf8).write(to: broken)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID, now: f.model.now)
        let composition = AppComposition(repository: f.repository, workout: model,
            scratchDirectory: broken, scratchStoreID: f.storeURL.standardizedFileURL.path)
        composition.now = model.now; composition.timeZoneID = model.timeZoneID
        try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        try await model.beginMovement(movementID: row.movementID)
        let before = model.snapshot, backup = try await f.repository.exportBackup()
        composition.showingWorkout = true
        model.entryDraft.reps = "retained during background"
        await composition.pauseRecoveryForBackground()
        #expect(composition.errorText == nil && model.errorText != nil)
        #expect(composition.showingWorkout && composition.workout === model)
        #expect(model.entryDraft.reps == "retained during background" && model.snapshot == before)
        model.entryDraft.reps = "still reachable"
        await composition.suspendContext()
        #expect(composition.errorText == nil && model.errorText != nil)
        #expect(composition.workout === model && model.entryDraft.reps == "still reachable")
        let retainedBackup = try await f.repository.exportBackup()
        #expect(model.snapshot == before && retainedBackup == backup)
        composition.errorText = "Preexisting authoritative local store failure"
        await composition.pauseRecoveryForBackground()
        #expect(composition.errorText == "Preexisting authoritative local store failure")
        #expect(model.entryDraft.reps == "still reachable" && model.snapshot == before)
        await f.repository.close()
    }
    @Test func scratchRelaunchDoesNotBecomeActual() async throws {
        let f = try await GuidedWorkoutFixture.make(), row = f.model.snapshot.draft!.displayed.exercises[0]
        let scratchURL = directory(), store = WorkoutScratchStore(directory: scratchURL)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: f.storeURL.standardizedFileURL.path)
        try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        try await model.beginMovement(movementID: row.movementID)
        let dataset = try #require(model.snapshot.history.first { $0.parentEnvelopeHash == nil }?.datasetID)
        try await f.repository.bindDataset(datasetID: #require(UUID(uuidString: dataset)), to: recoveryScope)
        let before = try await f.repository.exportBackup()
        let commits = ScratchCommitCounter()
        await f.repository.observeCommits { commits.observe($0) }
        model.entryDraft = SetEntryDraft(reps: "unfinished 8", left: "7", reason: .effortLimit)
        try await model.flushScratch()
        await f.repository.close()
        let reopenedRepository = try TrainingRepository.open(at: f.storeURL)
        await reopenedRepository.observeCommits { commits.observe($0) }
        let reopened = try await reopenedRepository.snapshot(programID: model.programID)
        let reopenedStore = WorkoutScratchStore(directory: scratchURL)
        #expect(try await reopenedRepository.exportBackup() == before)
        let restored = WorkoutViewModel(repository: reopenedRepository, snapshot: reopened, timeZoneID: model.timeZoneID,
            now: model.now, scratchStore: reopenedStore, scratchStoreID: f.storeURL.standardizedFileURL.path)
        try await restored.resumeGuidedWorkout()
        #expect(restored.entryDraft == model.entryDraft)
        #expect(restored.log(for: row.movementID)?.actualSets.isEmpty == true)
        restored.entryDraft.reps = "9"
        try await restored.flushScratch()
        let again = WorkoutViewModel(repository: reopenedRepository, snapshot: reopened, timeZoneID: model.timeZoneID,
            now: model.now, scratchStore: reopenedStore, scratchStoreID: f.storeURL.standardizedFileURL.path)
        try await again.resumeGuidedWorkout()
        #expect(again.entryDraft.reps == "9")
        #expect(try await reopenedRepository.exportBackup() == before)
        #expect(commits.count == 0)
        let originalWrites = await store.writeCount, reopenedWrites = await reopenedStore.writeCount
        #expect(originalWrites == 1 && reopenedWrites == 1)
        print("SCRATCH_COMMIT_COUNTS sidecar=2 repository=0")
        let payload = String(decoding: try BackupService.bytes(before), as: UTF8.self)
        #expect(!payload.contains("unfinished 8") && !payload.contains("WorkoutScratch"))
        let pending = try await reopenedRepository.pendingCloudRecords(scope: recoveryScope)
        #expect(!pending.isEmpty && pending.allSatisfy { !String(decoding: $0.payload, as: UTF8.self).contains("unfinished 8") })
        await reopenedRepository.close()
    }
    private func recordedCorrectionFixture(store: WorkoutScratchStore) async throws -> (GuidedWorkoutFixture, WorkoutViewModel, String) {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await f.model.confirmLoad(movementID: row.movementID, load: #require(f.model.movement(for: row).availableLoads.first))
        try await f.model.beginMovement(movementID: row.movementID)
        try await f.model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 9, missedGoalReason: .effortLimit))
        try await f.model.advanceRest()
        try await f.model.recordSet(movementID: row.movementID, index: 1, actual: ActualSet(reps: 10))
        try await f.model.advanceRest()
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: store, scratchStoreID: "real")
        model.reviewStep = .set(movementID: row.movementID, index: 0)
        return (f, model, row.movementID)
    }
    @Test func delayedCorrectionOpenerCannotAdoptAfterNavigationClearingOrCancellation() async throws {
        for scenario in ["working", "other correction", "cleared", "cancelled", "obsolete error"] {
            let url = directory(), store = WorkoutScratchStore(directory: url)
            let (f, model, id) = try await recordedCorrectionFixture(store: store)
            let before = model.snapshot, delay = ScratchNavigationDelay()
            await store.setBeforeLoadForTesting { await delay.holdFirst() }
            let opening = Task { await model.openCorrectionEntry(movementID: id, index: 0) }
            await delay.waitUntilEntered()
            switch scenario {
            case "working", "obsolete error":
                model.reviewStep = nil
                #expect(model.visibleStep == .set(movementID: id, index: 2))
            case "other correction":
                model.reviewStep = .set(movementID: id, index: 1)
                #expect(await model.openCorrectionEntry(movementID: id, index: 1))
            case "cleared":
                model.entryDraft = SetEntryDraft(reps: "edited", reason: .timeInterruption)
                model.entryDraft = SetEntryDraft()
            default: opening.cancel()
            }
            if scenario == "obsolete error" {
                try await model.flushScratch() // Finish the new context's invalidation before load-only corruption.
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let draftID = try #require(model.snapshot.draft?.id)
                try Data("invalid scratch".utf8).write(to: url.appendingPathComponent(draftID.uuidString.lowercased() + ".json"))
            }
            let expected = model.entryDraft
            await delay.release()
            #expect(await opening.value == false, "Obsolete opener: \(scenario)")
            #expect(model.entryDraft == expected, "No old recorded actuals/reason: \(scenario)")
            #expect(model.errorText == nil, "No obsolete opener error: \(scenario)")
            #expect(model.snapshot == before)
            #expect(try await f.repository.snapshot(programID: model.programID) == before)
            await f.repository.close()
        }
    }
    @Test func delayedDismissCannotReplaceSameOwnerReopenedInputOrNavigation() async throws {
        for fails in [false, true] {
            for action in ["reopen", "edit", "back", "resume"] {
                let url = directory(), store = WorkoutScratchStore(directory: url)
                let (f, model, id) = try await recordedCorrectionFixture(store: store)
                let navigation = WorkoutReviewNavigation(model: model)
                navigation.path = [.summary(id), .correction(id, 0)]
                model.entryDraft = SetEntryDraft(reps: "dismissed text", reason: .effortLimit)
                try await model.flushScratch()
                let before = model.snapshot, delay = ScratchNavigationDelay()
                await store.setBeforeSaveForTesting { await delay.holdFirst() }
                var shown = false, restored = false
                let dismissal = Task { await navigation.dismissed(isCurrentOwner: { true }, restorePresentation: { shown = true; restored = true }) }
                await delay.waitUntilEntered()
                shown = true
                navigation.presentationReopened() // Same retained coordinator's new presentation.
                if action == "edit" { model.entryDraft = SetEntryDraft(reps: "new resumed text", reason: .timeInterruption) }
                if action == "back" {
                    let old = navigation.path
                    navigation.path.removeLast()
                    await navigation.nativeBack(from: old, to: navigation.path)
                }
                if action == "resume" {
                    try await model.resumeGuidedWorkout()
                    navigation.clearReview()
                    try await navigation.push(.summary(id))
                    try await navigation.push(.correction(id, 1))
                    #expect(await model.openCorrectionEntry(movementID: id, index: 1))
                    model.entryDraft = SetEntryDraft(reps: "resumed different correction")
                    try await model.flushScratch()
                }
                let expectedEntry = model.entryDraft, expectedStep = model.visibleStep, expectedPath = navigation.path
                if fails {
                    try FileManager.default.removeItem(at: url)
                    try Data("file instead of directory".utf8).write(to: url)
                }
                await delay.release(); await dismissal.value
                #expect(shown && !restored, "Old dismissal must not restore: \(fails)/\(action)")
                #expect(navigation.path == expectedPath && model.visibleStep == expectedStep)
                #expect(model.entryDraft == expectedEntry)
                #expect(!navigation.retainsCorrectionEntry)
                #expect(model.snapshot == before)
                #expect(try await f.repository.snapshot(programID: model.programID) == before)
                await f.repository.close()
            }
        }
    }

    @Test func correctionOpeningPreservesSavedBlankAndCancelledRestoration() async throws {
        let store = WorkoutScratchStore(directory: directory())
        let (f, model, id) = try await recordedCorrectionFixture(store: store)
        let before = model.snapshot
        #expect(await model.openCorrectionEntry(movementID: id, index: 0))
        #expect(model.entryDraft == SetEntryDraft(reps: "9", reason: .effortLimit))
        model.entryDraft = SetEntryDraft()
        try await model.flushScratch()
        #expect(await model.openCorrectionEntry(movementID: id, index: 0))
        #expect(model.entryDraft == SetEntryDraft(), "Persisted deliberate blank is input intent")
        model.entryDraft = SetEntryDraft(reps: "saved correction")
        try await model.flushScratch()
        let other = WorkoutViewModel(repository: f.repository, snapshot: before, timeZoneID: model.timeZoneID,
            now: model.now, scratchStore: store, scratchStoreID: "real")
        other.reviewStep = .set(movementID: id, index: 0)
        let delay = ScratchNavigationDelay()
        await store.setBeforeLoadForTesting { await delay.holdFirst() }
        let opening = Task { await other.openCorrectionEntry(movementID: id, index: 0) }
        await delay.waitUntilEntered(); opening.cancel(); await delay.release()
        #expect(await opening.value == false)
        #expect(other.entryDraft == SetEntryDraft() && other.errorText == nil)
        #expect(other.snapshot == before && model.snapshot == before)
        await f.repository.close()
    }
    @Test func delayedDismissInputRevisionPreservesClearedIntentWithoutReopening() async throws {
        for fails in [false, true] {
            let url = directory(), store = WorkoutScratchStore(directory: url)
            let (f, model, id) = try await recordedCorrectionFixture(store: store)
            let navigation = WorkoutReviewNavigation(model: model)
            navigation.path = [.summary(id), .correction(id, 0)]
            model.entryDraft.reps = "pre-dismiss input"
            try await model.flushScratch()
            let delay = ScratchNavigationDelay(), before = model.snapshot, expectedPath = navigation.path
            await store.setBeforeSaveForTesting { await delay.holdFirst() }
            let attempt = navigation.beginDismissal()
            var restored = false
            let dismissal = Task { await navigation.dismissed(attempt: attempt, isCurrentOwner: { true }, restorePresentation: { restored = true }) }
            await delay.waitUntilEntered()
            model.entryDraft.reps = "new intent"
            model.entryDraft = SetEntryDraft()
            try await model.flushScratch()
            if fails {
                try FileManager.default.removeItem(at: url)
                try Data("file instead of directory".utf8).write(to: url)
            }
            await delay.release(); await dismissal.value
            #expect(!restored && !navigation.retainsCorrectionEntry)
            #expect(navigation.path == expectedPath && model.reviewStep == .set(movementID: id, index: 0))
            #expect(model.entryDraft == SetEntryDraft() && model.errorText == nil)
            #expect(model.snapshot == before)
            await f.repository.close()
        }
    }
    @Test func delayedDismissBindingReopenRejectsCallbackBeforePresentationNotification() async throws {
        for fails in [false, true] {
            let url = directory(), store = WorkoutScratchStore(directory: url)
            let (f, model, id) = try await recordedCorrectionFixture(store: store)
            let navigation = WorkoutReviewNavigation(model: model)
            navigation.path = [.summary(id), .correction(id, 0)]
            model.entryDraft.reps = "retained correction"
            try await model.flushScratch()
            let expected = model.entryDraft, expectedPath = navigation.path, before = model.snapshot
            let delay = ScratchNavigationDelay()
            await store.setBeforeSaveForTesting { await delay.holdFirst() }
            let attempt = navigation.beginDismissal() // Same synchronous capture as the sheet binding.
            var shown = false, restored = false
            let dismissal = Task {
                await navigation.dismissed(attempt: attempt, isCurrentOwner: { true }, isStillDismissed: { !shown }, restorePresentation: { shown = true; restored = true })
            }
            await delay.waitUntilEntered()
            shown = true // Reopened binding; SwiftUI's presentationReopened notification has not run.
            if fails {
                try FileManager.default.removeItem(at: url)
                try Data("file instead of directory".utf8).write(to: url)
            }
            await delay.release(); await dismissal.value
            #expect(shown && !restored && !navigation.retainsCorrectionEntry)
            #expect(navigation.path == expectedPath && model.entryDraft == expected)
            #expect(model.reviewStep == .set(movementID: id, index: 0) && model.snapshot == before)
            await f.repository.close()
        }
    }
    @Test func sameOwnerResumeAlignsOnlyStalePathAndPreservesForwardInput() async throws {
        for fails in [false, true] {
            let url = directory(), store = WorkoutScratchStore(directory: url)
            let (f, model, id) = try await recordedCorrectionFixture(store: store)
            let navigation = WorkoutReviewNavigation(model: model)
            let old: [WorkoutReviewRoute] = [.summary(id), .correction(id, 0)]
            navigation.path = old
            model.entryDraft.reps = "old correction"
            try await model.flushScratch()
            let delay = ScratchNavigationDelay(), before = model.snapshot
            await store.setBeforeSaveForTesting { await delay.holdFirst() }
            var shown = false, restored = false
            let attempt = navigation.beginDismissal()
            let dismissal = Task { await navigation.dismissed(attempt: attempt, isCurrentOwner: { true }, isStillDismissed: { !shown }, restorePresentation: { shown = true; restored = true }) }
            await delay.waitUntilEntered()
            try await model.resumeGuidedWorkout()
            #expect(model.reviewStep == nil && model.visibleStep == .set(movementID: id, index: 2))
            model.entryDraft.reps = "new forward input"
            try await model.flushScratch()
            let forwardEntry = model.entryDraft
            shown = true; navigation.presentationReopened()
            #expect(navigation.path.isEmpty && !navigation.retainsCorrectionEntry)
            #expect(!navigation.ownsNativeBack(from: old))
            #expect(model.entryDraft == forwardEntry)
            if fails {
                try FileManager.default.removeItem(at: url)
                try Data("file instead of directory".utf8).write(to: url)
                // SwiftUI may observe this programmatic path change after presentation.
                await navigation.nativeBack(from: old, to: [])
                #expect(navigation.path.isEmpty && model.reviewStep == nil)
                #expect(model.entryDraft == forwardEntry)
            }
            await delay.release(); await dismissal.value
            #expect(shown && !restored && navigation.path.isEmpty)
            #expect(model.reviewStep == nil && model.entryDraft == forwardEntry && model.snapshot == before)
            #expect(try await f.repository.snapshot(programID: model.programID) == before)
            await f.repository.close()
        }
    }
    @Test func correctionSaveReturnsToUnconfirmedForwardSummaryWithoutReplay() async throws {
        let store = WorkoutScratchStore(directory: directory())
        let (f, model, id) = try await recordedCorrectionFixture(store: store)
        model.reviewStep = nil
        try await model.recordSet(movementID: id, index: 2, actual: ActualSet(reps: 10))
        #expect(model.visibleStep == .summary(movementID: id))
        let issued = model.snapshot.draft!.displayed, history = model.snapshot.history
        let navigation = WorkoutReviewNavigation(model: model)
        try await navigation.push(.correction(id, 0))
        model.entryDraft.reps = "10"
        try await model.correctSet(movementID: id, index: 0, replacement: ActualSet(reps: 10), operationID: UUID())
        #expect(model.reviewStep == .summary(movementID: id))
        let old = navigation.path
        navigation.path.removeLast() // The correction Save callback, followed by native path observation.
        #expect(navigation.ownsNativeBack(from: old))
        await navigation.nativeBack(from: old, to: navigation.path)
        #expect(navigation.path.isEmpty && model.reviewStep == nil)
        #expect(model.visibleStep == .summary(movementID: id))
        #expect(model.log(for: id)?.actualSets.map { $0.reps } == [10, 10, 10])
        #expect(model.snapshot.draft?.displayed == issued && model.snapshot.history == history)
        try await model.confirmMovementSummary(movementID: id, effort: .unknown, status: .completed, reviewing: false)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(id) == true)
        #expect(model.log(for: id)?.actualSets.count == 3 && model.log(for: id)?.status == .completed)
        #expect(model.snapshot.draft?.displayed == issued && model.snapshot.history == history)
        #expect(try await f.repository.snapshot(programID: model.programID) == model.snapshot)
        await f.repository.close()
    }

    @Test func nativeBackFlushFailureRestoresPageTextAndDurableCursor() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let broken = directory()
        try Data("file instead of directory".utf8).write(to: broken)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: WorkoutScratchStore(directory: broken), scratchStoreID: "broken")
        let id = model.snapshot.draft!.logs[0].movementID
        model.reviewStep = .set(movementID: id, index: 0)
        model.entryDraft.reps = "unfinished correction"
        let before = model.snapshot
        let navigation = WorkoutReviewNavigation(model: model)
        let old: [WorkoutReviewRoute] = [.summary(id), .correction(id, 0)]
        let popped: [WorkoutReviewRoute] = [.summary(id)]
        navigation.path = popped
        await navigation.nativeBack(from: old, to: popped)
        #expect(navigation.path == old)
        #expect(model.visibleStep == .set(movementID: id, index: 0))
        #expect(model.entryDraft.reps == "unfinished correction")
        #expect(model.errorText?.contains("Retry Back") == true)
        #expect(model.snapshot == before)
        #expect(try await f.repository.snapshot(programID: model.programID) == before)
        model.operations.contextEnabled = false
        navigation.path = popped
        await navigation.nativeBack(from: old, to: popped)
        #expect(navigation.path == popped && model.entryDraft.reps == "unfinished correction")
        await f.repository.close()
    }

    @Test func failedSheetDismissRetainsCorrectionPageTextAndIgnoresObsoleteOwner() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        let load = try #require(f.model.movement(for: row).availableLoads.first)
        try await f.model.confirmLoad(movementID: row.movementID, load: load)
        try await f.model.beginMovement(movementID: row.movementID)
        let performed = row.sets[0].targetReps ?? 8
        try await f.model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: performed))
        let broken = directory()
        try Data("file instead of directory".utf8).write(to: broken)
        let model = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: f.model.now, scratchStore: WorkoutScratchStore(directory: broken), scratchStoreID: "broken")
        let id = model.snapshot.draft!.logs[0].movementID
        let navigation = WorkoutReviewNavigation(model: model)
        let route: [WorkoutReviewRoute] = [.summary(id), .correction(id, 0)]
        navigation.path = route
        model.reviewStep = .set(movementID: id, index: 0)
        model.entryDraft = SetEntryDraft(reps: "unfinished correction", reason: .effortLimit)
        let before = model.snapshot
        var shown = false
        navigation.invalidate() // The presented view disappeared; its container keeps this coordinator.
        await navigation.dismissed(isCurrentOwner: { true }, restorePresentation: { shown = true })
        navigation.presentationReopened()
        #expect(shown && navigation.path == route && navigation.retainsCorrectionEntry)
        #expect(model.visibleStep == .set(movementID: id, index: 0))
        #expect(model.entryDraft == SetEntryDraft(reps: "unfinished correction", reason: .effortLimit))
        #expect(model.errorText?.contains("Retry closing") == true)
        let reopened = try await f.repository.snapshot(programID: model.programID)
        #expect(model.snapshot == before && reopened == before)
        shown = false
        await navigation.dismissed(isCurrentOwner: { false }, restorePresentation: { shown = true })
        #expect(!shown && navigation.path == route && model.entryDraft.reps == "unfinished correction")
        model.entryDraft = SetEntryDraft()
        await navigation.dismissed(isCurrentOwner: { true }, restorePresentation: { shown = true })
        #expect(shown && navigation.retainsCorrectionEntry && model.entryDraft == SetEntryDraft())
        #expect(model.log(for: id)?.actualSets.first?.reps == performed && model.snapshot == before)
        shown = false
        model.operations.contextEnabled = false
        await navigation.dismissed(isCurrentOwner: { true }, restorePresentation: { shown = true })
        #expect(!shown && model.entryDraft == SetEntryDraft() && navigation.path == route)
        await f.repository.close()
    }

}

private final class ScratchCommitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func observe(_ stage: String) { lock.lock(); defer { lock.unlock() }; if stage == "before_save" { value += 1 } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private actor ScratchNavigationDelay {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func holdFirst() async {
        guard !entered else { return }
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
