import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@Suite(.serialized) @MainActor struct CloudRecoveryLifecycleTests {
    private func composition(_ s: RepositoryScenario, provider: FakeCloudAccountProvider? = nil, now: Date = Date(timeIntervalSince1970: 1791144000)) async throws -> (AppComposition, WorkoutViewModel, CloudSyncCoordinator) {
        let account = provider ?? FakeCloudAccountProvider(recoveryScope)
        let server = FakeCloudServer()
        let transport = FakeCloudTransport(repository: s.repository, accountProvider: account, server: server)
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: account, makeTransport: { transport })
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { now })
        let app = AppComposition(repository: s.repository, workout: model, cloudCoordinator: coordinator)
        app.now = model.now; return (app, model, coordinator)
    }
    private func settle(_ app: AppComposition) async throws {
        for _ in 0..<500 { if !app.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Recovery gate did not settle")
    }
    @Test func completedUploadCountRequiresAllArchivesAndAncestors() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let records = try await recoveryRecords(s.repository)
        let event = try #require(records.first { (try? JSONDecoder().decode(JournalEnvelope.self, from: $0.rawCanonicalBytes)).map { CloudRecordCodec.isWorkout($0.command) } == true })
        try await s.repository.acceptCloudSaveObservation(event.observation, scope: recoveryScope)
        let partial = try await s.repository.cloudStatus(scope: recoveryScope)
        #expect(partial.pendingCompletedWorkoutCount == 1)
        #expect(partial.acknowledgedCompletedWorkoutCount == 0)
        #expect(partial.pendingRecordCount > 0)
        for record in records { try await s.repository.acceptCloudSaveObservation(record.observation, scope: recoveryScope) }
        let complete = try await s.repository.cloudStatus(scope: recoveryScope)
        #expect(complete.pendingCompletedWorkoutCount == 0)
        #expect(complete.acknowledgedCompletedWorkoutCount == 1)
        #expect(complete.lastRecordAcknowledgement != nil)
    }
    @Test func missingAccountAndDisablePreserveLocalProgramAndDraft() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (app, model, _) = try await composition(s, provider: FakeCloudAccountProvider(nil))
        try await model.start(easierToday: false)
        let before = try await s.repository.exportBackup()
        await app.setCloudRecoveryEnabled(true)
        #expect(app.cloudStatus.phase == .accountUnavailable)
        #expect(app.cloudStatus.retryReason?.contains("iOS Settings") == true)
        await app.setCloudRecoveryEnabled(false)
        #expect(try await s.repository.exportBackup() == before)
        #expect(app.workout === model)
    }
    @Test func separateCurrentAccountProgramNeverReusesOldDataset() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let old = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: old.datasetID)!, to: recoveryScope)
        let nextAccount = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        let (app, _, _) = try await composition(s, provider: FakeCloudAccountProvider(nextAccount))
        await app.setCloudRecoveryEnabled(true)
        #expect(app.cloudStatus.phase == .accountUnavailable)
        try await app.createSeparateCloudProgram(goal: .maintenance)
        let roots = try await app.recoveryProof().envelopes.values.filter { $0.parentEnvelopeHash == nil }
        #expect(roots.count == 2)
        #expect(Set(roots.map(\.datasetID)).count == 2)
        let newRoot = try #require(roots.first { $0.programID != s.programID.uuidString.lowercased() })
        #expect(try await s.repository.datasetAssociation(UUID(uuidString: newRoot.datasetID)!) == nextAccount.key)
        #expect(try await s.repository.pendingCloudRecords(scope: recoveryScope).count == 4)
        #expect(try await s.repository.datasetAssociation(UUID(uuidString: old.datasetID)!) == recoveryScope.key)
        #expect(try await s.repository.pendingCloudRecords(scope: nextAccount).allSatisfy { $0.datasetID.uuidString.lowercased() != old.datasetID })
    }
    @Test func explicitRootChoiceRetainsOtherRootAndInactiveDraft() async throws {
        let a = try await RepositoryTestHarness.make(goal: .size)
        let b = try await RepositoryTestHarness.make(goal: .strength)
        var draft = try await b.draft(); draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        try await b.repository.saveDraft(draft)
        _ = try await CloudIngestor(repository: b.repository).ingest(recoveryRecords(b.repository), scope: recoveryScope)
        _ = try await a.repository.importBackup(b.repository.exportBackup())
        let (app, _, _) = try await composition(a)
        let all = try await a.repository.exportBackup()
        try await app.selectRecoveryProgram(b.programID.uuidString.lowercased())
        #expect(app.workout?.snapshot.draft == draft)
        #expect(try await a.repository.exportBackup() == all)
        await #expect(throws: (any Error).self) { try await app.selectRecoveryProgram(a.programID.uuidString.lowercased()) }
        #expect(try await a.repository.exportBackup() == all)
    }
    @Test func stagedPainDraftCompletesBeforeBranchHealthAdoption() async throws {
        let local = try await RepositoryTestHarness.make(goal: .size)
        let (remote, _) = try recoveryEmpty()
        _ = try await remote.importBackup(local.repository.exportBackup())
        _ = try await remote.finalize(programID: local.programID, expectedRevision: 0, event: local.firstEvent, next: local.next)
        let incoming = try await recoveryRecords(remote)
        let (app, model, _) = try await composition(local)
        try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.recordProblem(movementID: row.movementID, problem: .pain)
        for row in model.snapshot.draft!.displayed.exercises where !model.handled(row.movementID) { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let before = model.snapshot
        await app.setCloudRecoveryEnabled(true)
        try await local.repository.retainCloudObservations(incoming.map(\.observation), scope: recoveryScope)
        await app.cloudRecordsChanged(recoveryScope); try await settle(app)
        #expect(app.cloudStatus.phase == .incomplete)
        #expect(model.snapshot == before)
        #expect(model.snapshot.health == .ready)
        _ = try await model.finish(); try await settle(app)
        #expect(app.workout === model)
        #expect(model.snapshot.draft == nil)
        #expect(model.snapshot.health == .integrityConflict)
        #expect(model.snapshot.history.filter { CloudRecordCodec.isWorkout($0.command) }.count == 2)
        #expect(model.snapshot.state.baseSafety?[row.baseMovementID ?? row.movementID]?.paused == true)
        await #expect(throws: (any Error).self) { try await model.start(easierToday: false) }
    }
    @Test func wrongAccountCallbacksDoNotIngestOldScope() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let (app, model, _) = try await composition(s, provider: provider)
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        let before = try await s.repository.exportBackup()
        await provider.set(CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .production, accountIdentifier: "synthetic-B"))
        await app.cloudRecordsChanged(recoveryScope); try await settle(app)
        #expect(try await s.repository.exportBackup() == before)
        #expect(app.workout === model)
        #expect(app.cloudStatus.phase == .accountUnavailable)
    }
}

