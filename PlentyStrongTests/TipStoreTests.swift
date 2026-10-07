import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@Suite(.serialized) @MainActor struct TipStoreTests {
    let productID = "us.zoller.PlentyStrong.tip.small"
    func cacheURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("commerce/receipts.json") }
    func store(_ fake: FakeTipPurchaser, at url: URL? = nil) -> TipStore { TipStore(purchaser: fake, receiptURL: url ?? cacheURL()) }
    func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    @Test func voluntaryTipFinishesVerifiedTransaction() async throws {
        let fake = FakeTipPurchaser(outcome: .verifiedTip(VerifiedTip(transactionID: 42, productID: productID)))
        let url = cacheURL(), store = store(fake, at: url)
        fake.beforeFinish = {
            let cache = try TipReceiptCache(url: url)
            #expect(cache.status(transactionID: 42) == .finishPending)
        }
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .thankYou); #expect(fake.finishedTransactionIDs == [42])
        #expect(try TipReceiptCache(url: url).status(transactionID: 42) == .finished)
    }
    @Test func repeatedUpdateAndRelaunchDoNotDuplicateAcknowledgementOrFinish() async throws {
        let tip = VerifiedTip(transactionID: 42, productID: productID)
        let fake = FakeTipPurchaser(outcome: .verifiedTip(tip)), url = cacheURL()
        let first = store(fake, at: url)
        await first.load(); await first.tip(productID: productID)
        await first.load(); fake.delivery.yield(tip)
        try await Task.sleep(for: .milliseconds(80))
        #expect(first.state == .ready); #expect(fake.finishedTransactionIDs == [42])
        let next = FakeTipPurchaser(), relaunched = store(next, at: url)
        await relaunched.load(); next.delivery.yield(tip)
        try await Task.sleep(for: .milliseconds(80))
        #expect(relaunched.state == .ready); #expect(next.finishedTransactionIDs.isEmpty)
    }
    @Test(arguments: [TipPurchaseOutcome.cancelled, .pending, .failed(message: "Unverified purchase")])
    func nonVerifiedPurchaseNeverFinishesOrWritesTraining(outcome: TipPurchaseOutcome) async throws {
        let harness = try await RepositoryTestHarness.make(goal: .size)
        let before = try BackupService.bytes(await harness.repository.exportBackup())
        let fake = FakeTipPurchaser(outcome: outcome), store = store(fake)
        await store.load(); await store.tip(productID: productID)
        switch outcome {
        case .cancelled: #expect(store.state == .idle)
        case .pending: #expect(store.state == .pending)
        case .failed: #expect(store.state == .failed)
        default: Issue.record("Unexpected fixture")
        }
        #expect(fake.finishedTransactionIDs.isEmpty)
        #expect(try BackupService.bytes(await harness.repository.exportBackup()) == before)
        await harness.repository.close()
    }
    @Test func pendingRemainsUnderstandableWhenPageReloads() async {
        let fake = FakeTipPurchaser(outcome: .pending), store = store(fake)
        await store.load(); await store.tip(productID: productID); await store.load()
        #expect(store.state == .pending); #expect(fake.finishedTransactionIDs.isEmpty)
    }
    @Test func interruptedHandlingRetriesFinishAfterRelaunchWithoutSecondThankYou() async throws {
        let tip = VerifiedTip(transactionID: 42, productID: productID), url = cacheURL()
        let first = FakeTipPurchaser(outcome: .verifiedTip(tip)); first.finishFails = true
        let original = store(first, at: url)
        await original.load(); await original.tip(productID: productID)
        #expect(original.state == .thankYou)
        #expect(try TipReceiptCache(url: url).status(transactionID: 42) == .finishPending)
        let next = FakeTipPurchaser(), relaunched = store(next, at: url)
        next.delivery.yield(tip) // unfinished startup delivery may precede store subscription
        try await settle { next.finishedTransactionIDs == [42] }
        try await settle { (try? TipReceiptCache(url: url).status(transactionID: 42)) == .finished }
        #expect(relaunched.state != .thankYou)
    }
    @Test func handledBoundaryBeforeFinishPendingStillRetries() async throws {
        let url = cacheURL(), cache = try TipReceiptCache(url: url)
        try cache.recordHandled(VerifiedTip(transactionID: 42, productID: productID))
        let fake = FakeTipPurchaser(), relaunched = store(fake, at: url)
        fake.delivery.yield(VerifiedTip(transactionID: 42, productID: productID))
        try await settle { fake.finishedTransactionIDs == [42] }
        #expect(relaunched.state != .thankYou)
    }
    @Test func concurrentDuplicateWhileFinishWaitsIsCoalesced() async throws {
        let tip = VerifiedTip(transactionID: 42, productID: productID)
        let fake = FakeTipPurchaser(outcome: .verifiedTip(tip)); fake.suspendFinish = true
        let store = store(fake); await store.load()
        let purchase = Task { await store.tip(productID: productID) }
        try await settle { fake.finishSuspension != nil }
        fake.delivery.yield(tip); fake.delivery.yield(tip)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.finishedTransactionIDs == [42])
        fake.finishSuspension?.resume(); await purchase.value
        #expect(store.state == .thankYou)
    }
    @Test func unavailableProductsHaveNoPricesAndDoNotLeaseTraining() async throws {
        let harness = try await RepositoryTestHarness.make(goal: .size)
        let model = WorkoutViewModel(repository: harness.repository, snapshot: try await harness.repository.snapshot(programID: harness.programID), timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791316800) })
        let fake = FakeTipPurchaser(); fake.loadFails = true
        let store = store(fake), composition = AppComposition(repository: harness.repository, workout: model, tipStore: store)
        let before = try BackupService.bytes(await harness.repository.exportBackup())
        await store.load()
        #expect(store.state == .failed); #expect(store.products.isEmpty)
        #expect(!composition.busy); #expect(composition.workout === model)
        #expect(try BackupService.bytes(await harness.repository.exportBackup()) == before)
        await harness.repository.close()
    }
    @Test func receiptWriteFailureNeverFinishesOrThanks() async throws {
        let url = cacheURL(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt synthetic cache".utf8).write(to: url)
        let fake = FakeTipPurchaser(outcome: .verifiedTip(.init(transactionID: 42, productID: productID))), store = store(fake, at: url)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .failed); #expect(fake.finishedTransactionIDs.isEmpty)
        #expect(try Data(contentsOf: url) == Data("corrupt synthetic cache".utf8))
    }
    @Test func foreignProductCannotBeAcknowledged() async throws {
        let fake = FakeTipPurchaser(outcome: .verifiedTip(.init(transactionID: 42, productID: "synthetic.other"))), store = store(fake)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .failed); #expect(fake.finishedTransactionIDs.isEmpty)
    }
    @Test func tipLeavesPortableBackupStagedExportAndCloudOutboxIdentical() async throws {
        let harness = try await RepositoryTestHarness.make(goal: .size)
        let document = try await harness.repository.exportBackup()
        let scope = CloudScope(containerIdentifier: "synthetic-tips", environment: .development, accountIdentifier: "synthetic")
        try await harness.repository.bindDataset(datasetID: UUID(uuidString: document.datasetID)!, to: scope)
        let outbox = try await harness.repository.pendingCloudRecords(scope: scope)
        let before = try BackupService.bytes(document)
        let staged = try BackupService.bytes(await harness.repository.stagedRecoveryOriginals())
        let fake = FakeTipPurchaser(outcome: .verifiedTip(.init(transactionID: 42, productID: productID))), store = store(fake)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .thankYou)
        #expect(try BackupService.bytes(await harness.repository.exportBackup()) == before)
        #expect(try BackupService.bytes(await harness.repository.stagedRecoveryOriginals()) == staged)
        let afterOutbox = try await harness.repository.pendingCloudRecords(scope: scope)
        #expect(afterOutbox.map(\.recordID) == outbox.map(\.recordID))
        #expect(afterOutbox.map(\.payload) == outbox.map(\.payload))
        await harness.repository.close()
    }
}
