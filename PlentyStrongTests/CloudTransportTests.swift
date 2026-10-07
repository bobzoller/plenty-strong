import CloudKit
import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

struct CloudTransportTests {
    @Test func cloudRecordIdentityCannotCrossDatasetsOrKinds() throws {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let journal = try CloudRecordCodec.recordName(kind: .journal, datasetID: a, identity: "event-1")
        #expect(try journal != CloudRecordCodec.recordName(kind: .journal, datasetID: b, identity: "event-1"))
        #expect(try journal != CloudRecordCodec.recordName(kind: .archive, datasetID: a, identity: "event-1"))
    }
    @Test func offlineFinishAndOldPopulatedStoreReopenPreserveDurablePending() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let oldBackup = try await s.repository.exportBackup()
        let repository = try await s.reopened()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let dataset = UUID(uuidString: oldBackup.datasetID)!
        #expect(try await repository.pendingCloudRecords(scope: scope).isEmpty)
        try await repository.bindDataset(datasetID: dataset, to: scope)
        let pending = try await repository.pendingCloudRecords(scope: scope)
        #expect(pending.filter { $0.kind == .journal }.count == 2)
        #expect(pending.filter { $0.kind == .journal && $0.identity == s.firstEvent.eventID }.count == 1)
        #expect(pending.filter { $0.kind == .archive }.count == 3)
        #expect(try await repository.exportBackup() == oldBackup)
    }
    @Test func ackRequiresExactScopeAndHashAndPersistsSystemFieldsAndCursor() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: a)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: a).first)
        let ack = CloudAcknowledgement(recordID: item.recordID, verifiedHash: item.checksum, systemFields: Data([1,2]))
        await #expect(throws: (any Error).self) { try await s.repository.acknowledge(records: [ack], scope: b) }
        await #expect(throws: (any Error).self) { try await s.repository.acknowledge(records: [.init(recordID: item.recordID, verifiedHash: "wrong", systemFields: Data())], scope: a) }
        try await s.repository.saveCloudCursor(Data([4,5]), scope: a)
        try await s.repository.acknowledge(records: [ack], scope: a)
        try await s.repository.acknowledge(records: [ack], scope: a)
        let reopened = try await s.reopened()
        #expect(try await reopened.cloudCursor(scope: a) == Data([4,5]))
        let metadata = try await reopened.cloudMetadata(scope: a)
        #expect(metadata.acknowledgements.count == 1)
        #expect(metadata.acknowledgements[item.recordID]?.systemFields == Data([1,2]))
        #expect(try await reopened.pendingCloudRecords(scope: a).count == 3)
        #expect(try await reopened.exportBackup() == backup)
    }
}

