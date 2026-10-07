import Foundation
import Testing
@testable import TrainingCore

struct ContractTests {
    @Test func catalogsRetainSourceAndExactPolicy() throws {
        let active = try RulesetCatalog.fixedV1()
        let numeric = try RulesetCatalog.numericV02()
        #expect(numeric.hash == "cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb")
        #expect(active.hash != numeric.hash)
        #expect(active.ruleIDs == (1...16).map { String(format: "R%02d", $0) })
        #expect(active.sourceIDs == (1...13).map { String(format: "E%02d", $0) })
        #expect(active.rules?.count == 16)
        #expect(active.sources?.count == 13)
        #expect(active.sources!.allSatisfy { !$0.url.isEmpty && !$0.locator.isEmpty && !$0.population.isEmpty && !$0.limitations.isEmpty && !$0.relevantPassageReference.isEmpty && !$0.adaptationRationale.isEmpty })
        #expect(try active.preset(goal: .maintenance, daysPerWeek: 3).normalSets == 2)
        #expect(try numeric.preset(goal: .size, daysPerWeek: 2).normalSets == 4)
        #expect(active.parameters?.normalEffortInstruction == "Stop when you think you could do two more good reps. Stop earlier for pain or loss of control.")
        for mutate in [
            { (r: inout Ruleset) in r.hash = "bad" },
            { (r: inout Ruleset) in r.sources?.removeLast() },
            { (r: inout Ruleset) in r.rules?[0].sourceIDs = ["E99"] },
            { (r: inout Ruleset) in r.sourceIDs.append("E01") },
            { (r: inout Ruleset) in r.parameters?.confirmationCount = 1 }
        ] {
            var broken = active
            mutate(&broken)
            #expect(throws: EngineError.self) { try broken.validateIntegrity() }
        }
        #expect(try RulesetCatalog.fixedV1() == active)
    }

    @Test func invalidConfigurationsRejectAtSmallestField() throws {
        let rules = try RulesetCatalog.fixedV1()
        let original = try selectFixedProgram(goal: .size, programID: UUID())
        for mutate in [
            { (c: inout ProgramConfig) in c.movements.append(c.movements[0]) },
            { (c: inout ProgramConfig) in c.weeklySlots[0].movementIDs[0] = "unknown" },
            { (c: inout ProgramConfig) in c.movements[0].setupRevision = 0 },
            { (c: inout ProgramConfig) in c.movements[0].secondaryMuscles.append("chest") },
            { (c: inout ProgramConfig) in c.movements[0].availableLoads[0].basis = .total },
            { (c: inout ProgramConfig) in c.movements[0].availableLoads[0].unit = .kg },
            { (c: inout ProgramConfig) in c.movements[0].availableLoads[0].amount = "0" },
            { (c: inout ProgramConfig) in c.movements[0].availableLoads.swapAt(0, 1) },
            { (c: inout ProgramConfig) in c.movements[1].availableLoads = c.movements[0].availableLoads },
            { (c: inout ProgramConfig) in c.initialLoads["banded_pullups"] = Load(amount: "5", unit: .lb, basis: .total) }
        ] {
            var config = original
            mutate(&config)
            #expect(throws: EngineError.self) { try validate(config: config, rules: rules) }
        }
    }

    @Test func unequalAndUnfinishedSidesPreserveOriginals() throws {
        let movement = try selectFixedProgram(goal: .size, programID: UUID()).movements.first { $0.id == "bulgarian_split_squat" }!
        var log = ExerciseLog(movementID: "variant", prescriptionID: "p", status: .completed, actualLoad: nil, actualSets: [ActualSet(reps: 12, leftReps: 12, rightReps: 10)], finalEffort: .onTarget, problem: .none)
        let normalized = try normalizeSideLog(log, movement: movement)
        #expect(normalized.status == .partial)
        #expect(normalized.actualSets[0].reps == 10)
        #expect(normalized.actualSets[0].leftReps == 12)
        #expect(normalized.actualSets[0].rightReps == 10)
        log.actualSets[0].rightReps = nil
        #expect(try normalizeSideLog(log, movement: movement).status == .partial)
        log.actualSets[0].leftReps = -1
        #expect(throws: EngineError.self) { try normalizeSideLog(log, movement: movement) }
    }