extension CloudRecoveryLifecycleTests {
    @Test func invalidSavedRootChoiceRequiresExplicitMultipleRootSelectionAndRestartPreservesChoice() async throws {
        let a = try await RepositoryTestHarness.make(goal: .size), b = try await RepositoryTestHarness.make(goal: .strength)
        _ = try await CloudIngestor(repository: b.repository).ingest(recoveryRecords(b.repository), scope: recoveryScope)
        _ = try await a.repository.importBackup(b.repository.exportBackup())
        let url = a.storeURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
        try JSONEncoder().encode(CloudRecoveryPreferences(enabled: false, activeProgramID: UUID().uuidString.lowercased())).write(to: url)
        let app = AppComposition(repository: a.repository, preferencesURL: url)
        try await app.reloadLocalProductChoices()
        #expect(app.workout == nil)
        #expect(app.recoveryPrograms.count == 2)
        try await app.selectRecoveryProgram(b.programID.uuidString.lowercased())
        let restart = AppComposition(repository: a.repository, preferencesURL: url)
        try await restart.reloadLocalProductChoices()
        #expect(restart.workout?.programID == b.programID)
        #expect(try await a.repository.exportBackup().heads.count == 2)
    }
    @Test func verifiedReceivedRootAssociatesWithoutSynthesizingOutboxOrAcknowledgements() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(s.repository)
        let (downloaded, _) = try recoveryEmpty()
        _ = try await CloudIngestor(repository: downloaded).ingest(records, scope: recoveryScope)
        let dataset = UUID(uuidString: try await s.repository.exportBackup().datasetID)!
        let before = try await downloaded.exportBackup()
        try await downloaded.bindDataset(datasetID: dataset, to: recoveryScope)
        #expect(try await downloaded.pendingCloudRecords(scope: recoveryScope).isEmpty)
        #expect(try await downloaded.cloudMetadata(scope: recoveryScope).acknowledgements.isEmpty)
        #expect(try await downloaded.exportBackup() == before)
        let other = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        await #expect(throws: (any Error).self) { try await downloaded.bindDataset(datasetID: dataset, to: other) }
        let (portable, _) = try recoveryEmpty()
        _ = try await portable.importBackup(before)
        try await portable.bindDataset(datasetID: dataset, to: other)
        #expect(try await portable.pendingCloudRecords(scope: other).isEmpty)
        #expect(try await portable.cloudMetadata(scope: other).acknowledgements.isEmpty)
        await #expect(throws: (any Error).self) { try await portable.bindDataset(datasetID: UUID(), to: other) }
    }
}

