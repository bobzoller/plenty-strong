import StoreKit

/// Native consumables only. No paid capabilities or restore-benefits operation.
@MainActor final class StoreKitTipPurchaser: TipPurchasing {
    let verifiedTransactions: AsyncStream<VerifiedTip>
    private let delivery: AsyncStream<VerifiedTip>.Continuation
    private var loadedProducts: [String: Product] = [:]
    private var transactions: [UInt64: Transaction] = [:]
    private var updates: Task<Void, Never>?
    private var unfinished: Task<Void, Never>?
    init() {
        let stream = AsyncStream<VerifiedTip>.makeStream()
        verifiedTransactions = stream.stream; delivery = stream.continuation
        // Register immediately at construction, independently of product/page loading.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                self?.deliver(result)
            }
        }
        unfinished = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                self?.deliver(result)
            }
        }
    }
    deinit { updates?.cancel(); unfinished?.cancel(); delivery.finish() }
    func products() async throws -> [TipProduct] {
        let products = try await Product.products(for: TipProduct.identifiers).filter { $0.type == .consumable }
        loadedProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products.map { TipProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice) }
    }
    func purchase(id: String) async -> TipPurchaseOutcome {
        guard let product = loadedProducts[id] else { return .failed(message: String(localized: "This tip is unavailable right now.")) }
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard let tip = verified(result) else { return .failed(message: String(localized: "The tip could not be verified. Your training is available.")) }
                return .verifiedTip(tip)
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .failed(message: String(localized: "This tip is unavailable right now."))
            }
        } catch { return .failed(message: String(localized: "The tip could not be completed. Please try again later.")) }
    }
    func finishVerified(transactionID: UInt64) async throws {
        guard let transaction = transactions[transactionID] else { throw FinishError.notVerified }
        await transaction.finish()
        transactions[transactionID] = nil
    }
    private func deliver(_ result: VerificationResult<Transaction>) {
        if let tip = verified(result) { delivery.yield(tip) }
    }
    private func verified(_ result: VerificationResult<Transaction>) -> VerifiedTip? {
        guard case let .verified(transaction) = result,
              transaction.productType == .consumable, TipProduct.identifiers.contains(transaction.productID),
              transaction.revocationDate == nil else { return nil }
        transactions[transaction.id] = transaction
        return VerifiedTip(transactionID: transaction.id, productID: transaction.productID)
    }
    private enum FinishError: Error { case notVerified }
}

/// Inert service for synthetic app launches; it never constructs StoreKit services.
@MainActor final class UnavailableTipPurchaser: TipPurchasing {
    let verifiedTransactions = AsyncStream<VerifiedTip> { $0.finish() }
    func products() async throws -> [TipProduct] { throw Unavailable.offline }
    func purchase(id: String) async -> TipPurchaseOutcome { .failed(message: String(localized: "This tip is unavailable right now.")) }
    func finishVerified(transactionID: UInt64) async throws { throw Unavailable.offline }
    private enum Unavailable: Error { case offline }
}
