import Foundation
import CoreFoundation

/// Finite data conversions and RFC6901 pointers; no formulas or executable policy.
func validateMigrationSourceBindings(_ archive: ExternalSourceArchive) throws {
    func invalid(_ field: String) -> EngineError { EngineError(code: "invalid_migration", field: "source_binding." + field) }
    let target = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive))
    var sources: [String: Any] = [:]
    var covered = Set<String>()
    let aggregatePointers: Set<String> = ["/baselines", "/workouts", "/sourceState"]
    for binding in archive.sourceBindings {
        guard covered.insert(binding.targetPointer).inserted,
              let file = archive.files.first(where: { $0.name == binding.fileName }) else { throw invalid("identity") }
        guard !aggregatePointers.contains(binding.targetPointer) || binding.conversion == "exact" else { throw invalid("aggregate_conversion") }
        if sources[file.name] == nil { sources[file.name] = try JSONSerialization.jsonObject(with: file.bytes) }
        let value = try migrationPointer(binding.sourcePointer, in: sources[file.name]!)
        let converted: Any
        switch binding.conversion {
        case "exact": converted = value
        case "string", "decimal":
            guard let text = migrationScalarString(value) else { throw invalid("string") }
            if binding.conversion == "decimal", (try? ExactLoad(canonicalAmount: text)) == nil { throw invalid("decimal") }
            converted = text
        case "integer":
            guard let text = migrationScalarString(value), let number = Int64(text) else { throw invalid("integer") }
            converted = NSNumber(value: number)
        case "integer_vector":
            let items: [Any]
            if let array = value as? [Any] { items = array }
            else if let string = value as? String { items = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
            else { throw invalid("vector") }
            converted = try items.map { item -> NSNumber in
                guard let text = migrationScalarString(item), let number = Int64(text), number > 0 else { throw invalid("vector") }
                return NSNumber(value: number)
            }
        case "minimum_rir":
            guard let text = value as? String else { throw invalid("minimum_rir") }
            if text.isEmpty { converted = NSNumber(value: 2) }
            else {
                guard let first = text.first, let number = first.wholeNumberValue, number >= 2,
                      text == "\(number)+" || text == "\(number)" || text == "\(number)–\(number + 1)" || text == "\(number)-\(number + 1)" else { throw invalid("minimum_rir") }
                converted = NSNumber(value: number)
            }
        case "boolean":
            if let string = value as? String, ["TRUE", "FALSE"].contains(string) { converted = NSNumber(value: string == "TRUE") }
            else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { converted = number }
            else { throw invalid("boolean") }
        case "load_unit":
            guard let text = value as? String, ["lb/hand", "lb", "kg/hand", "kg"].contains(text) else { throw invalid("load_unit") }
            converted = String(text.prefix(2))
        case "load_basis":
            guard let text = value as? String, ["lb/hand", "kg/hand", "lb total", "kg total"].contains(text) else { throw invalid("load_basis") }
            converted = text.hasSuffix("/hand") ? "per_implement" : "total"
        default: throw invalid("conversion")
        }
        let expected = try migrationPointer(binding.targetPointer, in: target)
        let a = try JSONSerialization.data(withJSONObject: converted, options: [.sortedKeys, .fragmentsAllowed])
        let b = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .fragmentsAllowed])
        guard a == b else { throw invalid("mismatch") }
    }
    // Bind shape and completeness as well as individual typed values. Otherwise
    // deleting a projection also deletes the fields from which coverage derives.
    var required = aggregatePointers
    for (i, row) in archive.baselines.enumerated() {
        for key in ["baseMovementID", "variantID", "modifications", "recoveryStatus", "sourceKeys", "targets", "sourceRepFloor", "sourceRepCeiling", "minimumRir", "safetyText", "reviewRequired", "paused", "recoveryRequired"] { required.insert("/baselines/\(i)/\(key)") }
        if row.load != nil { for key in ["amount", "unit", "basis"] { required.insert("/baselines/\(i)/load/\(key)") } }
        if row.unresolvedLoadAmount != nil { required.insert("/baselines/\(i)/unresolvedLoadAmount") }
    }
    for (i, workout) in archive.workouts.enumerated() {
        required.insert("/workouts/\(i)/date")
        required.insert("/workouts/\(i)/sourceKey")
        for j in workout.rows.indices {
            required.insert("/workouts/\(i)/rows/\(j)/sourceKey")
            required.insert("/workouts/\(i)/rows/\(j)/raw")
            required.insert("/workouts/\(i)/rows/\(j)/movementLabel")
        }
    }
    guard required.isSubset(of: covered) else { throw invalid("coverage") }
}

private func migrationScalarString(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
    return nil
}

private func migrationPointer(_ pointer: String, in object: Any) throws -> Any {
    guard pointer.hasPrefix("/") else { throw EngineError(code: "invalid_migration", field: "source_binding.pointer") }
    var current = object
    for encoded in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
        guard encoded.range(of: "~(?![01])", options: .regularExpression) == nil else { throw EngineError(code: "invalid_migration", field: "source_binding.pointer") }
        let key = encoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        if let dictionary = current as? [String: Any], let value = dictionary[key] { current = value }
        else if let array = current as? [Any], let index = Int(key), String(index) == key, array.indices.contains(index) { current = array[index] }
        else { throw EngineError(code: "invalid_migration", field: "source_binding.pointer") }
    }
    return current
}