private actor SDKCallbackRecoveryTransport: CloudTransport {
    let adapter: CloudKitTransport
    init(repository: TrainingRepository, provider: any CloudAccountProvider) {
        adapter = CloudKitTransport(testingScope: recoveryScope, accountProvider: provider, repository: repository)
    }
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async { await adapter.setUpdateHandler(handler) }
    func start(scope: CloudScope) {}
    func requestSync() {}
    func stop() async { await adapter.stop() }
    func syncStatus() async -> SyncStatus { await adapter.syncStatus() }
    func discoverRecoveryCandidates(scope: CloudScope) -> [RecoveryCandidate] { [] }
    func deliver(_ records: [DownloadedCloudRecord]) async {
        await adapter.deliverCallbackForTesting(.fetched(records.map(\.observation), deletedRecordIDs: []))
    }
}
extension CloudRecoveryLifecycleTests {
    private func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Expected lifecycle state did not arrive: \(label)")
    }
    @Test func productionCallbackStagesAcrossRestartAndAppliesAfterTruthfulFinish() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(s.repository.exportBackup())
        _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let incoming = try await recoveryRecords(other)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let transport = SDKCallbackRecoveryTransport(repository: s.repository, provider: provider)
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: provider, makeTransport: { transport })
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791144000) })
        let app = AppComposition(repository: s.repository, workout: model, cloudCoordinator: coordinator)
        await coordinator.setUpdateHandler { [weak app] scope in await app?.cloudRecordsChanged(scope) }
        try await model.start(easierToday: false)
        let first = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.recordProblem(movementID: first.movementID, problem: .pain)
        for row in model.snapshot.draft!.displayed.exercises where !model.handled(row.movementID) { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let original = model.snapshot
        await app.setCloudRecoveryEnabled(true)
        await transport.deliver(incoming)
        try await waitFor("initial protected staging disclosure") { app.cloudStatus.retryReason?.contains("all saved workouts") == true }
        #expect(model.snapshot == original)
        #expect(try await s.repository.cloudMetadata(scope: recoveryScope).observations.count == incoming.count)
        await app.setCloudRecoveryEnabled(false)
        let reopened = try await s.reopened()
        let restartedModel = WorkoutViewModel(repository: reopened, snapshot: try await reopened.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: model.now)
        #expect(restartedModel.snapshot == original)
        let replacement = SDKCallbackRecoveryTransport(repository: reopened, provider: provider)
        let restoredCoordinator = CloudSyncCoordinator(repository: reopened, accountProvider: provider, makeTransport: { replacement })
        let restartedApp = AppComposition(repository: reopened, workout: restartedModel, cloudCoordinator: restoredCoordinator)
        await restartedApp.setCloudRecoveryEnabled(true)
        try await waitFor("restart protected staging disclosure") { restartedApp.cloudStatus.retryReason?.contains("all saved workouts") == true }
        #expect(restartedModel.snapshot == original)
        try await settle(restartedApp)
        _ = try await restartedModel.finish()
        try await waitFor("post-Finish authoritative conflict") { restartedModel.snapshot.health == .integrityConflict }
        #expect(restartedApp.workout === restartedModel)
        #expect(restartedModel.snapshot.draft == nil)
        #expect(restartedModel.snapshot.history.filter { CloudRecordCodec.isWorkout($0.command) }.count == 2)
        #expect(restartedModel.snapshot.state.baseSafety?[first.baseMovementID ?? first.movementID]?.paused == true)
    }
    @Test func disabledGenerationDoesNotAdoptQueuedIncomingObservations() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let (app, model, _) = try await composition(s, provider: provider)
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        let before = model.snapshot
        let gate = model.operations
        try await gate.perform { _ in
            await app.cloudRecordsChanged(recoveryScope)
            await app.setCloudRecoveryEnabled(false)
        }
        try await settle(app)
        #expect(model.snapshot == before)
        #expect(app.cloudStatus.phase == .localOnly)
    }
    @Test func rawUnsupportedClaimCannotAssociateDatasetWithoutVerifiedRoot() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(s.repository)
        let root = try #require(records.first { $0.observation.recordType == "JournalV1" })
        var fields = try #require(try JSONSerialization.jsonObject(with: root.rawCanonicalBytes) as? [String: Any]); fields["schemaVersion"] = 99
        let bytes = try CloudRecordCodec.canonicalBytes(JSONSerialization.data(withJSONObject: fields))
        let invalid = DownloadedCloudRecord(observation: CloudObservation(recordID: root.recordID, zoneName: root.observation.zoneName, recordType: "JournalV1", claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        let (fresh, _) = try recoveryEmpty()
        _ = try await CloudIngestor(repository: fresh).ingest([invalid], scope: recoveryScope)
        let dataset = UUID(uuidString: try await s.repository.exportBackup().datasetID)!
        await #expect(throws: (any Error).self) { try await fresh.bindDataset(datasetID: dataset, to: recoveryScope) }
        #expect(try await fresh.pendingCloudRecords(scope: recoveryScope).isEmpty)
        #expect(try await fresh.cloudMetadata(scope: recoveryScope).acknowledgements.isEmpty)
    }
}

extension CloudRecoveryLifecycleTests {
    @Test func accountVerificationWaitNeverOwnsTrainingGate() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let provider = ThrowingCloudAccountProvider(recoveryScope)
        let transport = SDKCallbackRecoveryTransport(repository: s.repository, provider: provider)
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: provider, makeTransport: { transport })
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791144000) })
        let app = AppComposition(repository: s.repository, workout: model, cloudCoordinator: coordinator)
        await app.setCloudRecoveryEnabled(true)
        try await model.start(easierToday: false)
        let clock = ControlledCloudRetryClock()
        await provider.blockNextVerification(clock)
        let service = Task { await app.cloudRecordsChanged(recoveryScope) }
        for _ in 0..<500 { if await clock.sleeperCount() == 1 { break }; await Task.yield() }
        #expect(await clock.sleeperCount() == 1)
        #expect(!app.busy)
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.recordProblem(movementID: row.movementID, problem: .pain)
        #expect(model.snapshot.draft?.logs.first?.problem == .pain)
        let protected = try await s.repository.exportBackup()
        await app.setCloudRecoveryEnabled(false)
        await clock.advance(); await service.value
        #expect(app.cloudStatus.phase == .localOnly)
        #expect(try await s.repository.exportBackup() == protected)
    }
    @Test func backgroundAccountChangeInvalidatesDeferredDraftScope() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(s.repository.exportBackup())
        _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let (app, model, _) = try await composition(s, provider: provider)
        try await model.start(easierToday: false)
        for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        await app.setCloudRecoveryEnabled(true)
        try await s.repository.retainCloudObservations(recoveryRecords(other).map(\.observation), scope: recoveryScope)
        await app.cloudRecordsChanged(recoveryScope); try await settle(app)
        await app.pauseRecoveryForBackground()
        await provider.set(CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B"))
        _ = try await model.finish(); try await settle(app)
        #expect(model.snapshot.health == .ready)
        #expect(model.snapshot.history.filter { CloudRecordCodec.isWorkout($0.command) }.count == 1)
        #expect(try await s.repository.cloudMetadata(scope: recoveryScope).observations.count > 0)
        await app.retryCloudRecovery()
        #expect(app.cloudStatus.phase == .accountUnavailable)
        #expect(model.snapshot.health == .ready)
    }
    @Test func resolutionWrapperIsRequiredForCompletedRecoveryCount() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(s.repository.exportBackup())
        var pain = s.firstEvent; pain.exercises[0].problem = .pain
        _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: pain, next: s.next)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        _ = try await recoveryRecords(s.repository)
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await s.repository.exportBackup()))
        let heads = try #require(proof.heads[s.programID.uuidString.lowercased()])
        let clean = try #require(proof.envelopes.values.first { CloudRecordCodec.isWorkout($0.command) && $0.returnedState.baseSafety?[pain.exercises[0].baseMovementID!]!.paused == false })
        _ = try await s.repository.resolveConflict(programID: s.programID, expectedHeadHashes: heads, selection: BranchSelection(selectedHeadHash: clean.envelopeHash, reviewedQuarantineChecksums: proof.quarantined.map { BackupService.hash($0.record.bytes) }), next: s.next)
        let pending = try await s.repository.pendingCloudRecords(scope: recoveryScope)
        let cleanBytes = try BackupService.bytes(clean)
        let wrapper = try #require(pending.first { (try? JSONDecoder().decode(CausalOriginalArchive.self, from: $0.payload))?.record.bytes == cleanBytes })
        let occupied = try await s.repository.cloudMetadata(scope: recoveryScope).conflictingRecordIDs
        for record in pending where record.recordID != wrapper.recordID && !occupied.contains(record.recordID) {
            try await s.repository.acceptCloudSaveObservation(CloudObservation(recordID: record.recordID, zoneName: CloudRecordCodec.zoneID(record.datasetID).zoneName, recordType: record.kind.recordType, claimedChecksum: record.checksum, payload: record.payload, systemFields: Data()), scope: recoveryScope)
        }
        #expect(try await s.repository.cloudStatus(scope: recoveryScope).pendingCompletedWorkoutCount == 2)
        try await s.repository.acceptCloudSaveObservation(CloudObservation(recordID: wrapper.recordID, zoneName: CloudRecordCodec.zoneID(wrapper.datasetID).zoneName, recordType: wrapper.kind.recordType, claimedChecksum: wrapper.checksum, payload: wrapper.payload, systemFields: Data()), scope: recoveryScope)
        #expect(try await s.repository.cloudStatus(scope: recoveryScope).pendingCompletedWorkoutCount == 0)
        #expect(try await s.repository.cloudStatus(scope: recoveryScope).acknowledgedCompletedWorkoutCount == 2)
        #expect(try await s.repository.cloudStatus(scope: recoveryScope).phase == .conflict)
    }
}

