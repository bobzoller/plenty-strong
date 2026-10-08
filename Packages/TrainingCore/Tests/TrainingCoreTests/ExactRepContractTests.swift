import Foundation
import Testing
@testable import TrainingCore

struct ExactRepContractTests {
    @Test func policiesAreExplicit() throws {
        let rules = try RulesetCatalog.exactV1()
        #expect(rules.version == "general-fitness-exact-v1")
        #expect(rules.contractVersion == 3)
        #expect(try ProgramPolicy.resolve(schemaVersion: 3, rules: rules) == .fixedExactV1)
        #expect(try ProgramPolicy.resolve(schemaVersion: 2, rules: RulesetCatalog.fixedV1()) == .fixedCeilingsV1)
        #expect(try ProgramPolicy.resolve(schemaVersion: 1, rules: RulesetCatalog.numericV02()) == .numericV02)
        #expect(ProgramPolicy.fixedExactV1.usesVariants)
        #expect(ProgramPolicy.fixedExactV1.usesExactTargets)
        #expect(!ProgramPolicy.numericV02.usesVariants)
        #expect(!ProgramPolicy.fixedCeilingsV1.usesExactTargets)
        for schema in [1, 2, 4] {
            #expect(throws: EngineError.self) { try ProgramPolicy.resolve(schemaVersion: schema, rules: rules) }
        }
    }

    @Test func exactManifestIsPinnedAndNotCallerExecutable() throws {
        let rules = try RulesetCatalog.exactV1()
        #expect(rules.hash == RulesetCatalog.exactRulesetHash)
        #expect(rules.sourceRulesetHash == RulesetCatalog.fixedRulesetHash)
        #expect(rules.profileHash == RulesetCatalog.fixedProfileHash)
        #expect(rules.ruleIDs == (1...13).map { String(format: "X%02d", $0) })
        #expect(rules.sourceIDs == (1...9).map { String(format: "EX%02d", $0) })
        #expect(rules.presets == (try RulesetCatalog.fixedV1()).presets)
        #expect(try rules.resolvedParameters.exactRep == ExactRepParameters())
        #expect(try rules.preset(goal: .size, daysPerWeek: 3).normalSets == 3)
        #expect(rules.rules?.last?.evidenceClass == .softwareRequirement)
        #expect(rules.rules?.dropLast().allSatisfy { $0.evidenceClass == .appAdaptation } == true)
        #expect(try RulesetCatalog.resolve(version: rules.version, hash: rules.hash) == rules)
        for original in [try RulesetCatalog.numericV02(), try RulesetCatalog.fixedV1()] {
            #expect(try RulesetCatalog.resolve(version: original.version, hash: original.hash) == original)
        }
        #expect(throws: EngineError.self) { try RulesetCatalog.resolve(version: rules.version, hash: "bad") }
        #expect(throws: EngineError.self) { try RulesetCatalog.resolve(version: "future", hash: rules.hash) }
        for mutate in [
            { (r: inout Ruleset) in r.hash = "bad" },
            { (r: inout Ruleset) in r.version = "future" },
            { (r: inout Ruleset) in r.parameters?.exactRep?.normalIncrementTotal = 2 },
            { (r: inout Ruleset) in r.sources?[0].limitations = "validated forecast" }
        ] {
            var changed = rules
            mutate(&changed)
            #expect(throws: EngineError.self) { try ProgramPolicy.resolve(schemaVersion: 3, rules: changed) }
            // Even a self-consistent replacement hash cannot change the pinned policy.
            changed.hash = try hashWithoutHash(changed)
            if changed.hash != rules.hash {
                #expect(throws: EngineError.self) { try changed.validateIntegrity() }
            }
        }
        #expect(try hashWithoutHash(rules) == RulesetCatalog.exactRulesetHash)
    }

    @Test func newTypedFieldsRoundTripWithoutFabricatedDecodeDefaults() throws {
        let state = ExactRepState(normalTargets: [10, 10, 9], shortfallStreak: 1,
            lastSuitableNormalDate: try LocalDate(iso8601: "2026-10-01"), setupReviewRequired: true)
        #expect(try JSONDecoder().decode(ExactRepState.self, from: JSONEncoder().encode(state)) == state)
        let context = ExactRepContext(variantID: "v", setupRevision: 2,
            load: Load(amount: "40", unit: .lb, basis: .perImplement), normalSetCount: 3,
            minimumRir: 4, effortScope: .allWorkingSets, restSeconds: 180, movementPosition: 2,
            repFloor: 8, repCeiling: 12, rulesetHash: RulesetCatalog.exactRulesetHash)
        #expect(try JSONDecoder().decode(ExactRepContext.self, from: JSONEncoder().encode(context)) == context)
        let actual = ActualSet(reps: 9, setIndex: 2, missedGoalReason: .effortLimit)
        #expect(try JSONDecoder().decode(ActualSet.self, from: JSONEncoder().encode(actual)) == actual)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExactRepParameters.self, from: Data("{}".utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ExactRepState.self, from: Data(#"{"shortfallStreak":0,"setupReviewRequired":false}"#.utf8))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packages/TrainingCore/Sources/TrainingCore/Resources/ruleset-exact-v1.json"))
        // Verify that typed coding preserves every field of the actual manifest.
        #expect(try canonical(RulesetCatalog.exactV1()) == JSONDecoder().decode(CanonicalValue.self, from: data))
    }

