import Foundation
import Testing
@testable import TrainingCore

struct ProgressionFixtureTests {
    @Test(arguments: FixtureCompiler.advanceCaseIDs)
    func completeWorkedTransition(caseID: String) throws {
        let input = try FixtureCompiler.advanceInput(caseID: caseID)
        let original = input
        let expected = try FixtureCompiler.expectedAdvanceResult(caseID: caseID)
        #expect(advanceProgram(input) == expected)
        #expect(advanceProgram(input) == expected)
        #expect(input == original)
        try assertSourceProjection(result: advanceProgram(input), source: FixtureCompiler.sourceProjection(caseID: caseID))
    }

    @Test func allFortySevenSourceIDsAreRepresented() {
        #expect(FixtureCompiler.advanceCaseIDs.count == 43)
        #expect(Set(FixtureCompiler.advanceCaseIDs + FixtureCompiler.prepareCaseIDs) == Set((1...47).map { String(format: "C%02d", $0) }))
    }
}

func assertSourceProjection(result: AdvanceResult, source: CanonicalValue) throws {
    guard case .object(let sourceFields) = source, case .object(let fields) = try FixtureCompiler.canonical(result) else { fatalError() }
    #expect(fields["kind"] == sourceFields["kind"])
    if case .object(let checks) = sourceFields["checks"] {
        for (path, expected) in checks where path.hasPrefix("/") {
            var found: CanonicalValue? = .object(fields)
            for component in path.split(separator: "/") {
                switch found {
                case .object(let object): found = object[String(component)]
                case .array(let array): found = Int(component).flatMap { array.indices.contains($0) ? array[$0] : nil }
                default: found = nil
                }
            }
            #expect(found == expected)
        }
        if case .applied(let state, let workout, let decisions) = result {
            if let count = checks["workingSetCount"] { #expect(count == .integer(Int64(workout.exercises.reduce(0) { $0 + $1.sets.count }))) }
            if case .array(let keys) = checks["noticeKeys"] {
                #expect(keys.compactMap { if case .string(let value) = $0 { return value }; return nil }.sorted() == decisions.filter { $0.action == .notice }.map(\.explanationKey).sorted())
            }
            #expect(state.activePrescription == workout)
        }
    }
    if case .applied(_, _, let decisions) = result, case .array(let rules) = sourceFields["primaryRuleIds"] {
        #expect(rules.compactMap { if case .string(let value) = $0 { return value }; return nil }.sorted() == Array(Set(decisions.flatMap(\.ruleIDs))).sorted())
    }
    if case .rejected(_, let errors) = result, let sourceErrors = sourceFields["errorCodes"] {
        #expect(sourceErrors == .array(errors.map(CanonicalValue.string)))
    }
}

extension ProgressionFixtureTests {
    @Test(arguments: ["F03", "F04", "F05", "F06", "F07", "F14"])
    func originalFixedTransitionsUseArchivedMetadataAndFullGoldens(caseID: String) throws {
        let input = try sourceFixedInput(caseID)
        let id = input.state.config.movements[0].id
        var after = input.state.exercises[id]!
        let action: DecisionAction
        let rules: [String]
        let key: String
        switch caseID {
        case "F03", "F07": after.repCeiling = 14; after.ceilingStreak = 0; action = .extendRepCeiling; rules = ["R11", "R14"]; key = "rep_ceiling_extended"
        case "F04": after.load!.amount = "55"; after.mode = .baseline; after.ceilingStreak = 0; action = .increaseLoad; rules = ["R11", "R13"]; key = "load_increased"
        case "F05": after.mode = .normal; action = .baseline; rules = ["R06"]; key = "baseline_established"
        case "F06": action = .hold; rules = ["R03", "R04"]; key = "easier_session_recorded"
        case "F14": action = .baseline; rules = ["R06"]; key = "baseline_pending"
        default: fatalError()
        }
        if input.event.exercises[0].status == .completed { after.lastCompletedDate = input.event.date }
        let expected = try legacyGolden(input, after: after, action: action, rules: rules, key: key)
        #expect(advanceProgram(input) == expected)
        #expect(advanceProgram(input) == expected)
        if case let .applied(state, _, _) = expected {
            let exercise = state.exercises[id]!
            let source = try fixedSourceExample(caseID)
            guard case .object(let values) = source else { fatalError() }
            if let mode = values["mode"] ?? values["nextMode"] { #expect(mode == .string(exercise.mode.rawValue)) }
            if let load = values["load"] { #expect(load == .null && exercise.load == nil) }
            if let ceiling = values["repCeiling"] ?? values["nextRepCeilingFrom12"] { #expect(ceiling == .integer(Int64(exercise.repCeiling))) }
            if let streak = values["ceilingStreak"] { #expect(streak == .integer(Int64(exercise.ceilingStreak))) }
            if let increase = values["automaticLoadIncrease"] { #expect(increase == .bool(action == .increaseLoad)) }
            if values["assistanceChangedByEngine"] == .bool(false) { #expect(exercise.load == input.state.exercises[id]!.load) }
            if values["progressionEligible"] == .bool(false) { #expect(exercise.ceilingStreak == 0 && exercise.recentComparable.isEmpty) }
        }
    }

    @Test func originalF01F02F08F10F11F12F13RemainSubstantiveBehaviors() throws {
        let config = try selectFixedProgram(goal: .maintenance, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!)
        let rules = try RulesetCatalog.fixedV1()
        let initialized = try initializeProgram(config: config, rules: rules,
            firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "SUN"))
        #expect(config.daysPerWeek == 3 && config.weeklySlots.map(\.id) == ["SUN", "TUE", "THU"])
        #expect(config.weeklySlots.map { $0.movementIDs.count } == [5,5,5])
        #expect(initialized.state.exercises.count == 12 && initialized.state.exercises.values.allSatisfy { $0.normalSets == 2 })
        #expect(Set(config.movements.filter(\.lowRepLoadingAllowed).map(\.id)) == Set(["incline_db_press_24", "chest_supported_db_row_38_neutral", "suitcase_db_squat", "db_romanian_deadlift"]))
        let strength = try selectFixedProgram(goal: .strength, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!)
        let strengthState = try initializeProgram(config: strength, rules: rules,
            firstWorkout: WorkoutSlot(date: initialized.workout.date, slotID: "SUN")).state
        for movement in strength.movements where !movement.lowRepLoadingAllowed {
            let id = strength.activeVariantIDs![movement.id]!
            #expect(strengthState.exercises[id]!.repFloor == 8 && strengthState.exercises[id]!.repCeiling == 12)
        }
        let body = try appInput(base: "bent_knee_hanging_leg_raise_ab_straps", mode: .baseline)
        let easier = try prepareWorkout(state: body.state, rules: body.rules, easierToday: true)
        let raise = easier.exercises.first { $0.baseMovementID == "bent_knee_hanging_leg_raise_ab_straps" }!
        #expect(raise.sets.count == 2 && raise.sets.allSatisfy { $0.repCeiling == 8 && $0.effortInstruction.contains("at least 4") })
        #expect(raise.load == nil)
        let split = config.movements.first { $0.id == "bulgarian_split_squat" }!
        let raw = ExerciseLog(movementID: split.id, prescriptionID: "source-F10", status: .completed,
            actualLoad: nil, actualSets: [ActualSet(reps: 12, leftReps: 12, rightReps: 10)], finalEffort: .onTarget, problem: .none)
        let normalized = try normalizeSideLog(raw, movement: split)
        #expect(normalized.status == .partial && normalized.actualSets[0].reps == 10 && raw.actualSets[0].leftReps == 12)
        #expect(config.muscleExposureCounts["quads"] == 1)
        #expect(config.weeklySlots.filter { slot in config.movements.contains { movement in
            slot.movementIDs.contains(movement.id) && (movement.primaryMuscles + movement.secondaryMuscles).contains("quads")
        } }.map(\.id) == ["TUE"])
        let triceps = config.movements.first { $0.id == "db_triceps_extension" }!
        let row = config.movements.first { $0.id == "chest_supported_db_row_38_neutral" }!
        #expect(triceps.implementCount == 1 && triceps.availableLoads.contains(Load(amount: "35", unit: .lb, basis: .total)))
        #expect(row.implementCount == 2 && row.availableLoads.contains(Load(amount: "40", unit: .lb, basis: .perImplement)))
        // F09 full-state reset behavior runs in ConfigurationTests.F09SetupResetMatchesArchivedExpectationAndFullState.
    }
}

func fixedSourceExample(_ id: String) throws -> CanonicalValue {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard case .object(let document) = try JSONDecoder().decode(CanonicalValue.self,
        from: Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-fixed-exercise-profile.json"))),
        case .array(let examples) = document["acceptanceExamples"],
        case .object(let example) = examples.first(where: { if case .object(let f) = $0 { return f["id"] == .string(id) }; return false }),
        let expected = example["expected"] else { fatalError("Missing source example") }
    return expected
}

func sourceFixedInput(_ caseID: String) throws -> AdvanceInput {
    let base: String
    let amount: String?
    switch caseID {
    case "F03": base = "db_lateral_raise"; amount = "15"
    case "F04": base = "incline_db_press_24"; amount = "50"
    case "F05", "F06": base = "banded_pullups"; amount = nil
    case "F07": base = "banded_chinups"; amount = nil
    default: base = "bent_knee_hanging_leg_raise_ab_straps"; amount = nil
    }
    let movement = try archivedProfile().movements.first { $0.id == base }!
    let load = amount.map { Load(amount: $0, unit: .lb, basis: .perImplement) }
    let config = ProgramConfig(programID: "source-fixed-example", goal: .size, daysPerWeek: 3, movements: [movement],
        weeklySlots: ["SUN", "TUE", "THU"].map { WeeklySlot(id: $0, movementIDs: [base]) },
        requiredMuscleGroups: movement.primaryMuscles, initialLoads: [base: load])
    let rules = try RulesetCatalog.numericV02()
    let date = try LocalDate(iso8601: "2026-10-04")
    var state = try initializeProgram(config: config, rules: rules, firstWorkout: WorkoutSlot(date: date, slotID: "SUN")).state
    if ["F03", "F04", "F07"].contains(caseID) { state.exercises[base]!.mode = .normal; state.exercises[base]!.ceilingStreak = 1 }
    state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: date, slotID: "SUN")
    let easier = caseID == "F06"
    let displayed = easier ? try FixtureCompiler.expectedEasier(state: state, rules: rules) : state.activePrescription
    let reps = caseID == "F14" || caseID == "F05" ? 10 : (easier ? 8 : 12)
    let log = ExerciseLog(movementID: base, prescriptionID: displayed.id, status: caseID == "F14" ? .partial : .completed,
        actualLoad: load, actualSets: Array(repeating: ActualSet(reps: reps), count: caseID == "F14" ? 1 : displayed.exercises[0].sets.count),
        finalEffort: .onTarget, problem: .none)
    return AdvanceInput(state: state, event: CompletedWorkout(eventID: caseID, date: date, slotID: "SUN",
        prescriptionID: displayed.id, plannedPrescriptionID: state.activePrescription.id,
        sessionMode: easier ? .easier : .normal, exercises: [log]), rules: rules, nextSlotID: "TUE", nextWorkoutDate: try date.adding(days: 2))
}

func legacyGolden(_ input: AdvanceInput, after: ExerciseState, action: DecisionAction, rules: [String], key: String,
                  notices: [(String, [String])] = []) throws -> AdvanceResult {
    var state = input.state
    let id = input.event.exercises[0].movementID
    state.exercises[id] = after
    state.revision += 1
    state.lastSessionDate = input.event.date
    state.processedEvents[input.event.eventID] = try CanonicalJSON.sha256(FixtureCompiler.canonical(input.event))
    let workout = try FixtureCompiler.expectedWorkout(state: state, date: input.nextWorkoutDate, slotID: input.nextSlotID)
    state.activePrescription = workout
    var decisions = [try FixtureCompiler.expectedDecision(id: id, action: action, rules: rules, key: key,
        before: input.state.exercises[id]!, after: after)]
    for (notice, noticeRules) in notices {
        decisions.append(try FixtureCompiler.expectedDecision(id: id, action: .notice, rules: noticeRules,
            key: notice, before: input.state.exercises[id]!, after: after))
    }
    return .applied(nextState: state, nextWorkout: workout, decisions: decisions)
}

extension ProgressionFixtureTests {
    @Test(arguments: [6, 8])
    func strengthRepExtensionHonorsEightRepMaximum(ceiling: Int) throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C16")
        input.state.config.movements[0].availableLoads = [Load(amount: "40", unit: .lb, basis: .perImplement), Load(amount: "50", unit: .lb, basis: .perImplement)]
        input.state.exercises["example_lift"]!.repCeiling = ceiling
        for i in input.state.activePrescription.exercises[0].sets.indices { input.state.activePrescription.exercises[0].sets[i].repCeiling = ceiling }
        input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
        input.event.prescriptionID = input.state.activePrescription.id
        input.event.plannedPrescriptionID = input.state.activePrescription.id
        input.event.exercises[0].prescriptionID = input.state.activePrescription.id
        input.event.exercises[0].actualSets = Array(repeating: ActualSet(reps: ceiling), count: 3)
        var after = input.state.exercises["example_lift"]!
        after.ceilingStreak = 0
        after.repCeiling = 8
        after.lastCompletedDate = input.event.date
        if ceiling == 6 {
            let expected = try legacyGolden(input, after: after, action: .extendRepCeiling, rules: ["R11", "R14"], key: "rep_ceiling_extended")
            #expect(advanceProgram(input) == expected)
        } else {
            after.recentComparable = [Exposure(eventID: input.event.eventID, date: input.event.date,
                load: after.load, plannedSetCount: 3, repFloor: 4, repCeiling: 8,
                actualSets: input.event.exercises[0].actualSets, effort: .onTarget, problem: .none, sessionMode: .normal, phase: .normal)]
            let expected = try legacyGolden(input, after: after, action: .hold, rules: ["R11", "R15"], key: "equipment_limit",
                notices: [("equipment_limit", ["R11", "R15"])])
            #expect(advanceProgram(input) == expected)
        }
    }

    @Test func successfulLoadIncreaseRestoresExtendedOriginalPreset() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C04")
        input.state.exercises["example_lift"]!.repCeiling = 16
        for index in input.state.activePrescription.exercises[0].sets.indices { input.state.activePrescription.exercises[0].sets[index].repCeiling = 16 }
        input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
        input.event.prescriptionID = input.state.activePrescription.id
        input.event.plannedPrescriptionID = input.state.activePrescription.id
        input.event.exercises[0].prescriptionID = input.state.activePrescription.id
        input.event.exercises[0].actualSets = Array(repeating: ActualSet(reps: 16), count: 3)
        var after = input.state.exercises["example_lift"]!
        after.load!.amount = "42"
        after.mode = .baseline
        after.repCeiling = 12
        after.ceilingStreak = 0
        after.lastCompletedDate = input.event.date
        let expected = try legacyGolden(input, after: after, action: .increaseLoad, rules: ["R11", "R13"], key: "load_increased")
        #expect(advanceProgram(input) == expected)
    }

    @Test(arguments: ["easier", "baseline", "return", "hard", "easy", "problem", "changedLoad", "dose", "range", "instruction", "growing", "maintenance", "fat_loss"])
    func plateauExcludesIneligibleOrDifferentComparisonContexts(exclusion: String) throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C26")
        switch exclusion {
        case "easier": input.state.exercises["example_lift"]!.recentComparable[0].sessionMode = .easier
        case "baseline": input.state.exercises["example_lift"]!.recentComparable[0].phase = .baseline
        case "return": input.state.exercises["example_lift"]!.recentComparable[0].phase = .returning
        case "hard": input.state.exercises["example_lift"]!.recentComparable[0].effort = .tooHard
        case "easy": input.state.exercises["example_lift"]!.recentComparable[0].effort = .tooEasy
        case "problem": input.state.exercises["example_lift"]!.recentComparable[0].problem = .pain
        case "changedLoad": input.state.exercises["example_lift"]!.recentComparable[0].load!.amount = "38"
        case "dose": input.state.exercises["example_lift"]!.recentComparable[0].plannedSetCount = 2
        case "range": input.state.exercises["example_lift"]!.recentComparable[0].repCeiling = 14
        case "instruction": input.state.exercises["example_lift"]!.recentComparable[0].effortInstruction = "Different instruction"
        case "growing": input = try FixtureCompiler.advanceInput(caseID: "C27")
        case "maintenance": input = try FixtureCompiler.advanceInput(caseID: "C25")
        case "fat_loss":
            input.state.config.goal = .fatLoss
            input.state.exercises["example_lift"]!.normalSets = 2
            input.state.activePrescription.exercises[0].sets.removeLast()
            input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
            input.event.prescriptionID = input.state.activePrescription.id
            input.event.plannedPrescriptionID = input.state.activePrescription.id
            input.event.exercises[0].prescriptionID = input.state.activePrescription.id
            input.event.exercises[0].actualSets.removeLast()
        default: fatalError()
        }
        guard case let .applied(_, _, decisions) = advanceProgram(input) else { Issue.record("Expected applied hold"); return }
        #expect(!decisions.contains { $0.explanationKey == "plateau_check" })
    }

    @Test func changedContextResetsConfirmationBeforeQualifyingCurrentExposure() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C04")
        let historyInput = try FixtureCompiler.advanceInput(caseID: "C26")
        var history = historyInput.state.exercises["example_lift"]!.recentComparable[0]
        history.repCeiling = 14
        input.state.exercises["example_lift"]!.recentComparable = [history]
        guard case let .applied(state, _, decisions) = advanceProgram(input) else { Issue.record("Expected new context confirmation"); return }
        #expect(state.exercises["example_lift"]!.load!.amount == "40" && state.exercises["example_lift"]!.ceilingStreak == 1)
        #expect(state.exercises["example_lift"]!.recentComparable.count == 1)
        #expect(decisions[0].ruleIDs == ["R11"])
    }
}
