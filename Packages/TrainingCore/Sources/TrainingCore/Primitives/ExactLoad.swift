import Foundation

public struct ExactLoad: Equatable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidCanonicalAmount
        case unrepresentableAmount
        case inexactArithmetic
    }

    public let canonicalAmount: String
    private let amount: Decimal

    public init(canonicalAmount: String) throws {
        // ASCII decimal syntax; no signs, exponent, leading zeros, or trailing fractional zeros.
        guard canonicalAmount.range(of: #"^(?:[1-9][0-9]*|0)(?:\.[0-9]*[1-9])?$"#, options: .regularExpression) != nil,
              canonicalAmount != "0" else {
            throw ValidationError.invalidCanonicalAmount
        }
        let locale = Locale(identifier: "en_US_POSIX")
        guard var parsed = Decimal(string: canonicalAmount, locale: locale),
              !parsed.isNaN, parsed > 0,
              NSDecimalString(&parsed, locale) == canonicalAmount else {
            throw ValidationError.unrepresentableAmount
        }
        self.canonicalAmount = canonicalAmount
        amount = parsed
    }

    /// A strictly higher load is allowed iff next * 10 <= current * 11, with no rounding.
    public func allowsIncrease(to next: ExactLoad) throws -> Bool {
        guard next.amount > amount else { return false }
        let candidate = try Self.multiply(next.amount, by: 10)
        let ceiling = try Self.multiply(amount, by: 11)
        return candidate <= ceiling
    }

    private static func multiply(_ value: Decimal, by factor: Int) throws -> Decimal {
        var left = value
        var right = Decimal(factor)
        var result = Decimal()
        guard NSDecimalMultiply(&result, &left, &right, .plain) == .noError,
              !result.isNaN else {
            throw ValidationError.inexactArithmetic
        }
        return result
    }
}
