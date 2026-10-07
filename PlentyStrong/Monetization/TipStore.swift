import Foundation
import Observation

@MainActor @Observable final class TipStore {
    private(set) var state: TipUIState = .idle
    private(set) var products: [TipProduct] = []
    private(set) var message: String?
    @ObservationIgnored private let purchaser: any TipPurchasing
    @ObservationIgnored private var cache: TipReceiptCache?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var handling: Set<UInt64> = []
    @ObservationIgnored private var purchaseInFlight = false
    @ObservationIgnored private var loadInFlight = false

    init(purchaser: any TipPurchasing, receiptURL: URL? = nil) {
        self.purchaser = purchaser
        do { cache = try TipReceiptCache(url: receiptURL ?? TipReceiptCache.defaultURL()) }
        catch { message = String(localized: "Tip receipts could not be opened. Your training is available."); state = .failed }
        let stream = purchaser.verifiedTransactions
        listener = Task { [weak self] in
            for await tip in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(tip)
            }
        }
    }
    deinit { listener?.cancel() }

    func load() async {
        guard !loadInFlight, !purchaseInFlight else { return }
        guard cache != nil else { state = .failed; return }
        loadInFlight = true
        defer { loadInFlight = false }
        if state != .pending { state = .loading; message = nil }
        do {
            let loaded = try await purchaser.products()
            products = TipProduct.identifiers.compactMap { id in loaded.first { $0.id == id } }
            guard !products.isEmpty else { throw ProductError.unavailable }
            // A startup transaction may have been acknowledged during product loading.
            if state == .loading { state = .ready }
        } catch {
            products = []
            if state == .loading { state = .failed; message = String(localized: "Tips are unavailable right now. All training features and backups are free.") }
        }
    }
    func tip(productID: String) async {
        guard !purchaseInFlight, !loadInFlight else { return }
        guard cache != nil, products.contains(where: { $0.id == productID }) else {
            state = .failed; message = String(localized: "Tips are unavailable right now. All training features and backups are free."); return
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        state = .purchasing; message = nil
        switch await purchaser.purchase(id: productID) {
        case let .verifiedTip(tip): await handle(tip)
        case .pending: state = .pending
        case .cancelled: state = .idle
        case let .failed(text): state = .failed; message = text
        }
    }
    private func handle(_ tip: VerifiedTip) async {
        guard TipProduct.identifiers.contains(tip.productID), let cache else {
            state = .failed; message = String(localized: "The tip could not be verified. Your training is available."); return
        }
        guard !handling.contains(tip.transactionID) else { return }
        handling.insert(tip.transactionID)
        defer { handling.remove(tip.transactionID) }
        do {
            let first = cache.status(transactionID: tip.transactionID) == nil
            try cache.recordHandled(tip)
            guard cache.status(transactionID: tip.transactionID) != .finished else { return }
            try cache.mark(.finishPending, transactionID: tip.transactionID)
            if first { state = .thankYou; message = nil }
            // Durable acknowledgement precedes external finish. A failure leaves a retry
            // receipt for the next unfinished/update delivery; it cannot grant a benefit.
            do {
                try await purchaser.finishVerified(transactionID: tip.transactionID)
                try cache.mark(.finished, transactionID: tip.transactionID)
            } catch {
                // Failed external finish is retried through unfinished delivery. If
                // only the final cache write failed, handled still deduplicates thanks.
            }
        } catch {
            state = .failed; message = String(localized: "The tip receipt could not be saved. Your training is available.")
        }
    }
    private enum ProductError: Error { case unavailable }
}
