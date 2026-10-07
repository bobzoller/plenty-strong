import Foundation

/// A proleptic Gregorian calendar date (0001...9999), independent of instants/timezones.
public struct LocalDate: Comparable, Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidISODate
        case outOfRange
    }

    public let iso8601: String
    private let ordinal: Int

    public init(iso8601: String) throws {
        let bytes = Array(iso8601.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, value in
                  index == 4 || index == 7 || (48...57).contains(value)
              }),
              let year = Int(iso8601.prefix(4)),
              let month = Int(iso8601.dropFirst(5).prefix(2)),
              let day = Int(iso8601.suffix(2)),
              (1...9999).contains(year), (1...12).contains(month),
              (1...Self.monthLengths(year: year)[month - 1]).contains(day) else {
            throw ValidationError.invalidISODate
        }
        self.iso8601 = iso8601
        ordinal = Self.daysBefore(year: year) + Self.monthLengths(year: year).prefix(month - 1).reduce(0, +) + day - 1
    }

    public static func < (left: Self, right: Self) -> Bool { left.ordinal < right.ordinal }

    public func days(until other: Self) -> Int { other.ordinal - ordinal }

    public func adding(days: Int) throws -> Self {
        let (newOrdinal, overflow) = ordinal.addingReportingOverflow(days)
        guard !overflow, (0..<Self.daysBefore(year: 10000)).contains(newOrdinal) else {
            throw ValidationError.outOfRange
        }
        // Locate the year without consulting a clock, locale, timezone, or calendar cutover.
        var lower = 1
        var upper = 10000
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if Self.daysBefore(year: middle) <= newOrdinal { lower = middle }
            else { upper = middle }
        }
        var remaining = newOrdinal - Self.daysBefore(year: lower)
        var month = 1
        for length in Self.monthLengths(year: lower) {
            if remaining < length { break }
            remaining -= length
            month += 1
        }
        return try Self(iso8601: String(format: "%04d-%02d-%02d", lower, month, remaining + 1))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(iso8601: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601)
    }

    private static func daysBefore(year: Int) -> Int {
        let prior = year - 1
        return prior * 365 + prior / 4 - prior / 100 + prior / 400
    }

    private static func monthLengths(year: Int) -> [Int] {
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }
}
