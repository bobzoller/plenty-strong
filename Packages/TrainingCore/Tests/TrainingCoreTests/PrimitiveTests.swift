import Foundation
import Testing
@testable import TrainingCore

struct PrimitiveTests {
    @Test func archivedProfileHashMatchesRawDocument() throws {
        guard case .object(var profile) = try rawDocument("2026-10-05-fixed-exercise-profile.json") else {
            Issue.record("Expected profile object")
            return
        }
        profile.removeValue(forKey: "contentHash")
        #expect(try CanonicalJSON.sha256(.object(profile)) == "508cff9a8cc292defccd8c017da28af28007942946d268b8468f6c5a6cc8bb15")
    }

    @Test func archivedRulesHashMatchesRawDocument() throws {
        guard case .object(let root) = try rawDocument("2026-10-05-general-fitness-progression-examples.json"),
              case .object(let input) = root["baseInput"],
              case .object(var rules) = input["rules"] else {
            Issue.record("Expected frozen rules object")
            return
        }
        rules.removeValue(forKey: "hash")
        #expect(try CanonicalJSON.sha256(.object(rules)) == "cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb")
    }

    @Test func objectInsertionOrderDoesNotChangeCanonicalBytes() throws {
        let first: CanonicalValue = .object(["z": .integer(1), "a": .array([.bool(true), .null])])
        let second: CanonicalValue = .object(["a": .array([.bool(true), .null]), "z": .integer(1)])
        #expect(try CanonicalJSON.encode(first) == Data(#"{"a":[true,null],"z":1}"#.utf8))
        #expect(try CanonicalJSON.encode(first) == CanonicalJSON.encode(second))
    }

    @Test func arraysPreserveOrder() throws {
        #expect(try CanonicalJSON.encode(.array([.integer(1), .integer(2)])) != CanonicalJSON.encode(.array([.integer(2), .integer(1)])))
    }

    @Test func objectKeysUseUnicodeScalarOrder() throws {
        let value: CanonicalValue = .object(["\u{10000}": .integer(2), "\u{E000}": .integer(1)])
        #expect(try CanonicalJSON.encode(value) == Data("{\"\u{E000}\":1,\"\u{10000}\":2}".utf8))
    }

    @Test func unicodeIsUTF8AndIsNotNormalized() throws {
        #expect(try CanonicalJSON.encode(.string("é🙂")) == Data("\"é🙂\"".utf8))
        #expect(try CanonicalJSON.encode(.string("e\u{301}")) == Data("\"e\u{301}\"".utf8))
        #expect(try CanonicalJSON.encode(.string("é")) != CanonicalJSON.encode(.string("e\u{301}")))
    }

    @Test func stringEscapesMatchPythonCanonicalJSON() throws {
        #expect(try CanonicalJSON.encode(.string("\"\\/\n\r\t\u{8}\u{C}\u{0}\u{1F}")) == Data(#""\"\\/\n\r\t\b\f\u0000\u001f""#.utf8))
    }

    @Test func integerLimitsEncodeWithoutFloatingPoint() throws {
        #expect(try CanonicalJSON.encode(.array([.integer(.min), .integer(.max)])) == Data("[-9223372036854775808,9223372036854775807]".utf8))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CanonicalValue.self, from: Data("1.5".utf8)) }
    }

    @Test func tenPercentBoundaryIsExact() throws {
        let current = try ExactLoad(canonicalAmount: "40")
        #expect(try current.allowsIncrease(to: ExactLoad(canonicalAmount: "44")))
        #expect(try !current.allowsIncrease(to: ExactLoad(canonicalAmount: "44.004")))
        #expect(try ExactLoad(canonicalAmount: "50").allowsIncrease(to: ExactLoad(canonicalAmount: "55")))
        #expect(try !ExactLoad(canonicalAmount: "15").allowsIncrease(to: ExactLoad(canonicalAmount: "20")))
    }

    @Test func fractionalBoundaryDoesNotUseBinaryFloatingPoint() throws {
        #expect(try ExactLoad(canonicalAmount: "0.1").allowsIncrease(to: ExactLoad(canonicalAmount: "0.11")))
        #expect(try !ExactLoad(canonicalAmount: "0.1").allowsIncrease(to: ExactLoad(canonicalAmount: "0.11000000000000000000000000000000000001")))
    }