extension CloudRecoveryLifecycleTests {
    @Test func stagedOriginalsExportIsLosslessMetadataFreeAndReadOnly() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(s.repository.exportBackup())
        _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let records = try await recoveryRecords(other)
        var originals = records.map(\.observation)
        let event = try #require(originals.first { (try? JSONDecoder().decode(JournalEnvelope.self, from: $0.payload)).map { CloudRecordCodec.isWorkout($0.command) } == true })
        originals.append(CloudObservation(recordID: event.recordID, zoneName: event.zoneName, recordType: event.recordType, claimedChecksum: "wrong", payload: event.payload + Data([0]), systemFields: Data("secret-system-fields".utf8)))
        try await s.repository.retainCloudObservations(originals, scope: recoveryScope)
        try await s.repository.saveCloudCursor(Data("secret-cursor".utf8), scope: recoveryScope)
        let before = try await s.repository.exportBackup(), metadata = try await s.repository.cloudMetadata(scope: recoveryScope)
        let app = AppComposition(repository: s.repository)
        let url = try await app.exportStagedOriginalsFile()
        let document = try JSONDecoder().decode(StagedRecoveryOriginalsExport.self, from: Data(contentsOf: url))
        #expect(document.formatVersion == 1)
        #expect(document.artifactKind == "plentystrong-staged-recovery-originals")
        #expect(document.originals.count == 2)
        #expect(Set(document.originals.map(\.bytes)) == Set([event.payload, event.payload + Data([0])]))
        #expect(document.originals.contains { $0.bytes == event.payload + Data([0]) })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(object.keys) == ["formatVersion", "artifactKind", "originals"])
        for descriptor in try #require(object["originals"] as? [[String: Any]]) {
            #expect(Set(descriptor.keys).isSubset(of: ["recordID", "zoneName", "recordType", "claimedChecksum", "bytes"]))
        }
        #expect(try await s.repository.exportBackup() == before)
        let after = try await s.repository.cloudMetadata(scope: recoveryScope)
        #expect(after.cursor == metadata.cursor && Set(after.acknowledgements.keys) == Set(metadata.acknowledgements.keys) && after.observations == metadata.observations)
    }
}

extension CloudRecoveryLifecycleTests {
    @Test(arguments: ["pause", "unresolved", "strict-floor"])
    func newAccountCannotBypassRetainedCurrentSafety(kind: String) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (app, _, _) = try await composition(s)
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        if kind == "pause" {
            var event = s.firstEvent; event.exercises[0].problem = .pain
            _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
        } else if kind == "strict-floor" {
            let movement = try await s.repository.snapshot(programID: s.programID).state.config.movements[0]
            _ = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 0, change: .minimumRir(baseMovementID: movement.id, value: 4), next: s.next)
        } else {
            let root = try await s.repository.exportBackup()
            let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
            var different = s.firstEvent; different.eventID = UUID().uuidString.lowercased()
            _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: different, next: s.next)
            _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
            _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        }
        let before = try await s.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await app.createSeparateCloudProgram(goal: .maintenance) }
        #expect(try await s.repository.exportBackup() == before)
    }
}