extension CloudTransportTests {
    @Test func processDeathAfterSaveRetriesSameIdentityAndAcknowledgesExactlyOnce() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let provider = FakeCloudAccountProvider(scope), server = FakeCloudServer()
        let first = FakeCloudTransport(repository: s.repository, accountProvider: provider, server: server)
        try await first.start(scope: scope)
        await first.simulateDeathAfterSave(); await first.requestSync()
        #expect(await server.creates == 1)
        #expect(try await s.repository.cloudMetadata(scope: scope).acknowledgements.isEmpty)
        await first.stop()
        let reopened = try await s.reopened()
        let restarted = FakeCloudTransport(repository: reopened, accountProvider: provider, server: server)
        try await restarted.start(scope: scope); await restarted.requestSync(); await restarted.requestSync()
        #expect(await server.creates == 4)
        #expect(try await reopened.cloudMetadata(scope: scope).acknowledgements.count == 4)
        #expect(try await reopened.pendingCloudRecords(scope: scope).isEmpty)
        #expect(await restarted.syncStatus().phase == .upToDateForKnownRecords)
        #expect(try await reopened.exportBackup() == backup)
    }
    @Test(arguments: [CKError.Code.quotaExceeded, .notAuthenticated, .networkFailure, .serviceUnavailable, .requestRateLimited])
    func failuresKeepEveryPendingRecord(code: CKError.Code) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let provider = FakeCloudAccountProvider(scope), server = FakeCloudServer()
        await server.fail(code)
        let transport = FakeCloudTransport(repository: s.repository, accountProvider: provider, server: server)
        try await transport.start(scope: scope); await transport.requestSync()
        #expect(try await s.repository.pendingCloudRecords(scope: scope).count == 4)
        #expect(await server.creates == 0)
        #expect(await transport.syncStatus().retryReason != nil)
        await transport.stop()
        #expect(try await s.reopened().pendingCloudRecords(scope: scope).count == 4)
    }
    @Test func changedServerBytesAreQuarantinedWithoutOverwritingOrAcknowledging() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first)
        // The claimed hash even matches; actual server bytes must still match.
        let conflict = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: Data("{}".utf8), systemFields: Data([8]))
        let server = FakeCloudServer(); await server.put(conflict)
        let transport = FakeCloudTransport(repository: s.repository, accountProvider: FakeCloudAccountProvider(scope), server: server)
        try await transport.start(scope: scope); await transport.requestSync()
        #expect(await server.creates == 0)
        #expect(try await s.repository.pendingCloudRecords(scope: scope).count == 4)
        #expect(try await s.repository.cloudStatus(scope: scope).phase == .conflict)
        let reopened = try await s.reopened()
        let metadata = try await reopened.cloudMetadata(scope: scope)
        #expect(metadata.observations.values.contains(conflict))
        #expect(metadata.acknowledgements[item.recordID] == nil)
        #expect(try await reopened.exportBackup() == backup)
    }
    @Test func completedWorkoutAckRequiresAllArchives() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let items = try await s.repository.pendingCloudRecords(scope: scope)
        let workout = try #require(items.first(where: { $0.isCompletedWorkout }))
        try await s.repository.acknowledge(records: [.init(recordID: workout.recordID, verifiedHash: workout.checksum, systemFields: Data())], scope: scope)
        #expect(try await s.repository.cloudStatus(scope: scope).acknowledgedCompletedWorkoutCount == 0)
        for item in items where item.kind == .archive {
            try await s.repository.acknowledge(records: [.init(recordID: item.recordID, verifiedHash: item.checksum, systemFields: Data())], scope: scope)
        }
        #expect(try await s.repository.cloudStatus(scope: scope).acknowledgedCompletedWorkoutCount == 0)
        #expect(try await s.repository.cloudStatus(scope: scope).pendingRecordCount == 1)
        let root = try #require(items.first(where: { $0.isRoot }))
        try await s.repository.acknowledge(records: [.init(recordID: root.recordID, verifiedHash: root.checksum, systemFields: Data())], scope: scope)
        #expect(try await s.repository.cloudStatus(scope: scope).acknowledgedCompletedWorkoutCount == 1)
    }
    @Test func ckAssetRoundTripUsesCanonicalBytesAndCreateOnlySystemFields() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        for item in try await s.repository.pendingCloudRecords(scope: scope) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let record = try CloudRecordCodec.makeRecord(item, assetURL: url)
            #expect(record.recordChangeTag == nil)
            #expect(CloudRecordCodec.matches(try CloudRecordCodec.observation(record), pending: item))
            #expect(try Data(contentsOf: url) == item.payload)
            #expect(try CloudRecordCodec.canonicalBytes(item.payload) == item.payload)
            // System fields can be securely round-tripped but are never fed to a save.
            let fields = CloudRecordCodec.systemFields(record)
            let decoder = try NSKeyedUnarchiver(forReadingFrom: fields); decoder.requiresSecureCoding = true
            let decoded = try #require(CKRecord(coder: decoder)); decoder.finishDecoding()
            #expect(decoded.recordID == record.recordID)
        }
    }
}

