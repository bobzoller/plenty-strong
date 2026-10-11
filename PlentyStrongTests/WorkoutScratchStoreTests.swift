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
