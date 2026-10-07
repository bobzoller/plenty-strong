import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import PlentyStrong

/// Real Xcode-local StoreKit, never sandbox/App Store Connect proof.
@Suite(.serialized) @MainActor struct StoreKitTipPurchaserTests {
    let productID = "us.zoller.PlentyStrong.tip.small"
    func session() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        return session
    }
    func receiptURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("receipts.json") }
    func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate())
    }
    @Test func hostedSyntheticCompositionNeverCompetesWithLocalTestPurchaser() async throws {
        let session = try session(); defer { session.clearTransactions() }
        let composition = AppComposition()
        await composition.tips.load()
        #expect(composition.tips.products.isEmpty)
        #expect(composition.tips.state == .failed)
    }
    @Test func localConsumablesUseStoreKitNamesPricesAndFinishVerifiedPurchase() async throws {
        let session = try session(); defer { session.clearTransactions() }
        let purchaser = StoreKitTipPurchaser(), url = receiptURL(), store = TipStore(purchaser: purchaser, receiptURL: url)
        await store.load()
        #expect(store.products.count == 3)
        #expect(store.products.first?.displayName == "Small tip"); #expect(store.products.first?.displayPrice == "$0.99")
        await store.tip(productID: productID)
        #expect(store.state == .thankYou)
        let transaction = try #require(session.allTransactions().first)
        #expect(try TipReceiptCache(url: url).status(transactionID: UInt64(transaction.identifier)) == .finished)
        var unfinished = 0; for await _ in Transaction.unfinished { unfinished += 1 }; #expect(unfinished == 0)
    }
    @Test func localProductNetworkFailureRemovesPricesWithoutReceipt() async throws {
        let session = try session(); defer { session.clearTransactions() }
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let url = receiptURL(), store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        await store.load()
        #expect(store.products.isEmpty)
        #expect(store.state == .failed); #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func localFailureDoesNotAcknowledgePurchase() async throws {
        let session = try session(); defer { session.clearTransactions() }
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        let url = receiptURL(), store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .failed); #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func localAskToBuyApprovalArrivesViaStartupListenerAndFinishes() async throws {
        let session = try session(); defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let url = receiptURL(), store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .pending)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let pending = try #require(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await settle { store.state == .thankYou }
        try await settle { (try? TipReceiptCache(url: url).status(transactionID: UInt64(pending.identifier))) == .finished }
    }
    @Test func localUnfinishedTransactionIsHandledAtStartupWithoutProductLoading() async throws {
        let session = try session(); defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: productID)
        let url = receiptURL(), store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        try await settle { store.state == .thankYou }
        try await settle { (try? TipReceiptCache(url: url).status(transactionID: transaction.id)) == .finished }
        #expect(store.products.isEmpty)
    }
    @Test func localInterruptedReceiptRetriesExternalFinishWithoutAnotherThankYou() async throws {
        let session = try session(); defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: productID), url = receiptURL()
        let cache = try TipReceiptCache(url: url)
        try cache.recordHandled(VerifiedTip(transactionID: transaction.id, productID: productID))
        try cache.mark(.finishPending, transactionID: transaction.id)
        let store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        try await settle { (try? TipReceiptCache(url: url).status(transactionID: transaction.id)) == .finished }
        #expect(store.state != .thankYou); #expect(store.state != .failed)
        #expect(store.message == nil)
        #expect(try TipReceiptCache(url: url).status(transactionID: transaction.id) == .finished)
        var unfinished = 0; for await _ in Transaction.unfinished { unfinished += 1 }; #expect(unfinished == 0)
    }
    @Test func localUnverifiedTransactionIsIgnoredAndNotFinished() async throws {
        let session = try session(); defer { session.clearTransactions() }
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        let url = receiptURL(), store = TipStore(purchaser: StoreKitTipPurchaser(), receiptURL: url)
        await store.load(); await store.tip(productID: productID)
        #expect(store.state == .failed); #expect(!FileManager.default.fileExists(atPath: url.path))
        var unfinished = 0; for await _ in Transaction.unfinished { unfinished += 1 }; #expect(unfinished == 1)
    }
}
