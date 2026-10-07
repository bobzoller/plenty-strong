import Foundation
import Testing
@testable import TrainingCore

struct VariantContractTests {
    @Test func defaultsAreDeterministicAndOnePerBase() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let config = try selectFixedProgram(goal: .size, programID: id)
        #expect(config.variants?.count == 12)
        #expect(config.activeVariantIDs?.count == 12)
        for movement in config.movements {
            let expected = try CanonicalJSON.sha256(.array([.string("movement-variant-v1"), .string(config.programID), .string(movement.id), .string("default")]))
            #expect(config.activeVariantIDs?[movement.id] == expected)
            #expect(config.variants?[expected] == MovementVariant(id: expected, baseMovementID: movement.id, modifications: ""))
        }
    }

    @Test func variantIntegrityAndTextRejects() throws {
        let rules = try RulesetCatalog.fixedV1()
        let original = try selectFixedProgram(goal: .size, programID: UUID())
        for mutate in [
            { (c: inout ProgramConfig) in c.activeVariantIDs?[c.movements[0].id] = "unknown" },
            { (c: inout ProgramConfig) in let selected = c.activeVariantIDs?[c.movements[1].id]; c.activeVariantIDs?[c.movements[0].id] = selected },
            { (c: inout ProgramConfig) in let variant = c.variants!.values.first!; c.variants?["alias"] = variant },
            { (c: inout ProgramConfig) in c.variants?[c.activeVariantIDs![c.movements[0].id]!]!.modifications = "changed default" },
            { (c: inout ProgramConfig) in c.variants?["new"] = MovementVariant(id: "new", baseMovementID: "unknown", modifications: "setup") },
            { (c: inout ProgramConfig) in c.variants?["new"] = MovementVariant(id: "new", baseMovementID: c.movements[0].id, modifications: "") },
            { (c: inout ProgramConfig) in c.variants?["new"] = MovementVariant(id: "new", baseMovementID: c.movements[0].id, modifications: " untrimmed ") },
            { (c: inout ProgramConfig) in c.variants?["new"] = MovementVariant(id: "new", baseMovementID: c.movements[0].id, modifications: String(repeating: "👨‍👩‍👧", count: 201)) }
        ] {
            var config = original
            mutate(&config)
            #expect(throws: EngineError.self) { try validate(config: config, rules: rules) }
        }
    }

    @Test func descriptionsAreOpaqueAndSelectionKeepsRoutine() throws {
        var config = try selectFixedProgram(goal: .maintenance, programID: UUID())
        let originalSlots = config.weeklySlots
        let baseID = "banded_pullups"
        config.variants?["saved"] = MovementVariant(id: "saved", baseMovementID: baseID, modifications: "+25 lb; 35 lb assistance")
        config.activeVariantIDs?[baseID] = "saved"
        try validate(config: config, rules: RulesetCatalog.fixedV1())
        #expect(config.weeklySlots == originalSlots)
        #expect(config.movements.first { $0.id == baseID }?.availableLoads == [])
        config.variants?["saved"]?.modifications = String(repeating: "e\u{301}", count: 200)
        try validate(config: config, rules: RulesetCatalog.fixedV1())
    }
}