    @Test func numericFixtureRoundTripPreservesArchivedOmissions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-general-fitness-progression-examples.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let base = try JSONSerialization.data(withJSONObject: raw["baseInput"]!)
        let input = try JSONDecoder().decode(AdvanceInput.self, from: base)
        let roundTrip = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(input))
        let expected = try JSONDecoder().decode(CanonicalValue.self, from: base)
        #expect(roundTrip == expected)
        #expect(input.state.config.movements[0].loadingMode == .externalLoad)
        #expect(input.state.config.variants == nil)
        let absent = try JSONDecoder().decode(Movement.self, from: Data(#"{"id":"m","primaryMuscles":["back"],"secondaryMuscles":[],"minimumRir":2,"availableLoads":[]}"#.utf8))
        #expect(!absent.automaticLoadProgressionAllowed)
        #expect(!absent.lowRepLoadingAllowed)
    }
}

struct ArchivedExposureContractTests {
    @Test func archivedComparableExposuresRetainEveryOriginalField() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-general-fitness-progression-examples.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = raw["cases"] as! [[String: Any]]
        for fixture in cases where ["C25", "C26", "C27"].contains(fixture["id"] as! String) {
            let overrides = fixture["inputOverrides"] as! [String: Any]
            let state = overrides["state"] as! [String: Any]
            let exercises = state["exercises"] as! [String: Any]
            let lift = exercises["example_lift"] as! [String: Any]
            let rawExposures = try JSONSerialization.data(withJSONObject: lift["recentComparable"]!)
            let exposures = try JSONDecoder().decode([Exposure].self, from: rawExposures)
            let before = try JSONDecoder().decode(CanonicalValue.self, from: rawExposures)
            let after = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(exposures))
            #expect(after == before)
            #expect(exposures.allSatisfy { $0.log == nil && $0.modificationsSnapshot == nil })
        }
    }

    @Test func canonicalSnapshotsRoundTripAndRejectFractionalNumbers() throws {
        let value = CanonicalValue.object(["before": .null, "integer": .integer(12), "description": .string("+25 lb"), "flags": .array([.bool(true)])])
        #expect(try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)) == value)
        for invalid in ["1.1", "{\"load\":2.5}", "9223372036854775808"] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CanonicalValue.self, from: Data(invalid.utf8)) }
        }
    }

    @Test func journalCommandsRetainTypedPayloadsAndRejectUnknownCases() throws {
        let date = try LocalDate(iso8601: "2026-10-06")
        let slot = WorkoutSlot(date: date, slotID: "TUE")
        let commands: [JournalCommand] = [
            .initialize(config: try selectFixedProgram(goal: .size, programID: UUID()), firstWorkout: slot),
            .reconfigure(change: .minimumRir(baseMovementID: "banded_pullups", value: 4), next: slot),
            .reconfigure(change: .safeResume(baseMovementID: "banded_pullups", externalClearanceConfirmed: true), next: slot),
            .reconfigure(change: .resetSetup(variantID: "saved"), next: slot),
            .reconfigure(change: .goal(.maintenance), next: slot),
            .variantChange(change: .create(baseMovementID: "banded_pullups", variantID: "saved", modifications: "35 lb assistance"), next: slot),
            .variantChange(change: .select(baseMovementID: "banded_pullups", variantID: "saved"), next: slot),
            .variantChange(change: .correctDescription(variantID: "saved", modifications: "+25 lb"), next: slot),
            .reschedule(slot: slot), .interruption(asOf: date)
        ]
        for command in commands {
            #expect(try JSONDecoder().decode(JournalCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalCommand.self, from: Data(#"{"kind":"cloud_resolution"}"#.utf8)) }
    }
}

struct SideSchemaContractTests {
    @Test func appMissingBothSidesIsPartialWhileArchivedCountIsPreserved() throws {
        let movements = try selectFixedProgram(goal: .size, programID: UUID()).movements
        let perSide = movements.first { $0.id == "bulgarian_split_squat" }!
        var log = ExerciseLog(movementID: "v", prescriptionID: "p", status: .completed, actualLoad: nil, actualSets: [ActualSet(reps: 12)], finalEffort: .onTarget, problem: .none)
        #expect(try normalizeSideLog(log, movement: perSide) == log)
        log.baseMovementID = perSide.id
        log.modificationsSnapshot = ""
        let partial = try normalizeSideLog(log, movement: perSide)
        #expect(partial.status == .partial)
        #expect(partial.actualSets == log.actualSets)
        log.actualSets = [ActualSet(reps: 12, leftReps: 12, rightReps: 12)]
        #expect(try normalizeSideLog(log, movement: perSide).status == .completed)
        let triceps = movements.first { $0.id == "db_triceps_extension" }!
        log.baseMovementID = triceps.id
        log.actualSets = [ActualSet(reps: 12)]
        #expect(try normalizeSideLog(log, movement: triceps).status == .completed)
    }
}