extension CloudRecoveryLifecycleTests {
    @Test(arguments: [false, true])
    func portableEmptyQueueRequiresIndependentCurrentScopeEvidence(completedWorkout: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        if completedWorkout { _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next) }
        let records = try await recoveryRecords(s.repository)
        _ = try await CloudIngestor(repository: s.repository).ingest(records, scope: recoveryScope)
        let backup = try await s.repository.exportBackup()
        let (portable, _) = try recoveryEmpty()
        _ = try await portable.importBackup(backup)
        let current = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        try await portable.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: current)
        #expect(try await portable.pendingCloudRecords(scope: current).isEmpty)
        #expect(try await portable.cloudMetadata(scope: current).acknowledgements.isEmpty)
        #expect(try await portable.cloudStatus(scope: current).phase == .incomplete)
        #expect(try await portable.snapshot(programID: s.programID).health == .ready)
        #expect(try await portable.exportBackup() == backup)
        _ = try await CloudIngestor(repository: portable).ingest(records, scope: current)
        let downloaded = try await portable.cloudStatus(scope: current)
        #expect(downloaded.phase == .upToDateForKnownRecords)
        #expect(downloaded.acknowledgedCompletedWorkoutCount == (completedWorkout ? 1 : 0))
        #expect(downloaded.lastRecordAcknowledgement == nil)
        #expect(try await portable.pendingCloudRecords(scope: current).isEmpty)
        #expect(try await portable.cloudMetadata(scope: current).acknowledgements.isEmpty)
    }
}


extension CloudRecoveryLifecycleTests {
    @Test func changedScopeCannotBindAfterSelectedProgramDiscovery() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scopeB = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        let (app, _, coordinator) = try await composition(s, provider: FakeCloudAccountProvider(scopeB))
        let before = try await s.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await coordinator.enable(datasetID: UUID(uuidString: before.datasetID)!, expectedScope: recoveryScope) }
        #expect(try await s.repository.datasetAssociation(UUID(uuidString: before.datasetID)!) == nil)
        #expect(try await s.repository.exportBackup() == before)
        #expect(app.workout != nil)
    }
}

extension CloudRecoveryLifecycleTests {
    @Test func deferredGateProcessesLateArrivalWithoutAnotherTrainingWrite() async throws {
        let gate = TrainingOperationGate()
        let clock = ControlledCloudRetryClock()
        var steps: [String] = []
        gate.whenIdle { lease in
            try! gate.requireOwnership(lease)
            steps.append("first-start")
            await clock.wait(1)
            steps.append("first-end")
        }
        for _ in 0..<500 { if await clock.sleeperCount() == 1 { break }; await Task.yield() }
        #expect(await clock.sleeperCount() == 1)
        #expect(gate.busy)
        gate.whenIdle { lease in
            try! gate.requireOwnership(lease)
            steps.append("late-arrival")
        }
        await #expect(throws: (any Error).self) { try await gate.perform { _ in steps.append("interleaved-write") } }
        await clock.advance()
        try await waitFor("late arrival drained without an unrelated training write") { !gate.busy && steps.last == "late-arrival" }
        #expect(steps == ["first-start", "first-end", "late-arrival"])
    }
}

