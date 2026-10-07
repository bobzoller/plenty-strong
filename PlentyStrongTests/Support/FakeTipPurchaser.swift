import Foundation
@testable import PlentyStrong

@MainActor final class FakeTipPurchaser: TipPurchasing {
    var outcome: TipPurchaseOutcome
    var loadFails = false
    var finishFails = false
    var beforeFinish: (() throws -> Void)?
    var finishSuspension: CheckedContinuation<Void, Never>?
    var suspendFinish = false
    private(set) var finishedTransactionIDs: [UInt64] = []
    let verifiedTransactions: AsyncStream<VerifiedTip>
    let delivery: AsyncStream<VerifiedTip>.Continuation
    init(outcome: TipPurchaseOutcome = .cancelled) {
        self.outcome = outcome
        let stream = AsyncStream<VerifiedTip>.makeStream()
        verifiedTransactions = stream.stream; delivery = stream.continuation
    }
    func products() async throws -> [TipProduct] {
        if loadFails { throw Failure.synthetic }
        return [TipProduct(id: "us.zoller.PlentyStrong.tip.small", displayName: "Small tip", displayPrice: "$0.99"),
                TipProduct(id: "us.zoller.PlentyStrong.tip.medium", displayName: "Medium tip", displayPrice: "$2.99"),
                TipProduct(id: "us.zoller.PlentyStrong.tip.large", displayName: "Large tip", displayPrice: "$4.99")]
    }
    func purchase(id: String) async -> TipPurchaseOutcome { outcome }
    func finishVerified(transactionID: UInt64) async throws {
        finishedTransactionIDs.append(transactionID)
        try beforeFinish?()
        if suspendFinish { await withCheckedContinuation { finishSuspension = $0 } }
        if finishFails { throw Failure.synthetic }
    }
    enum Failure: Error { case synthetic }
}
