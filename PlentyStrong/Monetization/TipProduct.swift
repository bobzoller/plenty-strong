import Foundation

struct TipProduct: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let displayPrice: String
    static let identifiers = ["us.zoller.PlentyStrong.tip.small", "us.zoller.PlentyStrong.tip.medium", "us.zoller.PlentyStrong.tip.large"]
}
struct VerifiedTip: Equatable, Sendable { let transactionID: UInt64; let productID: String }
enum TipPurchaseOutcome: Equatable, Sendable {
    case verifiedTip(VerifiedTip), pending, cancelled, failed(message: String)
}
enum TipUIState: Equatable { case idle, loading, ready, purchasing, pending, thankYou, failed }
@MainActor protocol TipPurchasing: AnyObject {
    func products() async throws -> [TipProduct]
    func purchase(id: String) async -> TipPurchaseOutcome
    var verifiedTransactions: AsyncStream<VerifiedTip> { get }
    func finishVerified(transactionID: UInt64) async throws
}