/// Signals exact optional-service suspension points without elapsed-time guesses.
private actor RecoveryInterleavingCheckpoint {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            release = continuation
            arrival?.resume(); arrival = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

/// Local status/discovery fixture; only external service waits are substituted.
private actor InterleavingRecoveryTransport: CloudTransport {
    let repository: TrainingRepository
    private var scope: CloudScope?
    private var statusCheckpoint: RecoveryInterleavingCheckpoint?
    private var discoveryCheckpoint: RecoveryInterleavingCheckpoint?
    private var syncRequests = 0
    init(repository: TrainingRepository) { self.repository = repository }
    func blockNextStatus(_ checkpoint: RecoveryInterleavingCheckpoint) { statusCheckpoint = checkpoint }
    func blockNextDiscovery(_ checkpoint: RecoveryInterleavingCheckpoint) { discoveryCheckpoint = checkpoint }
    func requestCount() -> Int { syncRequests }
    func start(scope: CloudScope) { self.scope = scope }
    func stop() { scope = nil }
    func requestSync() { syncRequests += 1 }
    func syncStatus() async -> SyncStatus {
        if let checkpoint = statusCheckpoint { statusCheckpoint = nil; await checkpoint.suspend() }
        guard let scope else { return .init() }
        return (try? await repository.cloudStatus(scope: scope)) ?? .init(phase: .incomplete)
    }
    func discoverRecoveryCandidates(scope: CloudScope) async -> [RecoveryCandidate] {
        if let checkpoint = discoveryCheckpoint { discoveryCheckpoint = nil; await checkpoint.suspend() }
        return []
    }
}

private actor InterleavingRecoveryAccount: CloudAccountProvider {
    private var scope: CloudScope?
    private var verificationCount = 0
    private var checkpoint: RecoveryInterleavingCheckpoint?
    init(_ scope: CloudScope?) { self.scope = scope }
    func set(_ scope: CloudScope?) { self.scope = scope }
    func blockCoordinatorAdmission(_ checkpoint: RecoveryInterleavingCheckpoint) {
        verificationCount = 0; self.checkpoint = checkpoint
    }
    func currentScope() async throws -> CloudScope? {
        verificationCount += 1
        // Composition verification, discovery verification, post-discovery
        // verification, then the coordinator's final pre-bind verification.
        if verificationCount == 4, let checkpoint {
            self.checkpoint = nil; await checkpoint.suspend()
        }
        return scope
    }
}

extension CloudRecoveryLifecycleTests {
    @Test(arguments: ["start", "configuration"])
    func rootSelectionCannotStrandFreshIncomingAdoption(operation: String) async throws {
        let a = try await RepositoryTestHarness.make(goal: .size)
        let b = try await RepositoryTestHarness.make(goal: .size)
        let (remote, _) = try recoveryEmpty()
        _ = try await remote.importBackup(b.repository.exportBackup())
        var pain = b.firstEvent; pain.exercises[0].problem = .pain
        _ = try await remote.finalize(programID: b.programID, expectedRevision: 0, event: pain, next: b.next)
        _ = try await b.repository.finalize(programID: b.programID, expectedRevision: 0, event: b.firstEvent, next: b.next)
        // Independent datasets require a verified graph-format portable export;
        // legacy single-dataset import would quarantine this second root.
        _ = try await CloudIngestor(repository: b.repository).ingest(recoveryRecords(b.repository), scope: recoveryScope)
        _ = try await a.repository.importBackup(b.repository.exportBackup())
        #expect(try await a.repository.snapshot(programID: b.programID).health == .ready)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await a.repository.exportBackup()))
        _ = try #require(proof.envelopes.values.first { $0.programID == b.programID.uuidString.lowercased() && $0.parentEnvelopeHash == nil })
        let incoming = try await recoveryRecords(remote)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let transport = InterleavingRecoveryTransport(repository: a.repository)
        let coordinator = CloudSyncCoordinator(repository: a.repository, accountProvider: provider, makeTransport: { transport })
        let currentDate = try #require(ISO8601DateFormatter().date(from: "2026-10-06T22:00:00Z"))
        let modelA = WorkoutViewModel(repository: a.repository, snapshot: try await a.repository.snapshot(programID: a.programID), timeZoneID: "Pacific/Honolulu", now: { currentDate })
        let app = AppComposition(repository: a.repository, workout: modelA, cloudCoordinator: coordinator)
        app.now = { currentDate }; app.timeZoneID = "Pacific/Honolulu"
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        let authoredBefore = try await a.repository.pendingCloudRecords(scope: recoveryScope)
        let acknowledgementsBefore = try await a.repository.cloudMetadata(scope: recoveryScope).acknowledgements
        let datasetB = UUID(uuidString: try await b.repository.exportBackup().datasetID)!
        #expect(try await a.repository.datasetAssociation(datasetB) == nil)
        let initialB = try await a.repository.snapshot(programID: b.programID)
        _ = try #require(initialB.health == .ready && initialB.draft == nil)
        let today = try CalendarContext(timeZoneID: "Pacific/Honolulu").localDate(at: currentDate)
        _ = try #require(initialB.state.activePrescription.date <= today)
        let selectionCheckpoint = RecoveryInterleavingCheckpoint()
        app.selectionBeforeAdoptionForTesting = { await selectionCheckpoint.suspend() }
        let selection = Task { try await app.selectRecoveryProgram(b.programID.uuidString.lowercased()) }
        await selectionCheckpoint.waitUntilEntered()
        #expect(app.busy && app.workout === modelA)
        try await a.repository.retainCloudObservations(incoming.map(\.observation), scope: recoveryScope)
        await app.cloudRecordsChanged(recoveryScope)
        #expect(app.cloudStatus.phase == .incomplete)
        await selectionCheckpoint.resume(); try await selection.value
        app.selectionBeforeAdoptionForTesting = nil
        try await settle(app)
        let modelB = try #require(app.workout)
        #expect(modelB.programID == b.programID && modelB !== modelA)
        // After the queued work drains, incoming authoritative health must
        // block the next write without requiring another lifecycle callback.
        await #expect(throws: (any Error).self) {
            if operation == "start" { try await modelB.start(easierToday: false) }
            else { try await modelB.changeProgram(.goal(.maintenance)) }
        }
        try await settle(app)
        let authoritative = try await a.repository.snapshot(programID: b.programID)
        #expect(authoritative.health == .integrityConflict)
        #expect(modelB.snapshot.health == .integrityConflict)
        #expect(authoritative.draft == nil && modelB.snapshot.draft == nil)
        #expect(authoritative.state.config.goal == .size)
        let originals = authoritative.history.filter { CloudRecordCodec.isWorkout($0.command) }
        #expect(originals.count == 2)
        #expect(originals.contains { envelope in
            guard case let .workout(event, _) = envelope.command else { return false }
            return event == pain && envelope.returnedState.baseSafety?[pain.exercises[0].baseMovementID!]?.paused == true
        })
        #expect(app.cloudStatus.phase == .conflict)
        #expect(app.workout === modelB)
        #expect(try await a.repository.snapshot(programID: a.programID).health == .ready)
        // C2 retains verified received originals' real source association;
        // this is separate from explicit consent to upload authored histories.
        #expect(try await a.repository.datasetAssociation(datasetB) == recoveryScope.key)
        #expect(try await a.repository.pendingCloudRecords(scope: recoveryScope) == authoredBefore)
        #expect(try await a.repository.cloudMetadata(scope: recoveryScope).acknowledgements == acknowledgementsBefore)
    }

    @Test(arguments: ["start", "configuration"])
    func retainedIncomingHealthPrecedesWriteDuringStatusWait(operation: String) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (remote, _) = try recoveryEmpty()
        _ = try await remote.importBackup(s.repository.exportBackup())
        var pain = s.firstEvent; pain.exercises[0].problem = .pain
        _ = try await remote.finalize(programID: s.programID, expectedRevision: 0, event: pain, next: s.next)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let incoming = try await recoveryRecords(remote)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let transport = InterleavingRecoveryTransport(repository: s.repository)
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: provider, makeTransport: { transport })
        let currentDate = try #require(ISO8601DateFormatter().date(from: "2026-10-06T22:00:00Z"))
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { currentDate })
        let app = AppComposition(repository: s.repository, workout: model, cloudCoordinator: coordinator)
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        #expect(model.snapshot.health == .ready && model.snapshot.draft == nil)
        try await s.repository.retainCloudObservations(incoming.map(\.observation), scope: recoveryScope)
        let checkpoint = RecoveryInterleavingCheckpoint()
        await transport.blockNextStatus(checkpoint)
        let callback = Task { await app.cloudRecordsChanged(recoveryScope) }
        await checkpoint.waitUntilEntered()
        // The service remains suspended: the pending local adoption must already
        // own the gate or have published authoritative non-ready health.
        await #expect(throws: (any Error).self) {
            if operation == "start" { try await model.start(easierToday: false) }
            else { try await model.changeProgram(.goal(.maintenance)) }
        }
        try await settle(app)
        #expect(model.snapshot.health == .integrityConflict)
        #expect(model.snapshot.draft == nil)
        #expect(model.snapshot.state.config.goal == .size)
        #expect(model.snapshot.history.filter { CloudRecordCodec.isWorkout($0.command) }.count == 2)
        #expect(model.snapshot.history.contains { envelope in
            guard case let .workout(event, _) = envelope.command else { return false }
            return event == pain && envelope.returnedState.baseSafety?[pain.exercises[0].baseMovementID!]?.paused == true
        })
        #expect(try await s.repository.snapshot(programID: s.programID).health == .integrityConflict)
        await checkpoint.resume(); await callback.value
        #expect(app.workout === model)
        #expect(app.cloudStatus.phase == .conflict)
    }

    @Test(arguments: [false, true], ["discovery", "admission"])
    func associationConsentPinsSelectedRootDuringDiscovery(switchRoot: Bool, suspension: String) async throws {
        let a = try await RepositoryTestHarness.make(goal: .size)
        let configB = try selectFixedProgram(goal: .strength, programID: UUID())
        let date = try LocalDate(iso8601: "2026-10-05")
        _ = try await a.repository.initialize(config: configB, rules: RulesetCatalog.fixedV1(), firstWorkout: WorkoutScheduler.nextSlot(onOrAfter: date, config: configB), datasetID: UUID())
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await a.repository.exportBackup()))
        let rootA = try #require(proof.envelopes.values.first { $0.programID == a.programID.uuidString.lowercased() && $0.parentEnvelopeHash == nil })
        let rootB = try #require(proof.envelopes.values.first { $0.programID == configB.programID && $0.parentEnvelopeHash == nil })
        let provider = InterleavingRecoveryAccount(nil)
        let transport = InterleavingRecoveryTransport(repository: a.repository)
        let coordinator = CloudSyncCoordinator(repository: a.repository, accountProvider: provider, makeTransport: { transport })
        let modelA = WorkoutViewModel(repository: a.repository, snapshot: try await a.repository.snapshot(programID: a.programID), timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791144000) })
        let app = AppComposition(repository: a.repository, workout: modelA, cloudCoordinator: coordinator)
        await app.setCloudRecoveryEnabled(true)
        let before = try await a.repository.exportBackup()
        await provider.set(recoveryScope)
        let checkpoint = RecoveryInterleavingCheckpoint()
        if suspension == "discovery" { await transport.blockNextDiscovery(checkpoint) }
        else { await provider.blockCoordinatorAdmission(checkpoint) }
        let association = Task { await app.associateSelectedProgram() }
        await checkpoint.waitUntilEntered()
        #expect(!app.busy)
        try await app.selectRecoveryProgram(switchRoot ? configB.programID : rootA.programID)
        await checkpoint.resume(); await association.value; try await settle(app)
        if switchRoot {
            #expect(app.workout?.programID == UUID(uuidString: configB.programID))
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootA.datasetID)!) == nil)
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootB.datasetID)!) == nil)
            #expect(try await a.repository.pendingCloudRecords(scope: recoveryScope).isEmpty)
            #expect(await transport.requestCount() == 0)
            // A fresh explicit action targets B and remains usable after cancellation.
            await app.associateSelectedProgram(); try await settle(app)
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootB.datasetID)!) == recoveryScope.key)
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootA.datasetID)!) == nil)
            #expect(try await a.repository.pendingCloudRecords(scope: recoveryScope).allSatisfy { $0.datasetID.uuidString.lowercased() == rootB.datasetID })
        } else {
            #expect(app.workout === modelA)
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootA.datasetID)!) == recoveryScope.key)
            #expect(try await a.repository.datasetAssociation(UUID(uuidString: rootB.datasetID)!) == nil)
            #expect(try await a.repository.pendingCloudRecords(scope: recoveryScope).allSatisfy { $0.datasetID.uuidString.lowercased() == rootA.datasetID })
        }
        #expect(try await a.repository.exportBackup() == before)
        #expect(try await a.repository.cloudMetadata(scope: recoveryScope).acknowledgements.isEmpty)
    }
}