    @Test func legacyOptionalFieldsRemainAbsent() throws {
        let state = try legacyState()
        let prescription = state.activePrescription.exercises[0]
        let actual = ActualSet(reps: 8)
        let log = ExerciseLog(movementID: prescription.movementID, prescriptionID: state.activePrescription.id,
            status: .completed, actualLoad: nil, actualSets: [actual], finalEffort: .onTarget, problem: .none)
        let exposure = Exposure(eventID: "old", date: state.activePrescription.date, load: nil,
            plannedSetCount: 1, repFloor: 8, repCeiling: 12, actualSets: [actual], effort: .onTarget,
            problem: .none, sessionMode: .normal, phase: .normal)
        let values: [CanonicalValue] = [try canonical(prescription.sets[0]), try canonical(actual),
            try canonical(log), try canonical(state.exercises[prescription.movementID]!), try canonical(exposure),
            try canonical(RulesetCatalog.fixedV1().resolvedParameters)]
        let keys = ["targetReps", "setIndex", "missedGoalReason", "effortScope", "skippedSetIndices", "mixedLoads", "exactRepState", "prescribedTargets", "exactRepContext", "exactRep"]
        for value in values {
            guard case .object(let fields) = value else { Issue.record("Expected object"); continue }
            #expect(Set(fields.keys).isDisjoint(with: Set(keys)))
        }
        #expect(state.exercises.values.allSatisfy { $0.exactRepState == nil })
        #expect(state.activePrescription.exercises.flatMap(\.sets).allSatisfy { $0.targetReps == nil })
        let encoded = try canonical(state)
        #expect(try canonical(JSONDecoder().decode(ProgramState.self, from: CanonicalJSON.encode(encoded))) == encoded)
        try validateExactRepContract(state: state, rules: RulesetCatalog.fixedV1())
    }