    @Test func equalOrLowerLoadsAreNotIncreases() throws {
        let current = try ExactLoad(canonicalAmount: "40")
        #expect(try !current.allowsIncrease(to: current))
        #expect(try !current.allowsIncrease(to: ExactLoad(canonicalAmount: "39")))
    }

    @Test(arguments: ["", "0", "-1", "+1", "01", ".5", "1.", "1.0", "0.00", "1e2", " 1", "1 ", "NaN", "Infinity", "１"])
    func malformedOrNonpositiveLoadsAreRejected(_ amount: String) {
        #expect(throws: (any Error).self) { try ExactLoad(canonicalAmount: amount) }
    }

    @Test func decimalOverflowAndPrecisionLossAreRejected() {
        #expect(throws: (any Error).self) { try ExactLoad(canonicalAmount: String(repeating: "9", count: 200)) }
        #expect(throws: (any Error).self) { try ExactLoad(canonicalAmount: "1.123456789012345678901234567890123456789123456789") }
        #expect(throws: (any Error).self) { try ExactLoad(canonicalAmount: "0." + String(repeating: "0", count: 200) + "1") }
    }

    @Test func decimalOperationOverflowIsRejected() throws {
        let current = try ExactLoad(canonicalAmount: "8" + String(repeating: "9", count: 37) + String(repeating: "0", count: 127))
        let next = try ExactLoad(canonicalAmount: String(repeating: "9", count: 38) + String(repeating: "0", count: 127))
        #expect(throws: (any Error).self) { try current.allowsIncrease(to: next) }
    }

    @Test(arguments: ["2026-02-30", "2025-02-29", "1900-02-29", "2026-13-01", "2026-01-00", "0000-01-01", "2026-2-01", "2026-01-01T00:00:00Z", " 2026-01-01"])
    func invalidLocalDatesAreRejected(_ date: String) {
        #expect(throws: (any Error).self) { try LocalDate(iso8601: date) }
    }

    @Test func calendarArithmeticUsesDaysAcrossLeapAndYearBoundaries() throws {
        #expect(try LocalDate(iso8601: "2000-02-28").adding(days: 1) == LocalDate(iso8601: "2000-02-29"))
        #expect(try LocalDate(iso8601: "1900-02-28").adding(days: 1) == LocalDate(iso8601: "1900-03-01"))
        #expect(try LocalDate(iso8601: "2026-01-01").adding(days: -1) == LocalDate(iso8601: "2025-12-31"))
        #expect(try LocalDate(iso8601: "1582-10-04").adding(days: 1) == LocalDate(iso8601: "1582-10-05"))
    }

    @Test func interruptionDifferenceIsCalendarBasedIncludingDSTDates() throws {
        let start = try LocalDate(iso8601: "2026-03-01")
        let end = try LocalDate(iso8601: "2026-03-29")
        #expect(start.days(until: end) == 28)
        #expect(end.days(until: start) == -28)
        #expect(start < end)
    }

    @Test func localDateCodableUsesValidatedISOString() throws {
        let date = try LocalDate(iso8601: "2026-10-06")
        #expect(try JSONEncoder().encode(date) == Data(#""2026-10-06""#.utf8))
        #expect(try JSONDecoder().decode(LocalDate.self, from: Data(#""2026-10-06""#.utf8)) == date)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalDate.self, from: Data(#""2026-02-30""#.utf8)) }
    }

    @Test func dateAdditionRejectsRangeAndIntegerOverflow() throws {
        #expect(throws: (any Error).self) { try LocalDate(iso8601: "0001-01-01").adding(days: -1) }
        #expect(throws: (any Error).self) { try LocalDate(iso8601: "9999-12-31").adding(days: 1) }
        #expect(throws: (any Error).self) { try LocalDate(iso8601: "2026-01-01").adding(days: .max) }
    }

    private func rawDocument(_ filename: String) throws -> CanonicalValue {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("docs/specs/" + filename))
        return try JSONDecoder().decode(CanonicalValue.self, from: data)
    }
}