extension CloudRecoveryLifecycleTests {
    @Test(arguments: ["pause", "floor"], [false, true])
    func finalFixCrossRootExposureAdmission(kind: String, inactiveDraft: Bool) async throws {
        let a = try await RepositoryTestHarness.make(goal: .size), b = try await RepositoryTestHarness.make(goal: .size)
        let movement = try await a.repository.snapshot(programID: a.programID).state.config.movements[0]
        if kind == "pause" {
            var pain = a.firstEvent; pain.exercises[0].problem = .pain
            _ = try await a.repository.finalize(programID: a.programID, expectedRevision: 0, event: pain, next: a.next)
        } else {
            _ = try await a.repository.applyConfiguration(programID: a.programID, expectedRevision: 0, change: .minimumRir(baseMovementID: movement.id, value: 4), next: a.next)
        }
        if inactiveDraft {
            var draft = try await b.draft(empty: true)
            draft.logs[0].status = .partial; draft.logs[0].actualSets = [ActualSet(reps: 7)]
            draft.logs[2].problem = .controlLost; draft.logs[2].status = .stopped
            draft.workingSetsStarted = true; draft.acknowledgedMovementIDs = [draft.logs[2].movementID]
            try await b.repository.saveDraft(draft)
        }
        _ = try await CloudIngestor(repository: b.repository).ingest(recoveryRecords(b.repository), scope: recoveryScope)
        _ = try await a.repository.importBackup(b.repository.exportBackup())
        let (app, _, _) = try await composition(a)
        try await app.selectRecoveryProgram(b.programID.uuidString.lowercased())
        let model = try #require(app.workout)
        try await model.start(easierToday: false)
        let draft = try #require(model.snapshot.draft), row = draft.displayed.exercises[0]
        if !inactiveDraft { try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0]) }
        let before = try await a.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await model.recordSet(movementID: row.movementID, index: draft.logs[0].actualSets.count, actual: ActualSet(reps: 8)) }
        #expect(try await a.repository.exportBackup() == before)
        // Truthful partial/stop handling and finalization remain available.
        try await model.recordStatus(movementID: row.movementID, status: inactiveDraft ? .partial : .stopped)
        for other in draft.displayed.exercises.dropFirst() where !model.handled(other.movementID) { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        _ = try await model.finish()
        let saved = try #require(model.snapshot.history.last)
        if case let .workout(event, _) = saved.command {
            #expect(event.exercises[0].actualSets == draft.logs[0].actualSets)
            #expect(event.exercises[2].problem == draft.logs[2].problem)
        } else { Issue.record("Missing finalized original observations") }
    }

    @Test(arguments: ["fresh", "disabled", "changed-scope", "protected", "ambiguous-finish"])
    func finalFixReplacementGenerationReservesBeforeWrite(control: String) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let (remote, _) = try recoveryEmpty(); _ = try await remote.importBackup(s.repository.exportBackup())
        var pain = s.firstEvent; pain.exercises[0].problem = .pain
        _ = try await remote.finalize(programID: s.programID, expectedRevision: 0, event: pain, next: s.next)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let provider = FakeCloudAccountProvider(recoveryScope)
        let (app, model, _) = try await composition(s, provider: provider, now: Date(timeIntervalSince1970: 1791316800))
        await app.setCloudRecoveryEnabled(true); try await settle(app)
        if control == "protected" || control == "ambiguous-finish" { try await model.start(easierToday: false) }
        if control == "ambiguous-finish" {
            for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
            await s.repository.failNextSave()
            await #expect(throws: (any Error).self) { _ = try await model.finish() }
            #expect(model.hasAmbiguousFinish)
        }
        let checkpoint = RecoveryInterleavingCheckpoint()
        let held = Task { try await model.operations.perform { _ in await checkpoint.suspend() } }
        await checkpoint.waitUntilEntered()
        try await s.repository.retainCloudObservations(recoveryRecords(remote).map(\.observation), scope: recoveryScope)
        await app.cloudRecordsChanged(recoveryScope)
        await app.pauseRecoveryForBackground()
        if control == "disabled" { await app.setCloudRecoveryEnabled(false) }
        if control == "changed-scope" { await provider.set(nil) }
        await app.cloudRecordsChanged(recoveryScope)
        await checkpoint.resume(); try await held.value; try await settle(app)
        if control == "fresh" {
            #expect(model.snapshot.health == .integrityConflict)
            await #expect(throws: (any Error).self) { try await model.changeProgram(.goal(.maintenance)) }
            #expect(model.snapshot.draft == nil)
        } else {
            #expect(model.snapshot.health == .ready)
            #expect((model.snapshot.draft != nil) == (control == "protected" || control == "ambiguous-finish"))
        }
    }
}