    @Test func legacyGoldenArchiveBytesAndIDsRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-general-fitness-progression-examples.json"))
        let archive = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let base = try JSONSerialization.data(withJSONObject: archive["baseInput"]!)
        let input = try JSONDecoder().decode(AdvanceInput.self, from: base)
        let before = try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: base))
        #expect(try CanonicalJSON.encode(canonical(input)) == before)
        #expect(input.state.activePrescription.id == input.event.prescriptionID)
    }

    @Test func indexedSetsPreserveGaps() throws {
        let prescription = exactPrescription()
        let log = exactLog(status: .partial, sets: [ActualSet(reps: 10, setIndex: 0), ActualSet(reps: 9, setIndex: 2)], skipped: [1])
        try validateIndexedExactLog(log, prescription: prescription)
        let decoded = try JSONDecoder().decode(ExerciseLog.self, from: JSONEncoder().encode(log))
        #expect(decoded == log)
        #expect(decoded.actualSets.map(\.setIndex) == [0, 2])
        #expect(decoded.actualSets.map(\.reps) == [10, 9])
        #expect(decoded.skippedSetIndices == [1])
    }

    @Test func indexedLogsRequireExplicitScopeAndSlotBinding() throws {
        let prescription = exactPrescription()
        let original = exactLog(status: .partial, sets: [ActualSet(reps: 10, setIndex: 0)], skipped: [1])
        for mutate in [
            { (l: inout ExerciseLog) in l.effortScope = nil },
            { (l: inout ExerciseLog) in l.skippedSetIndices = nil },
            { (l: inout ExerciseLog) in l.mixedLoads = nil },
            { (l: inout ExerciseLog) in l.actualSets[0].setIndex = nil },
            { (l: inout ExerciseLog) in l.actualSets[0].setIndex = 3 },
            { (l: inout ExerciseLog) in l.actualSets.append(l.actualSets[0]) },
            { (l: inout ExerciseLog) in l.skippedSetIndices = [1, 1] },
            { (l: inout ExerciseLog) in l.skippedSetIndices = [0] },
            { (l: inout ExerciseLog) in l.skippedSetIndices = [-1] },
            { (l: inout ExerciseLog) in l.movementID = "different" },
            { (l: inout ExerciseLog) in l.baseMovementID = nil },
            { (l: inout ExerciseLog) in l.modificationsSnapshot = nil },
            { (l: inout ExerciseLog) in l.actualSets[0].reps = -1 }
        ] {
            var broken = original
            mutate(&broken)
            #expect(throws: EngineError.self) { try validateIndexedExactLog(broken, prescription: prescription) }
        }
    }

    @Test func rawStoppedPartialAndAsymmetricObservationsSurvive() throws {
        for status in [LogStatus.completed, .partial, .stopped] {
            let log = exactLog(status: status, sets: [ActualSet(reps: 0, leftReps: 0, setIndex: 0), ActualSet(reps: 9, leftReps: 9, rightReps: 7, setIndex: 2)], skipped: [1])
            try validateIndexedExactLog(log, prescription: exactPrescription())
            #expect(try JSONDecoder().decode(ExerciseLog.self, from: JSONEncoder().encode(log)) == log)
        }
    }

    @Test func exactStateRejectsMissingOrInvalidTargets() throws {
        let original = try exactState()
        let id = original.activePrescription.exercises[0].movementID
        try validateExactRepContract(state: original, rules: RulesetCatalog.exactV1())
        for mutate in [
            { (s: inout ProgramState) in s.exercises[id]?.exactRepState = nil },
            { (s: inout ProgramState) in s.exercises[id]?.exactRepState?.normalTargets = [8] },
            { (s: inout ProgramState) in s.exercises[id]?.exactRepState?.normalTargets = [8, 0, 6] },
            { (s: inout ProgramState) in s.exercises[id]?.exactRepState?.normalTargets = [13, 8, 8] },
            { (s: inout ProgramState) in s.exercises[id]?.exactRepState?.shortfallStreak = -1 },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].sets[0].targetReps = nil },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].sets[0].targetReps = 0 },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].sets[0].targetReps = 13 },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].baseMovementID = nil },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].sets[0].repCeiling = 20; s.activePrescription.exercises[0].sets[0].targetReps = 20 },
            { (s: inout ProgramState) in s.activePrescription.exercises.append(s.activePrescription.exercises[0]) },
            { (s: inout ProgramState) in s.rulesetHash = "bad" }
        ] {
            var broken = original
            mutate(&broken)
            #expect(throws: EngineError.self) { try validateExactRepContract(state: broken, rules: RulesetCatalog.exactV1()) }
        }
        // Later-set targets below the nominal floor are deliberate, legal goals.
        var belowFloor = original
        belowFloor.exercises[id]?.exactRepState?.normalTargets = [8, 7, 1]
        try validateExactRepContract(state: belowFloor, rules: RulesetCatalog.exactV1())
    }

    @Test func exactSnapshotsRequireTargetsAndContext() throws {
        var state = try exactState()
        let id = state.activePrescription.exercises[0].movementID
        let prescription = state.activePrescription.exercises[0]
        let exercise = state.exercises[id]!
        let context = ExactRepContext(variantID: id, setupRevision: 1, load: nil, normalSetCount: 3,
            minimumRir: 2, effortScope: .allWorkingSets, restSeconds: 120, movementPosition: 0,
            repFloor: 8, repCeiling: 12, rulesetHash: RulesetCatalog.exactRulesetHash)
        let log = ExerciseLog(movementID: id, prescriptionID: "previous", status: .completed, actualLoad: nil,
            actualSets: (0..<3).map { ActualSet(reps: 8, setIndex: $0) }, finalEffort: .onTarget, problem: .none,
            baseMovementID: prescription.baseMovementID, modificationsSnapshot: prescription.modificationsSnapshot,
            effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
        let exposure = Exposure(eventID: "past", date: try LocalDate(iso8601: "2026-10-01"), log: log,
            movementID: id, baseMovementID: prescription.baseMovementID, modificationsSnapshot: prescription.modificationsSnapshot,
            load: nil, plannedSetCount: 3, repFloor: 8, repCeiling: 12, effortInstruction: "Aim for listed reps",
            actualSets: log.actualSets, effort: .onTarget, problem: .none, sessionMode: .normal, phase: .normal,
            loadingMode: .bodyweight, setupRevision: exercise.setupRevision, repCounting: .total,
            prescribedTargets: [8, 8, 8], exactRepContext: context)
        // Use a bodyweight movement with no invented numeric load.
        let bodyID = state.config.activeVariantIDs!["bent_knee_hanging_leg_raise_ab_straps"]!
        var bodyExposure = exposure
        bodyExposure.movementID = bodyID
        bodyExposure.baseMovementID = "bent_knee_hanging_leg_raise_ab_straps"
        bodyExposure.log?.movementID = bodyID
        bodyExposure.log?.baseMovementID = bodyExposure.baseMovementID
        bodyExposure.exactRepContext?.variantID = bodyID
        state.exercises[bodyID]?.recentComparable = [bodyExposure]
        try validateExactRepContract(state: state, rules: RulesetCatalog.exactV1())
        for mutate in [
            { (e: inout Exposure) in e.prescribedTargets = nil },
            { (e: inout Exposure) in e.exactRepContext = nil },
            { (e: inout Exposure) in e.exactRepContext?.rulesetHash = "bad" },
            { (e: inout Exposure) in e.exactRepContext?.normalSetCount = 0 },
            { (e: inout Exposure) in e.exactRepContext?.load = Load(amount: "5", unit: .lb, basis: .total) },
            { (e: inout Exposure) in e.log?.effortScope = nil },
            { (e: inout Exposure) in e.actualSets[0].reps = 0; e.log?.actualSets = e.actualSets },
            { (e: inout Exposure) in e.actualSets[0].leftReps = 8; e.actualSets[0].rightReps = 7; e.log?.actualSets = e.actualSets }
        ] {
            var broken = state
            mutate(&broken.exercises[bodyID]!.recentComparable[0])
            #expect(throws: EngineError.self) { try validateExactRepContract(state: broken, rules: RulesetCatalog.exactV1()) }
        }
    }

    @Test func setupReviewHasNoWorkingSets() throws {
        var state = try exactState()
        let id = state.activePrescription.exercises[0].movementID
        state.exercises[id]?.exactRepState?.setupReviewRequired = true
        state.activePrescription.exercises[0].kind = .setupReview
        state.activePrescription.exercises[0].sets = []
        try validateExactRepContract(state: state, rules: RulesetCatalog.exactV1())
        state.activePrescription.exercises[0].sets = exactPrescription().sets
        #expect(throws: EngineError.self) { try validateExactRepContract(state: state, rules: RulesetCatalog.exactV1()) }
        #expect(try canonical(PrescriptionKind.setupReview) == .string("setup_review"))
        #expect(try canonical(MissedGoalReason.effortLimit) == .string("effort_limit"))
        #expect(try canonical(MissedGoalReason.timeInterruption) == .string("time_interruption"))
        #expect(try canonical(MissedGoalReason.otherUnknown) == .string("other_unknown"))
        #expect(try canonical(EffortScope.allWorkingSets) == .string("all_working_sets"))
    }

    private func legacyState() throws -> ProgramState {
        try initializeProgram(config: selectFixedProgram(goal: .size, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            rules: RulesetCatalog.fixedV1(), firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: "SUN")).state
    }

    private func exactState() throws -> ProgramState {
        var state = try legacyState()
        let rules = try RulesetCatalog.exactV1()
        state.schemaVersion = 3
        state.rulesetVersion = rules.version
        state.rulesetHash = rules.hash
        for id in state.exercises.keys {
            state.exercises[id]?.exactRepState = ExactRepState(normalTargets: [8, 8, 8], shortfallStreak: 0,
                lastSuitableNormalDate: nil, setupReviewRequired: false)
        }
        for index in state.activePrescription.exercises.indices {
            for set in state.activePrescription.exercises[index].sets.indices {
                state.activePrescription.exercises[index].sets[set].targetReps = 8
            }
        }
        return state
    }

    private func exactPrescription() -> ExercisePrescription {
        ExercisePrescription(movementID: "variant", kind: .working, phase: .normal, load: nil,
            sets: [10, 10, 9].map { SetPrescription(repFloor: 8, repCeiling: 12, effortInstruction: "Aim for listed reps", targetReps: $0) },
            restSeconds: 120, stopInstruction: "Stop for pain", baseMovementID: "base", modificationsSnapshot: "")
    }

    private func exactLog(status: LogStatus, sets: [ActualSet], skipped: [Int]) -> ExerciseLog {
        ExerciseLog(movementID: "variant", prescriptionID: "workout", status: status, actualLoad: nil, actualSets: sets,
            finalEffort: .onTarget, problem: .none, baseMovementID: "base", modificationsSnapshot: "",
            effortScope: .allWorkingSets, skippedSetIndices: skipped, mixedLoads: false)
    }

    private func canonical(_ value: some Encodable) throws -> CanonicalValue {
        try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    }

    private func hashWithoutHash(_ rules: Ruleset) throws -> String {
        guard case .object(var fields) = try canonical(rules) else { throw EngineError(code: "test", field: "rules") }
        fields.removeValue(forKey: "hash")
        return try CanonicalJSON.sha256(.object(fields))
    }
}
