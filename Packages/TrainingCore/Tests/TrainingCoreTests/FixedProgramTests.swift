import Foundation
import Testing
@testable import TrainingCore

struct FixedProgramTests {
    let programID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test func allGoalsKeepFrozenSplitAndNullLoads() throws {
        let source = try archivedProfile()
        for goal in Goal.allCases {
            let config = try selectFixedProgram(goal: goal, programID: programID)
            #expect(config.daysPerWeek == 3)
            #expect(config.movements.count == 12)
            #expect(config.weeklySlots.map(\.id) == ["SUN", "TUE", "THU"])
            #expect(config.weeklySlots.compactMap(\.weekday) == [0, 2, 4])
            #expect(config.weeklySlots.flatMap(\.movementIDs).count == 15)
            #expect(config.weeklySlots == source.weeklySlots)
            #expect(config.initialLoads.count == 12)
            #expect(config.initialLoads.values.allSatisfy { $0 == nil })
            #expect(config.movements.filter { $0.loadingMode == .externalLoad }.count == 9)
            #expect(config.movements.filter { $0.availableLoads.isEmpty }.count == 3)
            for movement in config.movements where movement.loadingMode == .externalLoad {
                #expect(movement.availableLoads.map(\.amount) == stride(from: 5, through: 80, by: 5).map(String.init))
            }
            try validate(config: config, rules: RulesetCatalog.fixedV1())
            #expect(config.muscleExposureCounts["quads"] == 1)
        }
    }

    @Test func strengthPermissionsAndLoadBasis() throws {
        let config = try selectFixedProgram(goal: .strength, programID: programID)
        #expect(Set(config.movements.filter(\.lowRepLoadingAllowed).map(\.id)) == Set(["incline_db_press_24", "chest_supported_db_row_38_neutral", "suitcase_db_squat", "db_romanian_deadlift"]))
        let triceps = config.movements.first { $0.id == "db_triceps_extension" }!
        let row = config.movements.first { $0.id == "chest_supported_db_row_38_neutral" }!
        #expect(triceps.implementCount == 1)
        #expect(triceps.availableLoads.first { $0.amount == "35" } == Load(amount: "35", unit: .lb, basis: .total))
        #expect(row.implementCount == 2)
        #expect(row.availableLoads.first { $0.amount == "40" } == Load(amount: "40", unit: .lb, basis: .perImplement))
    }

    @Test func activeMetadataAndArchivedMetadataHaveSeparateHashes() throws {
        let config = try selectFixedProgram(goal: .size, programID: programID)
        let source = try archivedProfile()
        #expect(config.profileID == "fixed-home-gym-v0.2")
        #expect(config.sourceProfileHash == source.contentHash)
        #expect(config.profileHash != source.contentHash)
        #expect(config.movements.map(\.id) == source.movements.map(\.id))
        #expect(config.movements.first { $0.id == "incline_db_press_24" }?.name == "Incline DB Press")
        #expect(config.movements.first { $0.id == "chest_supported_db_row_38_neutral" }?.name == "Chest-Supported DB Row")
        #expect(config.movements.first { $0.id == "banded_pullups" }?.name == "Pull-ups")
        #expect(config.movements.first { $0.id == "banded_chinups" }?.name == "Chin-ups")
        #expect(config.movements.first { $0.id == "bent_knee_hanging_leg_raise_ab_straps" }?.name == "Bent-Knee Hanging Leg Raise")
        #expect(!config.movements.flatMap(\.requiredEquipment).contains("ab_straps"))
        #expect(source.movements.first { $0.id == "bent_knee_hanging_leg_raise_ab_straps" }?.requiredEquipment.contains("ab_straps") == true)
        var changed = config
        changed.movements[0].name = "changed"
        #expect(try selectFixedProgram(goal: .size, programID: programID) == config)
    }
}

func archivedProfile() throws -> FixedExerciseProfile {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(FixedExerciseProfile.self, from: Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-fixed-exercise-profile.json")))
}

extension FixedProgramTests {
    @Test func pinnedTypedMetadataProjectionIsIndependentlyDerivedFromResource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Packages/TrainingCore/Sources/TrainingCore/Resources/fixed-exercise-profile.json")
        let profile = try JSONDecoder().decode(FixedExerciseProfile.self, from: Data(contentsOf: resource))
        // Independent field enumeration: dynamic values are deliberately absent.
        let expected: CanonicalValue = .object([
            "profileId": .string(profile.profileID), "profileHash": .string(profile.contentHash),
            "sourceProfileId": .string(profile.sourceProfileID!), "sourceProfileHash": .string(profile.sourceProfileHash!),
            "variantPolicyVersion": .string(profile.variantPolicyVersion!), "daysPerWeek": .integer(Int64(profile.daysPerWeek)),
            "coveragePolicy": .string(profile.coveragePolicy),
            "movements": try FixtureCompiler.canonical(profile.movements),
            "weeklySlots": try FixtureCompiler.canonical(profile.weeklySlots),
            "requiredMuscleGroups": try FixtureCompiler.canonical(profile.requiredMuscleGroups)
        ])
        #expect(try CanonicalJSON.sha256(expected) == RulesetCatalog.fixedMetadataProjectionHash)
        let config = try selectFixedProgram(goal: .size, programID: programID)
        #expect(try fixedMetadataContent(config: config) == expected)
    }

    @Test(arguments: ["name", "permission", "catalog", "equipment", "repCounting", "setupRevision", "muscles", "slot", "sourceIdentity", "variantPolicy"])
    func everyFrozenMetadataDimensionRejectsTampering(field: String) throws {
        var config = try selectFixedProgram(goal: .size, programID: programID)
        switch field {
        case "name": config.movements[0].name = "Changed"
        case "permission": config.movements[0].automaticLoadProgressionAllowed = false
        case "catalog": config.movements[0].availableLoads.removeLast()
        case "equipment": config.movements[0].requiredEquipment = []
        case "repCounting": config.movements[0].repCounting = .perSide
        case "setupRevision": config.movements[0].setupRevision = 2
        case "muscles": config.movements[0].primaryMuscles = ["other"]
        case "slot": config.weeklySlots[0].weekday = 1
        case "sourceIdentity": config.sourceProfileHash = "changed"
        case "variantPolicy": config.variantPolicyVersion = "changed"
        default: fatalError()
        }
        #expect(throws: EngineError.self) { try validate(config: config, rules: RulesetCatalog.fixedV1()) }
        #expect(try CanonicalJSON.sha256(fixedMetadataContent(config: config)) != RulesetCatalog.fixedMetadataProjectionHash)
    }
}
