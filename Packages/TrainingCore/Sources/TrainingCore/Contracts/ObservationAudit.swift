import Foundation

/// Ordered saved-set corrections. Raw originals remain distinct from effective
/// observations; only the latter are consumed by progression.
public struct ObservationAudit: Codable, Equatable, Sendable {
    public var version: Int
    public var corrections: [SetCorrection]

    public init(version: Int = 1, corrections: [SetCorrection]) {
        self.version = version
        self.corrections = corrections
    }
}

public struct SetCorrection: Codable, Equatable, Sendable {
    public var operationID: UUID
    public var movementID: String
    public var setIndex: Int
    public var before: ActualSet
    public var after: ActualSet
    public var beforeStatus: LogStatus
    public var afterStatus: LogStatus
    public var outcomeAcknowledged: Bool

    public init(operationID: UUID, movementID: String, setIndex: Int, before: ActualSet, after: ActualSet,
                beforeStatus: LogStatus, afterStatus: LogStatus, outcomeAcknowledged: Bool) {
        self.operationID = operationID
        self.movementID = movementID
        self.setIndex = setIndex
        self.before = before
        self.after = after
        self.beforeStatus = beforeStatus
        self.afterStatus = afterStatus
        self.outcomeAcknowledged = outcomeAcknowledged
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case movementID = "movementId"
        case setIndex, before, after, beforeStatus, afterStatus, outcomeAcknowledged
    }
}