extension CloudTransportTests {
    @Test func largeCanonicalHistoryPayloadUsesAssetAndChecksActualBytes() throws {
        let dataset = UUID()
        let bytes = try BackupService.bytes(["longHistory": String(repeating: "synthetic-history-", count: 90_000)])
        #expect(bytes.count > 1_024 * 1_024)
        let item = PendingCloudRecord(recordID: try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: "large-event"),
            kind: .journal, datasetID: dataset, identity: "large-event", payload: bytes, checksum: BackupService.hash(bytes),
            archiveReferences: [], programID: nil, isRoot: false, isCompletedWorkout: false, systemFields: Data([1]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let record = try CloudRecordCodec.makeRecord(item, assetURL: url)
        #expect(record["payload"] is CKAsset)
        #expect(record.recordChangeTag == nil)
        #expect(CloudRecordCodec.matches(try CloudRecordCodec.observation(record), pending: item))
        try Data("{\"changed\":true}".utf8).write(to: url)
        #expect(!CloudRecordCodec.matches(try CloudRecordCodec.observation(record), pending: item))
    }
    @Test func failedMetadataSaveRollsBackAckWithoutLosingPendingOrCursor() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        try await s.repository.saveCloudCursor(Data([7]), scope: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first)
        await s.repository.failNextSave()
        await #expect(throws: (any Error).self) {
            try await s.repository.acknowledge(records: [.init(recordID: item.recordID, verifiedHash: item.checksum, systemFields: Data([8]))], scope: scope)
        }
        let reopened = try await s.reopened()
        #expect(try await reopened.pendingCloudRecords(scope: scope).count == 4)
        #expect(try await reopened.cloudCursor(scope: scope) == Data([7]))
        #expect(try await reopened.cloudMetadata(scope: scope).acknowledgements.isEmpty)
        #expect(try await reopened.exportBackup() == backup)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLENTY_RUN_DEVELOPMENT_CLOUD_SMOKE"] == "YES", "Requires explicit live development gate"))
    func developmentCloudSmokeIsExplicitlyOptIn() async throws {
        // This compiled smoke is never run against an account/container unless
        // Bob approves the exact live gate and sets BOTH test environment values.
        let environment = ProcessInfo.processInfo.environment
        let identifier = try #require(environment["PLENTY_DEVELOPMENT_CLOUD_CONTAINER"])
        #expect(!identifier.isEmpty)
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let container = CKContainer(identifier: identifier)
        let provider = CloudKitAccountProvider(container: container, environment: .development)
        let scope = try #require(try await provider.currentScope())
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let originals = try await s.repository.pendingCloudRecords(scope: scope)
        let transport = CloudKitTransport(container: container, accountProvider: provider, repository: s.repository)
        try await transport.start(scope: scope); await transport.requestSync()
        let status = await transport.syncStatus()
        #expect(status.pendingRecordCount == 0)
        #expect(status.lastRecordAcknowledgement != nil)
        #expect(status.retryReason == nil)
        for item in originals {
            let fetched = try await container.privateCloudDatabase.record(for: CloudRecordCodec.recordID(item))
            #expect(CloudRecordCodec.matches(try CloudRecordCodec.observation(fetched), pending: item))
        }
        await transport.stop()
    }
}

extension CloudTransportTests {
    @Test func unsupportedRootIsDiscoverableAndIncomingBytesRemainUnaccepted() async throws {
        let dataset = UUID(), program = UUID()
        let bytes = try BackupService.bytes(["schemaVersion": "future", "datasetId": dataset.uuidString.lowercased(),
            "programId": program.uuidString.lowercased(), "eventId": "future-root", "command": "future-command"])
        let incoming = CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: "future-root"),
            zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: "JournalV1", claimedChecksum: BackupService.hash(bytes),
            payload: bytes, systemFields: Data())
        let candidates = CloudRecordCodec.recoveryCandidates([incoming])
        #expect(candidates == [.init(datasetID: dataset, programID: program, knownCompletedWorkoutCount: 0, status: .unsupported)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try TrainingRepository.open(at: url)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await repository.retainCloudObservations([incoming], scope: scope)
        try await repository.saveCloudCursor(Data([10]), scope: scope)
        #expect(try await repository.cloudStatus(scope: scope).phase == .incomplete)
        #expect(try await repository.counts() == [0,0,0,0,0])
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        #expect(try await reopened.cloudMetadata(scope: scope).observations.values.contains(incoming))
        #expect(try await reopened.cloudCursor(scope: scope) == Data([10]))
    }
    @Test func appendedHistoryDeduplicatesFrozenArchivesAndRebuildsOutboxAfterReopen() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        var current = try await s.repository.snapshot(programID: s.programID)
        for revision in 0..<12 {
            let slot = try WorkoutScheduler.nextSlot(after: current.state.activePrescription.date, config: current.state.config)
            current = try await s.repository.reschedule(programID: s.programID, expectedRevision: revision, slot: slot)
        }
        let reopened = try await s.reopened()
        let pending = try await reopened.pendingCloudRecords(scope: scope)
        #expect(pending.filter { $0.kind == .journal }.count == 13)
        #expect(pending.filter { $0.kind == .archive }.count == 3)
        #expect(Set(pending.map(\.recordID)).count == 16)
        for item in pending { #expect(BackupService.hash(item.payload) == item.checksum) }
        let server = FakeCloudServer()
        let transport = FakeCloudTransport(repository: reopened, accountProvider: FakeCloudAccountProvider(scope), server: server)
        try await transport.start(scope: scope); await transport.requestSync()
        #expect(await server.creates == 16)
        #expect(try await reopened.pendingCloudRecords(scope: scope).isEmpty)
    }
}

