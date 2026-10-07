import Foundation

/// Commerce-only receipts. Never a training journal, entitlement or backup payload.
@MainActor final class TipReceiptCache {
    enum Status: String, Codable { case handled, finishPending, finished }
    private struct Receipt: Codable { let productID: String; var status: Status }
    private struct Document: Codable { var version = 1; var receipts: [String: Receipt] = [:] }
    private let url: URL
    private var document: Document
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1,
                  document.receipts.allSatisfy({ UInt64($0.key) != nil && TipProduct.identifiers.contains($0.value.productID) }) else { throw CacheError.invalid }
        } else { document = Document() }
    }
    func status(transactionID: UInt64) -> Status? { document.receipts[String(transactionID)]?.status }
    func recordHandled(_ tip: VerifiedTip) throws {
        if let existing = document.receipts[String(tip.transactionID)] {
            guard existing.productID == tip.productID else { throw CacheError.invalid }
            return
        }
        var next = document
        next.receipts[String(tip.transactionID)] = Receipt(productID: tip.productID, status: .handled)
        try save(next)
    }
    func mark(_ status: Status, transactionID: UInt64) throws {
        guard document.receipts[String(transactionID)] != nil else { throw CacheError.invalid }
        var next = document; next.receipts[String(transactionID)]?.status = status
        try save(next)
    }
    private func save(_ next: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        document = next // In-memory authority advances only after the durable write.
    }
    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlentyStrong-Commerce", isDirectory: true).appendingPathComponent("receipts-v1.json")
    }
    private enum CacheError: Error { case invalid }
}
