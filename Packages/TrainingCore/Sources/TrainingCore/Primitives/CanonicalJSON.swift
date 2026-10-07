import CryptoKit
import Foundation

/// The archived hash contract has no floating-point JSON values.
public indirect enum CanonicalValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CanonicalValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: CanonicalValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected canonical JSON without floating-point numbers")
        }
    }
}

public enum CanonicalJSON {
    /// Python-compatible compact JSON, with scalar-sorted keys and unnormalized UTF-8.
    public static func encode(_ value: CanonicalValue) throws -> Data {
        Data(render(value).utf8)
    }

    public static func sha256(_ value: CanonicalValue) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func render(_ value: CanonicalValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .string(let value): quote(value)
        case .array(let values): "[" + values.map(render).joined(separator: ",") + "]"
        case .object(let values):
            "{" + values.sorted {
                $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars)
            }.map { quote($0.key) + ":" + render($0.value) }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0c: result += "\\f"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