extension CloudTransportTests {
    @Test func remoteDeletionRemainsAnObservationAndMakesRecoveryIncomplete() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let dataset = UUID(uuidString: backup.datasetID)!
        try await s.repository.bindDataset(datasetID: dataset, to: scope)
        let fake = FakeCloudTransport(repository: s.repository, accountProvider: FakeCloudAccountProvider(scope), server: FakeCloudServer())
        try await fake.start(scope: scope); await fake.requestSync()
        try await s.repository.retainCloudObservations([], deletedRecordIDs: ["zone:" + CloudRecordCodec.zoneID(dataset).zoneName], scope: scope)
        #expect(try await s.repository.cloudStatus(scope: scope).phase == .incomplete)
        #expect(try await s.repository.exportBackup() == backup)
        #expect(try await s.repository.pendingCloudRecords(scope: scope).isEmpty)
    }
}

extension CloudTransportTests {
    @Test(arguments: [CloudRecordKind.archive, .journal], [false, true])
    func productionFetchedKnownChangedBytesAreAtomicallyQuarantined(kind: CloudRecordKind, alreadyAcknowledged: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first(where: { $0.kind == kind }))
        if alreadyAcknowledged {
            try await s.repository.acknowledge(records: [.init(recordID: item.recordID, verifiedHash: item.checksum, systemFields: Data([1]))], scope: scope)
        }
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository)
        let changed = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: Data("{}".utf8), systemFields: Data([2]))
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        let firstRecord = try CloudRecordCodec.makeRecord(item, assetURL: firstURL)
        try changed.payload.write(to: firstURL)
        await transport.deliverCallbackForTesting(.fetchedRecords([firstRecord], deletedRecordIDs: []))
        let repeated = CloudObservation(recordID: item.recordID, zoneName: changed.zoneName, recordType: changed.recordType,
            claimedChecksum: item.checksum, payload: Data("{\"second\":true}".utf8), systemFields: Data([3]))
        let secondRecord = try CloudRecordCodec.makeRecord(item, assetURL: secondURL)
        try repeated.payload.write(to: secondURL)
        await transport.deliverCallbackForTesting(.fetchedRecords([secondRecord], deletedRecordIDs: []))
        // Same changed bytes with another source's system fields must not erase
        // the first captured SDK source observation.
        let anotherSource = CloudObservation(recordID: item.recordID, zoneName: changed.zoneName, recordType: changed.recordType,
            claimedChecksum: item.checksum, payload: changed.payload, systemFields: Data([99]))
        await transport.deliverCallbackForTesting(.fetched([anotherSource], deletedRecordIDs: []))
        let metadata = try await s.repository.cloudMetadata(scope: scope)
        #expect(metadata.conflictingRecordIDs.contains(item.recordID))
        #expect(metadata.observations.values.contains { $0.recordID == item.recordID && $0.payload == changed.payload && $0.claimedChecksum == item.checksum })
        #expect(metadata.observations.values.contains { $0.recordID == item.recordID && $0.payload == repeated.payload && $0.claimedChecksum == item.checksum })
        #expect(metadata.observations.count == 3)
        #expect(metadata.observations.values.contains(anotherSource))
        #expect((metadata.acknowledgements[item.recordID] != nil) == alreadyAcknowledged)
        #expect(try await s.repository.cloudStatus(scope: scope).phase == .conflict)
        #expect(try await s.repository.snapshot(programID: s.programID).health == .ready)
        #expect(try await s.repository.exportBackup() == backup)
        await transport.stop()
        let reopened = try await s.reopened()
        #expect(try await reopened.cloudMetadata(scope: scope).conflictingRecordIDs.contains(item.recordID))
    }
    @Test(arguments: [false, true])
    func productionVerificationThrowRetriesWithoutPoisonOrPrematureCursor(saved: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        try await s.repository.saveCloudCursor(Data([1]), scope: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first)
        let observation = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: item.payload, systemFields: Data([2]))
        let provider = ThrowingCloudAccountProvider(scope, failure: .networkFailure)
        let transport = CloudKitTransport(testingScope: scope, accountProvider: provider, repository: s.repository)
        let assetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = try CloudRecordCodec.makeRecord(item, assetURL: assetURL)
        await transport.deliverCallbackForTesting(saved ? .saved(observation) : .fetchedRecords([record], deletedRecordIDs: []))
        try FileManager.default.removeItem(at: assetURL)
        let diagnostics = await transport.callbackDiagnosticsForTesting()
        #expect(!diagnostics.persistenceFailed)
        #expect(diagnostics.deferredCount == 1)
        #expect((diagnostics.retryDelay ?? 0) >= 10 && (diagnostics.retryDelay ?? 0) <= 3_600)
        #expect(await transport.syncStatus().phase == .pending)
        #expect(try await s.repository.cloudCursor(scope: scope) == Data([1]))
        #expect(try await s.repository.cloudMetadata(scope: scope).acknowledgements.isEmpty)
        await provider.failNext(.networkFailure)
        await transport.deliverCallbackForTesting(.cursor(Data([3])))
        #expect(try await s.repository.cloudCursor(scope: scope) == Data([1]))
        #expect(try await s.repository.cloudMetadata(scope: scope).acknowledgements.isEmpty)
        #expect(await transport.callbackDiagnosticsForTesting().deferredCount == 2)
        #expect(!(await transport.callbackDiagnosticsForTesting().persistenceFailed))
        await transport.deliverCallbackForTesting(.cursor(Data([4])))
        #expect(try await s.repository.cloudCursor(scope: scope) == Data([4]))
        #expect(try await s.repository.cloudMetadata(scope: scope).observations.values.contains { $0.recordID == item.recordID && $0.payload == observation.payload })
        #expect((try await s.repository.cloudMetadata(scope: scope).acknowledgements[item.recordID] != nil) == saved)
        #expect(await transport.callbackDiagnosticsForTesting().deferredCount == 0)
        await transport.stop()
    }
    @Test(arguments: ["fetched", "saved", "cursor"])
    func productionDurableCallbackFailureStillBlocksTokenAdvancement(operation: String) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        try await s.repository.saveCloudCursor(Data([1]), scope: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first)
        let observation = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: item.payload, systemFields: Data([2]))
        let clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        try await awaitScheduledRetry(clock)
        await s.repository.failNextSave()
        let callback: CloudTransportCallback = operation == "cursor" ? .cursor(Data([3])) : operation == "saved" ? .saved(observation) : .fetched([observation], deletedRecordIDs: [])
        await transport.deliverCallbackForTesting(callback)
        #expect(await transport.callbackDiagnosticsForTesting().persistenceFailed)
        await transport.deliverCallbackForTesting(.cursor(Data([4])))
        #expect(try await s.repository.cloudCursor(scope: scope) == Data([1]))
        #expect(try await s.repository.cloudMetadata(scope: scope).acknowledgements.isEmpty)
        #expect(try await s.repository.pendingCloudRecords(scope: scope).count == 4)
        await clock.advance()
        for _ in 0..<100 {
            if await transport.callbackDiagnosticsForTesting().retryDelay == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count() == 0)
        await transport.stop(); await clock.advance()
    }
}

