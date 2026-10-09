import Foundation
import Testing
@testable import TrainingCore

struct StarterProgramCatalogTests {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let orders = [
        ["db_romanian_deadlift", "incline_db_press_30", "chest_supported_db_row_30_neutral", "db_floor_glute_bridge", "supported_single_leg_calf_raise", "dead_bug_heel_tap"],
        ["supported_static_split_squat", "db_floor_glute_bridge", "chest_supported_db_row_30_neutral", "db_lateral_raise", "supported_single_leg_calf_raise", "standing_db_curl"],
        ["suitcase_db_squat", "db_romanian_deadlift", "incline_db_press_30", "chest_supported_db_row_30_neutral", "db_lateral_raise", "dead_bug_heel_tap"]]

    @Test func allChoiceGoalPairsMatchFrozenDefinitions() throws {
        for choice in StarterProgramChoice.allCases {
            let definition = try StarterProgramCatalog.definition(choice)
            let rules = try RulesetCatalog.starter(choice)
            #expect(definition.schemaVersion == 4)
            #expect(try ProgramPolicy.resolve(schemaVersion: 4, rules: rules) == .starterExactV1)
            #expect(ProgramPolicy.starterExactV1.schemaVersion == 4)
            #expect(definition.requiredEquipment.contains("pull_up_bar") == (choice == .upperBody))
            for goal in Goal.allCases {
                let config = try selectStarterProgram(choice: choice, goal: goal, programID: id)
                #expect(try StarterProgramCatalog.choice(for: config) == choice)
                #expect(config.movements == definition.movements)
                #expect(config.weeklySlots == definition.weeklySlots)
                try validate(config: config, rules: rules)
                let doses = try config.movements.map { movement in
                    try resolveMovementDose(config: config, variantID: config.activeVariantIDs![movement.id]!, exercise: nil, rules: rules)
                }
                if choice == .wholeBodyGlutes {
                    #expect(config.weeklySlots.map(\.movementIDs) == orders)
                    let byID = Dictionary(uniqueKeysWithValues: zip(config.movements.map(\.id), doses))
                    #expect(config.weeklySlots.map { $0.movementIDs.reduce(0) { $0 + byID[$1]!.initialSets } } == [12, 12, 12])
                    #expect(config.weeklySlots.map { $0.movementIDs.reduce(0) { $0 + byID[$1]!.establishedSets } } == ([Goal.size, .strength].contains(goal) ? [15, 13, 16] : [12, 12, 12]))
                    for (movement, dose) in zip(config.movements, doses) {
                        let compound = ["db_romanian_deadlift", "incline_db_press_30", "chest_supported_db_row_30_neutral", "suitcase_db_squat"].contains(movement.id)
                        let reviewed = compound && movement.id != "db_romanian_deadlift" && goal == .strength
                        let accessory = ["db_lateral_raise", "supported_single_leg_calf_raise", "db_floor_glute_bridge"].contains(movement.id)
                        let trunk = movement.id == "dead_bug_heel_tap"
                        #expect(dose.repFloor == (reviewed ? 4 : trunk || (compound && goal == .strength) ? 6 : accessory ? 10 : 8))
                        #expect(dose.initialRepCeiling == (reviewed ? 6 : trunk || (compound && goal == .strength) ? 10 : accessory ? 15 : 12))
                        #expect(dose.restSeconds == (compound && goal == .strength ? 180 : trunk ? 60 : ["db_lateral_raise", "supported_single_leg_calf_raise", "standing_db_curl"].contains(movement.id) ? 90 : 120))
                        #expect(dose.maximumRepCeiling == (reviewed ? 8 : 20))
                        #expect(dose.requiresHandlingReview == reviewed)
                        #expect(dose.allowsIntroPromotion == (compound && [Goal.size, .strength].contains(goal)))
                        #expect(movement.repCounting == (["supported_static_split_squat", "supported_single_leg_calf_raise", "dead_bug_heel_tap"].contains(movement.id) ? .perSide : .total))
                        #expect(movement.implementCount == (trunk ? 0 : ["db_floor_glute_bridge", "supported_static_split_squat", "supported_single_leg_calf_raise"].contains(movement.id) ? 1 : 2))
                        if !trunk { #expect(movement.availableLoads.first?.basis == (movement.implementCount == 1 ? .total : .perImplement)) }
                        else { #expect(movement.availableLoads.isEmpty); #expect(config.initialLoads[movement.id]! == nil) }
                    }
                } else {
                    let old = try selectFixedProgram(goal: goal, programID: id)
                    let preset = try RulesetCatalog.exactV1().preset(goal: goal, daysPerWeek: 3)
                    #expect(config.movements == old.movements)
                    #expect(config.weeklySlots == old.weeklySlots)
                    for (movement, dose) in zip(config.movements, doses) {
                        let low = goal == .strength && movement.lowRepLoadingAllowed
                        #expect(dose.initialSets == preset.normalSets && dose.establishedSets == preset.normalSets)
                        #expect(dose.repFloor == (goal == .strength && !low ? 8 : preset.repFloor))
                        #expect(dose.initialRepCeiling == (goal == .strength && !low ? 12 : preset.repCeiling))
                        #expect(dose.restSeconds == preset.restSeconds)
                        #expect(dose.maximumRepCeiling == (low ? 8 : 20))
                        #expect(!dose.allowsIntroPromotion && !dose.requiresHandlingReview)
                    }
                }
            }
        }
    }

    @Test func suppliedDefinitionSelectionIsPureAndStrict() throws {
        for choice in StarterProgramChoice.allCases {
            let definition = try StarterProgramCatalog.definition(choice)
            #expect(try selectStarterProgram(definition: definition, goal: .size, programID: id) == selectStarterProgram(choice: choice, goal: .size, programID: id))
            let registration = StarterProgramCatalog.registration(choice)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("Packages/TrainingCore/Sources/TrainingCore/Resources/" + registration.profileID + ".json"))
            for key in ["choice", "schemaVersion", "contentHash", "sourceProfileHash", "requiredEquipment", "initialLoads"] {
                var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                switch key {
                case "choice": fields[key] = choice == .upperBody ? "whole_body_glutes" : "upper_body"
                case "schemaVersion": fields[key] = 3
                case "requiredEquipment": fields[key] = []
                case "initialLoads": fields[key] = [:]
                default: fields[key] = "bad"
                }
                let changed = try JSONDecoder().decode(StarterProgramDefinition.self, from: JSONSerialization.data(withJSONObject: fields))
                #expect(throws: EngineError.self) { try selectStarterProgram(definition: changed, goal: .size, programID: id) }
            }
        }
    }

    @Test func rdlStrengthIsSixToTenAt180Seconds() throws {
        let config = try selectStarterProgram(choice: .wholeBodyGlutes, goal: .strength, programID: id)
        let rules = try RulesetCatalog.starter(.wholeBodyGlutes)
        let dose = try resolveMovementDose(config: config, variantID: config.activeVariantIDs!["db_romanian_deadlift"]!, exercise: nil, rules: rules)
        #expect(dose.repFloor == 6 && dose.initialRepCeiling == 10 && dose.restSeconds == 180 && dose.maximumRepCeiling == 20)
    }

    @Test func newProfilesScheduleOnCalendarDaysAndRejectTamperedMetadata() throws {
        for choice in StarterProgramChoice.allCases {
            let config = try selectStarterProgram(choice: choice, goal: .size, programID: id)
            #expect(try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-11"), config: config) == WorkoutSlot(date: LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
            #expect(try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-12"), config: config) == WorkoutSlot(date: LocalDate(iso8601: "2026-10-13"), slotID: "TUE"))
            for mutate in [
                { (c: inout ProgramConfig) in c.movements[0].name = "tampered" },
                { (c: inout ProgramConfig) in c.weeklySlots[0].movementIDs.reverse() },
                { (c: inout ProgramConfig) in c.profileHash = "bad" },
                { (c: inout ProgramConfig) in c.sourceProfileHash = "bad" },
                { (c: inout ProgramConfig) in c.profileID = "unknown" },
                { (c: inout ProgramConfig) in c.coveragePolicy = nil },
                { (c: inout ProgramConfig) in c.coveragePolicy = "general" },
                { (c: inout ProgramConfig) in c.coveragePolicy = nil; c.weeklySlots[0].weekday = 1 },
                { (c: inout ProgramConfig) in c.coveragePolicy = "general"; c.weeklySlots[0].weekday = 1 }
            ] {
                var changed = config; mutate(&changed)
                #expect(throws: EngineError.self) { try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-11"), config: changed) }
                #expect(throws: EngineError.self) { try validate(config: changed, rules: RulesetCatalog.starter(choice)) }
            }
        }
    }

    @Test func rulesRejectRehashedDoseAndFamilyTampering() throws {
        for choice in StarterProgramChoice.allCases {
            let rules = try RulesetCatalog.starter(choice)
            #expect(rules.ruleIDs.suffix(6) == ["P01", "P02", "P03", "P04", "P05", "P06"])
            #expect(try RulesetCatalog.resolve(version: rules.version, hash: rules.hash) == rules)
            for mutate in [
                { (r: inout Ruleset) in r.starterDoses?["size"]?.removeAll() },
                { (r: inout Ruleset) in r.starterDoses?["strength"]?["db_romanian_deadlift"]?.repFloor += 1 },
                { (r: inout Ruleset) in r.safetyFamilies?["db_romanian_deadlift"] = "other" },
                { (r: inout Ruleset) in r.profileHash = "bad" },
                { (r: inout Ruleset) in r.contractVersion = 3 }
            ] {
                var changed = rules; mutate(&changed)
                changed.hash = try hashWithoutHash(changed)
                #expect(throws: EngineError.self) { try changed.validateIntegrity() }
                #expect(throws: EngineError.self) { try ProgramPolicy.resolve(schemaVersion: 4, rules: changed) }
            }
            #expect(throws: EngineError.self) { try ProgramPolicy.resolve(schemaVersion: 3, rules: rules) }
        }
    }

    @Test func explicitHandlingAndBodyweightBridgeResolution() throws {
        var config = try selectStarterProgram(choice: .wholeBodyGlutes, goal: .strength, programID: id)
        let rules = try RulesetCatalog.starter(.wholeBodyGlutes)
        let pressID = config.activeVariantIDs!["incline_db_press_30"]!
        let load = Load(amount: "20", unit: .lb, basis: .perImplement)
        var exercise = ExerciseState(load: load, mode: .baseline, normalSets: 2, repFloor: 4, repCeiling: 6, ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false, recentComparable: [], setupRevision: 1, starterState: StarterExerciseState(doseStage: .introductory, strengthHandling: .standardRange, windows: [:]))
        var dose = try resolveMovementDose(config: config, variantID: pressID, exercise: exercise, rules: rules)
        #expect(dose.repFloor == 8 && dose.initialRepCeiling == 12 && dose.maximumRepCeiling == 20 && dose.restSeconds == 180 && !dose.requiresHandlingReview)
        exercise.starterState!.strengthHandling = .lowRep(load: load)
        dose = try resolveMovementDose(config: config, variantID: pressID, exercise: exercise, rules: rules)
        #expect(dose.repFloor == 4 && dose.initialRepCeiling == 6 && dose.maximumRepCeiling == 8 && !dose.requiresHandlingReview)
        exercise.load = Load(amount: "25", unit: .lb, basis: .perImplement)
        #expect(try resolveMovementDose(config: config, variantID: pressID, exercise: exercise, rules: rules).requiresHandlingReview)
        let bridgeID = "synthetic-bodyweight-bridge"
        config.variants![bridgeID] = MovementVariant(id: bridgeID, baseMovementID: "db_floor_glute_bridge", modifications: "", loadingModeOverride: .bodyweight)
        config.activeVariantIDs!["db_floor_glute_bridge"] = bridgeID
        let movement = try resolveEffectiveMovement(config: config, variantID: bridgeID, rules: rules)
        #expect(movement.loadingMode == .bodyweight && movement.implementCount == 0 && movement.availableLoads.isEmpty && movement.initialLoad == nil && !movement.automaticLoadProgressionAllowed)
        #expect(try resolveMovementDose(config: config, variantID: bridgeID, exercise: nil, rules: rules).repFloor == 10)
        #expect(rules.safetyFamilies?["db_floor_glute_bridge"] == "db_floor_glute_bridge")
        config.variants![bridgeID]!.loadingModeOverride = .externalLoad
        #expect(throws: EngineError.self) { try resolveEffectiveMovement(config: config, variantID: bridgeID, rules: rules) }
        config.variants![bridgeID]!.loadingModeOverride = .bodyweight
        config.variants![bridgeID]!.baseMovementID = "db_romanian_deadlift"
        #expect(throws: EngineError.self) { try resolveEffectiveMovement(config: config, variantID: bridgeID, rules: rules) }
    }

    @Test func newOptionalStateAndContextContractsRoundTrip() throws {
        let context = ExactRepContext(variantID: "synthetic", setupRevision: 1, load: nil, normalSetCount: 2, minimumRir: 2, effortScope: .allWorkingSets, restSeconds: 60, movementPosition: 5, repFloor: 6, repCeiling: 10, rulesetHash: StarterProgramCatalog.gluteRulesetHash)
        let window = StarterComparisonWindow(slotID: "SUN", contextKey: "synthetic-context", context: context, precedingDose: [StarterPrecedingMovement(baseMovementID: "db_romanian_deadlift", normalSetCount: 2)], ceilingStreak: 0, strainStreak: 0, shortfallStreak: 0, introStreak: 1, exposures: [])
        let starter = StarterExerciseState(doseStage: .introductory, strengthHandling: .lowRep(load: Load(amount: "20", unit: .lb, basis: .perImplement)), windows: ["SUN": window])
        #expect(try JSONDecoder().decode(StarterExerciseState.self, from: JSONEncoder().encode(starter)) == starter)
        var state = try initializeProgram(config: selectFixedProgram(goal: .size, programID: id), rules: RulesetCatalog.exactV1(), firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-11"), slotID: "SUN")).state
        state.schemaVersion = 4 // Wire round trip only; semantic validator comes in Task 2.
        state.exercises[state.exercises.keys.sorted()[0]]!.starterState = starter
        state.retainedSafety = ["removed-synthetic-family": MovementSafetyState(paused: true, minimumRir: 4, sourceEventIDs: ["synthetic-pain"])]
        #expect(try JSONDecoder().decode(ProgramState.self, from: JSONEncoder().encode(state)) == state)
        let variant = MovementVariant(id: "synthetic-bridge", baseMovementID: "db_floor_glute_bridge", modifications: "", loadingModeOverride: .bodyweight)
        #expect(try JSONDecoder().decode(MovementVariant.self, from: JSONEncoder().encode(variant)) == variant)
    }

    @Test func archivesPinsSourceBindingsAndTypedRulesAreIndependent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceData = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-08-glute-starter-profile.json"))
        guard case .object(var source) = try JSONDecoder().decode(CanonicalValue.self, from: sourceData) else { throw EngineError(code: "test", field: "source") }
        #expect(source.removeValue(forKey: "contentHash") == .string(StarterProgramCatalog.gluteSourceProfileHash))
        #expect(try CanonicalJSON.sha256(.object(source)) == StarterProgramCatalog.gluteSourceProfileHash)
        for choice in StarterProgramChoice.allCases {
            let definition = try StarterProgramCatalog.definition(choice)
            let registration = StarterProgramCatalog.registration(choice)
            let rules = try RulesetCatalog.starter(choice)
            let rawRules = try JSONDecoder().decode(CanonicalValue.self, from: Data(contentsOf: root.appendingPathComponent("Packages/TrainingCore/Sources/TrainingCore/Resources/" + registration.resource + ".json")))
            #expect(try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(rules)) == rawRules)
            let config = try selectStarterProgram(definition: definition, goal: .size, programID: id)
            #expect(try CanonicalJSON.sha256(fixedMetadataContent(config: config)) == registration.projectionHash)
            #expect(definition.sourceProfileID == (choice == .upperBody ? "fixed-home-gym-v0.2" : "glute-starter-design-v0.1"))
            #expect(definition.sourceProfileHash == (choice == .upperBody ? RulesetCatalog.fixedProfileHash : StarterProgramCatalog.gluteSourceProfileHash))
            #expect(rules.rules?.prefix(13).map { $0 } == (try RulesetCatalog.exactV1()).rules)
            #expect(Set(rules.starterDoses!["size"]!.keys) == Set(config.movements.map(\.id)))
            #expect(Set(rules.safetyFamilies!.keys) == Set(config.movements.map(\.id)))
        }
    }

    @Test func oldPolicyBytesAreUnchanged() throws {
        #expect(try RulesetCatalog.exactV1().hash == "b5b1100ee68edbe76384c31a3c8e1af918b4f5e3737f701ed0a6745989c3c73f")
        let config = try selectFixedProgram(goal: .size, programID: id)
        #expect(config.profileHash == "e63a0543d54108af99637ed52dacebc1276e766b4314bc095891248efd7ce8ce")
        #expect(try StarterProgramCatalog.choice(for: config) == .upperBody)
        let state = try initializeProgram(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-11"), slotID: "SUN")).state
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!encoded.contains("starterState") && !encoded.contains("retainedSafety") && !encoded.contains("loadingModeOverride"))
    }

    @Test func legacyNewFieldsCannotSmuggleSchemaFourMeaning() throws {
        for rules in [try RulesetCatalog.numericV02(), try RulesetCatalog.fixedV1(), try RulesetCatalog.exactV1()] {
            let config = rules.contractVersion == nil ? try numericConfig() : try selectFixedProgram(goal: .size, programID: id)
            let state = try initializeProgram(config: config, rules: rules, firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-11"), slotID: config.weeklySlots[0].id)).state
            var changed = state
            changed.exercises[changed.exercises.keys.sorted()[0]]!.starterState = StarterExerciseState(doseStage: .introductory, strengthHandling: nil, windows: [:])
            #expect(throws: EngineError.self) { try validateExactRepContract(state: changed, rules: rules) }
            #expect(throws: EngineError.self) { try prepareWorkout(state: changed, rules: rules) }
            changed = state; changed.retainedSafety = [:]
            #expect(throws: EngineError.self) { try validateExactRepContract(state: changed, rules: rules) }
            #expect(throws: EngineError.self) { try prepareWorkout(state: changed, rules: rules) }
            if let key = changed.config.variants?.keys.sorted().first {
                changed = state; changed.config.variants![key]!.loadingModeOverride = .bodyweight
                #expect(throws: EngineError.self) { try validate(config: changed.config, rules: rules) }
            }
        }
    }
    private func hashWithoutHash(_ rules: Ruleset) throws -> String {
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(rules)) else { throw EngineError(code: "test", field: "rules") }
        fields.removeValue(forKey: "hash")
        return try CanonicalJSON.sha256(.object(fields))
    }

    private func numericConfig() throws -> ProgramConfig {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-general-fitness-progression-examples.json"))
        let archive = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = try JSONDecoder().decode(AdvanceInput.self, from: JSONSerialization.data(withJSONObject: archive["baseInput"]!))
        return input.state.config
    }

}
