import Foundation
import SwiftData
import Testing
@testable import PlentyStrong

struct CloudAccountTests {
    @Test func bindingSurvivesSignOutAndAccountChangeWhileTerminated() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let dataset = UUID(uuidString: backup.datasetID)!
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        try await s.repository.bindDataset(datasetID: dataset, to: a)
        let reopened = try await s.reopened()
        #expect(try await reopened.pendingCloudRecords(scope: b).isEmpty)
        await #expect(throws: (any Error).self) { try await reopened.bindDataset(datasetID: dataset, to: b) }
        #expect(try await reopened.pendingCloudRecords(scope: a).count == 4)
        #expect(try await reopened.exportBackup() == backup)
    }
}

extension CloudAccountTests {
    @Test func coordinatorSignOutSwitchDisableAndMissingAccountNeverBlockLocalFinish() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let dataset = UUID(uuidString: backup.datasetID)!
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        let provider = FakeCloudAccountProvider(a), server = FakeCloudServer()
        let fake = FakeCloudTransport(repository: s.repository, accountProvider: provider, server: server)
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: provider, makeTransport: { fake })
        try await coordinator.enable(datasetID: dataset)
        await provider.set(nil); await coordinator.requestSync()
        #expect(await coordinator.syncStatus().phase == .accountUnavailable)
        await provider.set(b); await coordinator.requestSync()
        #expect(await server.creates == 0)
        #expect(try await s.repository.pendingCloudRecords(scope: b).isEmpty)
        await coordinator.disable()
        #expect(await coordinator.syncStatus().phase == .localOnly)
        await provider.set(nil); try await coordinator.enable(datasetID: dataset)
        let result = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        #expect(result.snapshot.state.revision == 1)
        #expect(try await s.repository.pendingCloudRecords(scope: a).filter { $0.kind == .journal }.count == 2)
        #expect(await server.creates == 0)
    }
    @Test func discoveryOnFreshStoreIsReadOnlyAndRetainsOriginalsWithoutBindingHeads() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let backup = try await s.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let server = FakeCloudServer(), provider = FakeCloudAccountProvider(scope)
        let uploader = FakeCloudTransport(repository: s.repository, accountProvider: provider, server: server)
        try await uploader.start(scope: scope); await uploader.requestSync()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fresh = try TrainingRepository.open(at: url)
        let reader = FakeCloudTransport(repository: fresh, accountProvider: provider, server: server)
        let coordinator = CloudSyncCoordinator(repository: fresh, accountProvider: provider, makeTransport: { reader })
        let candidates = try await coordinator.discoverRecoveryCandidates()
        #expect(candidates.count == 1)
        #expect(candidates.first?.datasetID.uuidString.lowercased() == backup.datasetID)
        #expect(candidates.first?.status == .incomplete)
        #expect(await reader.startedCount == 0)
        #expect(await server.creates == 4)
        #expect(try await fresh.counts() == [0, 0, 0, 0, 0])
        #expect(try await fresh.pendingCloudRecords(scope: scope).isEmpty)
        #expect(try await fresh.cloudMetadata(scope: scope).observations.count == 4)
        await fresh.close()
        let reopened = try TrainingRepository.open(at: url)
        #expect(try await reopened.cloudMetadata(scope: scope).observations.count == 4)
        #expect(try await reopened.counts() == [0, 0, 0, 0, 0])
    }
}

extension CloudAccountTests {
    @Test func optionalNetworkWaitDoesNotFreezeLocalDraftOrFinish() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let backup = try await s.repository.exportBackup()
        try await s.repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
        let draft = try await s.draft(); try await s.repository.saveDraft(draft)
        let server = FakeCloudServer(); await server.pauseNextCreate()
        let transport = FakeCloudTransport(repository: s.repository, accountProvider: FakeCloudAccountProvider(scope), server: server)
        try await transport.start(scope: scope)
        let sync = Task { await transport.requestSync() }
        await server.waitForPause()
        #expect(try await s.repository.snapshot(programID: s.programID).draft == draft)
        let finished = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        #expect(finished.snapshot.state.revision == 1)
        await server.resumeCreate(); await sync.value
        #expect(try await s.repository.pendingCloudRecords(scope: scope).count == 1)
        await transport.requestSync()
        #expect(try await s.repository.pendingCloudRecords(scope: scope).isEmpty)
    }
    @Test func sameAccountDifferentContainerOrEnvironmentCannotUseBinding() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let dataset = UUID(uuidString: try await s.repository.exportBackup().datasetID)!
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        try await s.repository.bindDataset(datasetID: dataset, to: a)
        for other in [CloudScope(containerIdentifier: "other", environment: .development, accountIdentifier: "A"),
                      CloudScope(containerIdentifier: "synthetic", environment: .production, accountIdentifier: "A")] {
            #expect(try await s.repository.pendingCloudRecords(scope: other).isEmpty)
            await #expect(throws: (any Error).self) { try await s.repository.bindDataset(datasetID: dataset, to: other) }
        }
    }
}

extension CloudAccountTests {
    @MainActor private func replaceBindingBytes(_ bytes: Data, at url: URL) throws {
        let container = try TrainingMigrationPlan.open(at: url)
        let context = SwiftData.ModelContext(container); context.autosaveEnabled = false
        let row = try #require(try context.fetch(SwiftData.FetchDescriptor<CloudCursorRecord>()).first(where: { $0.accountScope == "cloud-bindings-v1" }))
        row.bytes = bytes; try context.save()
    }
    @Test(arguments: [Data("malformed-binding".utf8), Data("{\"version\":99,\"datasets\":{}}".utf8)])
    func invalidOptionalBindingsPreserveLocalAcceptanceAndFailClosedCloud(bytes: Data) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let a = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "A")
        let b = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "B")
        let dataset = UUID(uuidString: try await s.repository.exportBackup().datasetID)!
        try await s.repository.bindDataset(datasetID: dataset, to: a)
        await s.repository.close()
        try await replaceBindingBytes(bytes, at: s.storeURL)
        let reopened = try TrainingRepository.open(at: s.storeURL)
        let receipt = try await reopened.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        #expect(receipt.snapshot.state.revision == 1)
        let configured = try await reopened.applyConfiguration(programID: s.programID, expectedRevision: 1, change: .goal(.maintenance), next: s.next)
        #expect(configured.state.revision == 2)
        #expect(try await reopened.exportBackup().journal.count == 3)
        #expect(try await reopened.counts() == [3,1,0,3,0])
        await #expect(throws: (any Error).self) { try await reopened.pendingCloudRecords(scope: a) }
        await #expect(throws: (any Error).self) { try await reopened.bindDataset(datasetID: dataset, to: b) }
        await reopened.close()
        let container = try TrainingMigrationPlan.open(at: s.storeURL)
        let preserved = try await MainActor.run { () throws -> (Data, [String?]) in
            let context = SwiftData.ModelContext(container)
            let binding = try #require(try context.fetch(SwiftData.FetchDescriptor<CloudCursorRecord>()).first(where: { $0.accountScope == "cloud-bindings-v1" }))
            return (binding.bytes, try context.fetch(SwiftData.FetchDescriptor<OutboxRecord>()).map(\.accountScope))
        }
        #expect(preserved.0 == bytes)
        #expect(preserved.1.filter { $0 == nil }.count == 2)
        #expect(preserved.1.contains(a.key))
        #expect(!preserved.1.contains(b.key))
    }
}