extension CloudTransportTests {
    @Test func productionDeferredCallbacksNeverReplayAcrossStopOrChangedAccount() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: a)
        try await s.repository.saveCloudCursor(Data([1]), scope: a)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: a).first)
        let observation = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: item.payload, systemFields: Data())
        let provider = ThrowingCloudAccountProvider(a, failure: .networkFailure)
        let transport = CloudKitTransport(testingScope: a, accountProvider: provider, repository: s.repository)
        await transport.deliverCallbackForTesting(.saved(observation))
        await provider.set(b)
        await transport.deliverCallbackForTesting(.cursor(Data([2])))
        #expect(await transport.syncStatus().phase == .accountUnavailable)
        #expect(!(await transport.callbackDiagnosticsForTesting().persistenceFailed))
        #expect(try await s.repository.cloudCursor(scope: a) == Data([1]))
        #expect(try await s.repository.cloudMetadata(scope: a).acknowledgements.isEmpty)
        #expect(try await s.repository.cloudMetadata(scope: b).observations.isEmpty)
        #expect(try await s.repository.cloudCursor(scope: b) == nil)
        #expect(try await s.repository.pendingCloudRecords(scope: b).isEmpty)
        await transport.stop()
        await provider.set(a)
        await transport.deliverCallbackForTesting(.cursor(Data([3])))
        #expect(await transport.callbackDiagnosticsForTesting().deferredCount == 0)
        #expect(try await s.repository.cloudCursor(scope: a) == Data([1]))
        #expect(try await s.repository.cloudMetadata(scope: a).acknowledgements.isEmpty)
    }
}