extension CloudRecoveryLifecycleTests {
    @Test(arguments: ["cleared", "unrelated", "matching-floor"])
    func finalFixCurrentSafetyControlsRemainUsable(control: String) async throws {
        let a = try await RepositoryTestHarness.make(goal: .size), b = try await RepositoryTestHarness.make(goal: .size)
        let base = try await a.repository.snapshot(programID: a.programID).state.config.movements[0].id
        if control == "matching-floor" {
            _ = try await a.repository.applyConfiguration(programID: a.programID, expectedRevision: 0, change: .minimumRir(baseMovementID: base, value: 4), next: a.next)
            _ = try await b.repository.applyConfiguration(programID: b.programID, expectedRevision: 0, change: .minimumRir(baseMovementID: base, value: 4), next: b.next)
        } else {
            var pain = a.firstEvent; pain.exercises[0].problem = .pain
            _ = try await a.repository.finalize(programID: a.programID, expectedRevision: 0, event: pain, next: a.next)
            if control == "cleared" { _ = try await a.repository.applyConfiguration(programID: a.programID, expectedRevision: 1, change: .safeResume(baseMovementID: base, externalClearanceConfirmed: true), next: a.next) }
        }
        _ = try await CloudIngestor(repository: b.repository).ingest(recoveryRecords(b.repository), scope: recoveryScope)
        _ = try await a.repository.importBackup(b.repository.exportBackup())
        let (app, _, _) = try await composition(a)
        app.now = { Date(timeIntervalSince1970: 1791316800) }
        try await app.selectRecoveryProgram(b.programID.uuidString.lowercased())
        let model = try #require(app.workout); try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft?.displayed.exercises[control == "unrelated" ? 1 : 0])
        let movement = model.movement(for: row)
        if movement.loadingMode == .externalLoad { try await model.confirmLoad(movementID: row.movementID, load: movement.availableLoads[0]) }
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8, leftReps: movement.repCounting == .perSide ? 8 : nil, rightReps: movement.repCounting == .perSide ? 8 : nil))
        #expect(model.log(for: row.movementID)?.actualSets.count == 1)
    }
}