struct AppStateContractTests {
    @Test func variantStatesSafetyAndRootJournalRoundTrip() throws {
        let config = try selectFixedProgram(goal: .maintenance, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let rules = try RulesetCatalog.fixedV1()
        let date = try LocalDate(iso8601: "2026-10-04")
        let prescription = WorkoutPrescription(id: "synthetic", date: date, slotID: "SUN", exercises: [])
        let exercises = Dictionary(uniqueKeysWithValues: config.variants!.keys.map {
            ($0, ExerciseState(load: nil, mode: .baseline, normalSets: 2, repFloor: 8, repCeiling: 12, ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false, recentComparable: [], setupRevision: 1))
        })
        let safety = Dictionary(uniqueKeysWithValues: config.movements.map { ($0.id, MovementSafetyState(paused: false, minimumRir: 2, sourceEventIDs: [])) })
        let state = ProgramState(schemaVersion: 2, rulesetVersion: rules.version, rulesetHash: rules.hash, config: config, revision: 0, exercises: exercises, lastSessionDate: nil, activePrescription: prescription, processedEvents: [:], baseSafety: safety)
        #expect(state.exercises.count == 12)
        #expect(state.baseSafety?.count == 12)
        #expect(Set(state.exercises.keys) == Set(config.variants!.keys))
        let envelope = JournalEnvelope(schemaVersion: 2, datasetID: "synthetic", programID: config.programID, eventID: "init", eventHash: "hash", parentEnvelopeHash: nil, inputRevision: 0, inputStateHash: nil, rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: config.profileID!, profileHash: config.profileHash!, sourceProfileID: config.sourceProfileID!, sourceProfileHash: config.sourceProfileHash!, command: .initialize(config: config, firstWorkout: WorkoutSlot(date: date, slotID: "SUN")), returnedState: state, returnedPrescription: prescription, decisions: [], envelopeHash: "hash")
        let data = try JSONEncoder().encode(envelope)
        #expect(try JSONDecoder().decode(JournalEnvelope.self, from: data) == envelope)
        guard case .object(let fields) = try JSONDecoder().decode(CanonicalValue.self, from: data) else { Issue.record("Expected envelope object"); return }
        #expect(fields["parentEnvelopeHash"] == .null)
        #expect(fields["inputStateHash"] == .null)
        #expect(fields["programId"] == .string(config.programID))
        #expect(fields["wallTime"] == nil)
    }
}

struct ParameterContractTests {
    @Test func versionDispatchedTypedParametersPreserveNumericHash() throws {
        let numeric = try RulesetCatalog.numericV02()
        let active = try RulesetCatalog.fixedV1()
        let parameters = try numeric.resolvedParameters
        #expect(parameters.normalMinimumRir == 2)
        #expect(parameters.easierMinimumRir == 4)
        #expect(parameters.confirmationCount == 2)
        #expect(parameters.setbackCount == 2)
        #expect(parameters.maximumLoadIncreasePercent == 10)
        #expect(parameters.repCeilingExtension == 2)
        #expect(parameters.maximumRepCeiling == 20)
        #expect(parameters.maximumStrengthRepCeiling == 8)
        #expect(parameters.interruptionDays == 28)
        #expect(parameters.plateauExposures == 6)
        #expect(parameters.normalEffortInstruction == "Stop with roughly two good reps left; stop earlier for pain or loss of control.")
        #expect(try active.resolvedParameters == active.parameters)
        #expect(numeric.parameters == nil)
        #expect(numeric.hash == RulesetCatalog.numericRulesetHash)
        var unknown = numeric
        unknown.version = "future"
        #expect(throws: EngineError(code: "unknown_ruleset", field: "rules.version")) { try unknown.resolvedParameters }
    }
}