extension CloudTransportTests {
    private func awaitScheduledRetry(_ clock: ControlledCloudRetryClock) async throws {
        for _ in 0..<100 {
            if await clock.sleeperCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Production retry task never reached its controlled wait")
    }
    private func awaitSyncAttempt(_ probe: CloudNetworkSyncProbe, count: Int) async throws {
        for _ in 0..<100 {
            if await probe.count() >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Scheduled retry did not reach production requestSync")
    }
    @Test(arguments: [false, true], [CKError.Code.networkFailure, .serviceUnavailable, .quotaExceeded])
    func sdkRetrySurvivesUnrelatedSuccessfulCallbackAndActuallySyncs(saved: Bool, code: CKError.Code) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let item = try #require(try await s.repository.pendingCloudRecords(scope: scope).first)
        let observation = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: item.payload, systemFields: Data([2]))
        let clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(code))
        try await awaitScheduledRetry(clock)
        let reason = try #require(await transport.syncStatus().retryReason)
        let hint: String
        switch code { case .networkFailure: hint = "network"; case .quotaExceeded: hint = "storage"; default: hint = "busy" }
        #expect(reason.contains(hint))
        #expect(await transport.syncStatus().phase == .pending)
        await transport.deliverCallbackForTesting(saved ? .saved(observation) : .cursor(Data([3])))
        #expect(await transport.syncStatus().retryReason == reason)
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay != nil)
        #expect(await probe.count() == 0)
        await clock.advance()
        try await awaitSyncAttempt(probe, count: 1)
        // Completion runs after the probe observes the external operation.
        for _ in 0..<100 {
            if await transport.syncStatus().retryReason == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count() == 1)
        #expect(await transport.syncStatus().retryReason == nil)
        #expect(!(await transport.callbackDiagnosticsForTesting().persistenceFailed))
        await transport.stop(); await clock.advance()
    }
    @Test func successfulSyncAttemptCannotClearNewerSDKFailure() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await probe.setAction { await transport.deliverSDKFailureForTesting(CKError(.serviceUnavailable)) }
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        try await awaitScheduledRetry(clock); await clock.advance()
        try await awaitSyncAttempt(probe, count: 1)
        try await awaitScheduledRetry(clock)
        #expect(await transport.syncStatus().retryReason?.contains("busy") == true)
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay != nil)
        await probe.setAction(nil); await clock.advance()
        try await awaitSyncAttempt(probe, count: 2)
        for _ in 0..<100 {
            if await transport.syncStatus().retryReason == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.syncStatus().retryReason == nil)
        await transport.stop(); await clock.advance()
    }
    @Test(arguments: [false, true])
    func sdkRetryCannotSendAfterStopOrAccountChange(stopped: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: a)
        let clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe(), provider = ThrowingCloudAccountProvider(a)
        let transport = CloudKitTransport(testingScope: a, accountProvider: provider, repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        try await awaitScheduledRetry(clock)
        if stopped { await transport.stop() } else { await provider.set(b) }
        await clock.advance()
        // B verification must terminate the retry as unavailable before network.
        for _ in 0..<100 {
            if stopped { break }
            if await transport.syncStatus().phase == .accountUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count() == 0)
        #expect(try await s.repository.cloudMetadata(scope: b).observations.isEmpty)
        #expect(try await s.repository.pendingCloudRecords(scope: b).isEmpty)
        if !stopped { #expect(await transport.syncStatus().phase == .accountUnavailable) }
        await transport.stop(); await clock.advance()
    }
}

