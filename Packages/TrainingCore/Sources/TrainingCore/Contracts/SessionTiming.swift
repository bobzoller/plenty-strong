import Foundation

/// UTC integer milliseconds keep timing exact under the canonical JSON contract.
/// The session date is the real start date in the frozen timezone; midnight Keep
/// original retains that date while Finish still records its own real instant.
public struct SessionTiming: Codable, Equatable, Sendable {
    public var plannedDate: LocalDate
    public var startedAtMilliseconds: Int64
    public var finishedAtMilliseconds: Int64
    public var timeZoneID: String

    public init(plannedDate: LocalDate, startedAtMilliseconds: Int64, finishedAtMilliseconds: Int64, timeZoneID: String) {
        self.plannedDate = plannedDate
        self.startedAtMilliseconds = startedAtMilliseconds
        self.finishedAtMilliseconds = finishedAtMilliseconds
        self.timeZoneID = timeZoneID
    }

    public static func milliseconds(at instant: Date) throws -> Int64 {
        guard instant.timeIntervalSince1970.isFinite, (.distantPast ... Date.distantFuture).contains(instant) else {
            throw EngineError(code: "invalid_session_timing", field: "instant")
        }
        return Int64(floor(instant.timeIntervalSince1970 * 1_000))
    }

    public static func localDate(milliseconds: Int64, timeZoneID: String) throws -> LocalDate {
        let instant = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        guard (.distantPast ... Date.distantFuture).contains(instant) else {
            throw EngineError(code: "invalid_session_timing", field: "instant")
        }
        return try CalendarContext(timeZoneID: timeZoneID).localDate(at: instant)
    }

    public func validate(sessionDate: LocalDate, plannedDate: LocalDate) throws -> LocalDate {
        guard self.plannedDate == plannedDate, finishedAtMilliseconds >= startedAtMilliseconds,
              try Self.localDate(milliseconds: startedAtMilliseconds, timeZoneID: timeZoneID) == sessionDate else {
            throw EngineError(code: "invalid_session_timing", field: "timing")
        }
        return try Self.localDate(milliseconds: finishedAtMilliseconds, timeZoneID: timeZoneID)
    }
}