extension CloudTransportTests {
    @Test(arguments: [false, true])
    func retryFiringDuringNetworkAttemptHandsOffAfterAttemptCompletes(newFailure: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let clock = ControlledCloudRetryClock(), networkGate = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await probe.setAction { await networkGate.wait(0) }
        let firstAttempt = Task { await transport.requestSync() }
        try await awaitSyncAttempt(probe, count: 1)
        try await awaitScheduledRetry(networkGate)
        await transport.deliverSDKFailureForTesting(CKError(.serviceUnavailable))
        try await awaitScheduledRetry(clock); await clock.advance()
        for _ in 0..<100 {
            if await transport.callbackDiagnosticsForTesting().retryDelay == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count() == 1) // No concurrent network attempt.
        #expect(await transport.syncStatus().retryReason?.contains("busy") == true)
        if newFailure {
            // A newer failure owns a fresh backoff. The expired earlier timer
            // must not bypass this newer SDK delay at attempt completion.
            await transport.deliverSDKFailureForTesting(CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: 120.0]))
            try await awaitScheduledRetry(clock)
            #expect(await transport.callbackDiagnosticsForTesting().retryDelay == 120)
        }
        await probe.setAction(nil); await networkGate.advance(); await firstAttempt.value
        if newFailure {
            try await Task.sleep(for: .milliseconds(50))
            #expect(await probe.count() == 1)
            #expect(await transport.syncStatus().retryReason?.contains("storage") == true)
            #expect(await transport.callbackDiagnosticsForTesting().retryDelay == 120)
            await clock.advance()
        }
        try await awaitSyncAttempt(probe, count: 2)
        for _ in 0..<100 {
            if await transport.syncStatus().retryReason == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count() == 2)
        #expect(await transport.syncStatus().retryReason == nil)
        await transport.stop(); await clock.advance()
    }
}


extension CloudTransportTests {
    @Test(arguments: [false, true])
    func sdkRetrySurvivesOccupiedCallbackDrain(explicitRequest: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let clock = ControlledCloudRetryClock(), verificationGate = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let provider = ThrowingCloudAccountProvider(scope)
        let transport = CloudKitTransport(testingScope: scope, accountProvider: provider, repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        try await awaitScheduledRetry(clock)
        await provider.blockNextVerification(verificationGate)
        let callback = Task { await transport.deliverCallbackForTesting(.cursor(Data([3]))) }
        try await awaitScheduledRetry(verificationGate)
        if explicitRequest {
            await transport.requestSync() // Queue is occupied, so no network yet.
            #expect(await transport.callbackDiagnosticsForTesting().retryDelay != nil)
        } else {
            await clock.advance() // Expired retry awaits the occupied queue.
            for _ in 0..<100 {
                if await transport.callbackDiagnosticsForTesting().retryDelay == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(await probe.count() == 0)
        await verificationGate.advance(); await callback.value
        if explicitRequest { await clock.advance() }
        try await awaitSyncAttempt(probe, count: 1)
        #expect(await probe.count() == 1)
        #expect(try await s.repository.cloudCursor(scope: scope) == Data([3]))
        await transport.stop(); await clock.advance()
    }
}


extension CloudTransportTests {
    @Test(arguments: [false, true])
    func staleScheduledHandoffCannotBypassNewerServerFloor(admittedBeforeNewFailure: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let clock = ControlledCloudRetryClock(), verificationGate = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let provider = ThrowingCloudAccountProvider(scope)
        let transport = CloudKitTransport(testingScope: scope, accountProvider: provider, repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        if admittedBeforeNewFailure {
            await provider.failNext(.networkFailure)
            await transport.deliverCallbackForTesting(.cursor(Data([3])))
            try await awaitScheduledRetry(clock)
        }
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        try await awaitScheduledRetry(clock)
        let capturedHandoffToken = await transport.retryScheduleTokenForTesting()
        var admitted: Task<Void, Never>?
        if admittedBeforeNewFailure {
            await provider.blockNextVerification(verificationGate)
            admitted = Task { await transport.deliverScheduledRetryForTesting(token: capturedHandoffToken) }
            try await awaitScheduledRetry(verificationGate)
        }
        await transport.deliverSDKFailureForTesting(CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: 120.0]))
        if let admitted {
            // The retry was admitted, then awaited a queue while a newer floor
            // arrived. Its token must be checked again after that await.
            await verificationGate.advance(); await admitted.value
        } else {
            // Deliver a queued handoff captured before the newer floor existed.
            await transport.deliverScheduledRetryForTesting(token: capturedHandoffToken)
        }
        #expect(await probe.count() == 0)
        #expect(await transport.syncStatus().retryReason?.contains("storage") == true)
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay == 120)
        for _ in 0..<100 {
            if await clock.sleeperCount() >= (admittedBeforeNewFailure ? 3 : 2) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await clock.advance()
        try await awaitSyncAttempt(probe, count: 1)
        #expect(await probe.count() == 1)
        await transport.stop(); await clock.advance()
    }
}


extension CloudTransportTests {
    @Test func finalFixRetryFloorSurvivesShorterCallback() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let provider = ThrowingCloudAccountProvider(scope), clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: provider, repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 120.0]))
        await provider.failNext(.networkFailure)
        await transport.deliverCallbackForTesting(.cursor(Data([3])))
        #expect((await transport.callbackDiagnosticsForTesting().retryDelay ?? 0) > 119)
        // Admission must respect the floor even if an old timer is delivered early.
        await transport.requestSync()
        #expect(await probe.count() == 0)
        await transport.deliverCallbackForTesting(.cursor(Data([4]))) // resolves only callback owner
        #expect((await transport.callbackDiagnosticsForTesting().retryDelay ?? 0) > 119)
        await transport.requestSync(); #expect(await probe.count() == 0)
        await transport.deliverSDKFailureForTesting(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 240.0]))
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay == 240)
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay == 240)
        let token = await transport.retryScheduleTokenForTesting()
        await clock.advance(by: 119)
        await transport.deliverScheduledRetryForTesting(token: token)
        #expect(await probe.count() == 0)
        await clock.advance(by: 120)
        await transport.requestSync(); #expect(await probe.count() == 0)
        await clock.advance(by: 1)
        await transport.requestSync()
        try await awaitSyncAttempt(probe, count: 1)
        #expect(await transport.syncStatus().retryReason == nil)
        #expect(await transport.callbackDiagnosticsForTesting().retryDelay == nil)
        await transport.deliverSDKFailureForTesting(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 300.0]))
        await transport.stop(); await clock.advance()
        await transport.deliverScheduledRetryForTesting(token: token)
        #expect(await probe.count() == 1)
    }
    @Test func finalFixResolvedOwnersInvalidateQueuedHandoff() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let clock = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: ThrowingCloudAccountProvider(scope), repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await transport.deliverSDKFailureForTesting(CKError(.networkFailure))
        let token = await transport.retryScheduleTokenForTesting()
        await transport.requestSync() // Both owners resolve before queued retry admission.
        #expect(await probe.count() == 1)
        await transport.deliverScheduledRetryForTesting(token: token)
        #expect(await probe.count() == 1)
        await transport.stop(); await clock.advance()
    }
}


extension CloudTransportTests {
    @Test(arguments: [false, true])
    func finalFixProviderFloorArrivingDuringAdmissionBlocksNetwork(changedScope: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let provider = ThrowingCloudAccountProvider(scope), clock = ControlledCloudRetryClock(), verification = ControlledCloudRetryClock(), probe = CloudNetworkSyncProbe()
        let transport = CloudKitTransport(testingScope: scope, accountProvider: provider, repository: s.repository,
            retryWait: { await clock.wait($0) }, retryNow: { clock.now() }, networkSync: { try await probe.sync() })
        await provider.blockNextVerification(verification)
        let request = Task { await transport.requestSync() }
        try await awaitScheduledRetry(verification)
        await transport.deliverSDKFailureForTesting(CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 120.0]))
        if changedScope { await provider.set(CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")) }
        await verification.advance(); await request.value
        #expect(await probe.count() == 0)
        #expect((await transport.callbackDiagnosticsForTesting().retryDelay ?? 0) >= 120)
        await transport.stop(); await clock.advance()
        #expect(await probe.count() == 0)
    }
}
