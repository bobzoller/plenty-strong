import Testing
@testable import TrainingCore

struct SafetyTests {
    @Test(arguments: [LogStatus.skipped, .partial])
    func painWinsOnIncompleteRows(status: LogStatus) throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C08")
        input.event.exercises[0].status = status
        input.event.exercises[0].actualSets = status == .skipped ? [] : [ActualSet(reps: 12)]
        let original = input
        guard case let .applied(state, workout, decisions) = advanceProgram(input) else { Issue.record("Expected applied pause"); return }
        #expect(state.exercises["example_lift"]?.mode == .paused)
        #expect(workout.exercises[0].sets.isEmpty)
        #expect(decisions[0].ruleIDs == ["R01"])
        #expect(input == original)
    }

    @Test(arguments: ["missing", "duplicate", "negative", "extra", "unit", "unavailable", "date", "nextDate", "unknown", "rowID", "plannedID"])
    func malformedRowsRejectAtomically(fault: String) throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C01")
        switch fault {
        case "missing": input.event.exercises = []
        case "duplicate": input.event.exercises.append(input.event.exercises[0])
        case "negative": input.event.exercises[0].actualSets[0].reps = -1
        case "extra": input.event.exercises[0].actualSets.append(ActualSet(reps: 10))
        case "unit": input.event.exercises[0].actualLoad?.unit = .kg
        case "unavailable": input.event.exercises[0].actualLoad?.amount = "41"
        case "date": input.event.date = input.state.lastSessionDate!
        case "nextDate": input.nextWorkoutDate = input.event.date
        case "unknown": input.event.exercises[0].movementID = "unknown"
        case "rowID": input.event.exercises[0].prescriptionID = "old"
        case "plannedID": input.event.plannedPrescriptionID = "old"
        default: fatalError()
        }
        #expect(rejectsUnchanged(input))
    }

    @Test func exactReplayPrecedesInvalidDatesAndChangedContentConflicts() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C20")
        input.nextWorkoutDate = input.event.date
        #expect(advanceProgram(input) == .noOp(nextState: input.state, reason: .eventReplayed))
        input.event.exercises[0].problem = .pain
        #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["event_id_conflict"]))
    }
}

func rejectsUnchanged(_ input: AdvanceInput) -> Bool {
    guard case let .rejected(state, errors) = advanceProgram(input) else { return false }
    return state == input.state && !errors.isEmpty
}

extension SafetyTests {
    @Test(arguments: ["logBase", "logDescription", "prescriptionBase", "prescriptionDescription", "safety", "variantState", "revision", "inactiveSetupRevision", "historyLog", "historyVariant", "historyBase", "historyDescription", "historyInstruction", "historyLoading", "historySetup", "historyRepCounting", "historyLoad", "emptyInstruction", "unknownExternalHistoryLoad"])
    func incompleteAppStateOrSnapshotsRejectAtomically(fault: String) throws {
        var input = try appInput(variant: "modified", modifications: "Different grip")
        let id = "modified"
        var first = input.state.exercises[id]!
        first.ceilingStreak = 1
        guard case let .applied(state, _, _) = try appGolden(input, target: id, after: first,
            action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true) else { return }
        input = try appEvent(state: state, rules: input.rules, target: id, eventID: "invalid-event")
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        let p = input.state.activePrescription.exercises.firstIndex { $0.movementID == id }!
        switch fault {
        case "logBase": input.event.exercises[row].baseMovementID = nil
        case "logDescription": input.event.exercises[row].modificationsSnapshot = nil
        case "prescriptionBase": input.state.activePrescription.exercises[p].baseMovementID = nil
        case "prescriptionDescription": input.state.activePrescription.exercises[p].modificationsSnapshot = nil
        case "safety": input.state.baseSafety = nil
        case "variantState": input.state.exercises.removeValue(forKey: id)
        case "revision": input.state.revision = Int.max
        case "inactiveSetupRevision":
            let defaultID = try defaultVariantID(programID: state.config.programID, baseMovementID: "banded_pullups")
            input.state.exercises[defaultID]!.setupRevision = nil
        case "historyLog": input.state.exercises[id]!.recentComparable[0].log = nil
        case "historyVariant": input.state.exercises[id]!.recentComparable[0].movementID = nil
        case "historyBase": input.state.exercises[id]!.recentComparable[0].baseMovementID = nil
        case "historyDescription": input.state.exercises[id]!.recentComparable[0].modificationsSnapshot = nil
        case "historyInstruction": input.state.exercises[id]!.recentComparable[0].effortInstruction = nil
        case "historyLoading": input.state.exercises[id]!.recentComparable[0].loadingMode = nil
        case "historySetup": input.state.exercises[id]!.recentComparable[0].setupRevision = nil
        case "historyRepCounting": input.state.exercises[id]!.recentComparable[0].repCounting = nil
        case "historyLoad": input.state.exercises[id]!.recentComparable[0].load = Load(amount: "25", unit: .lb, basis: .total)
        case "emptyInstruction": input.state.exercises[id]!.recentComparable[0].effortInstruction = ""
        case "unknownExternalHistoryLoad":
            var external = try appInput(base: "incline_db_press_24", amount: "50")
            let externalID = external.state.config.activeVariantIDs!["incline_db_press_24"]!
            var externalAfter = external.state.exercises[externalID]!
            externalAfter.ceilingStreak = 1
            guard case var .applied(externalState, _, _) = try appGolden(external, target: externalID, after: externalAfter, action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true) else { return }
            externalState.exercises[externalID]!.recentComparable[0].load = nil
            externalState.exercises[externalID]!.recentComparable[0].log!.actualLoad = nil
            external = try appEvent(state: externalState, rules: external.rules, target: externalID, eventID: "missing-load")
            #expect(rejectsUnchanged(external))
            return
        default: fatalError()
        }
        if fault.hasPrefix("prescription") {
            input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
            input.event.prescriptionID = input.state.activePrescription.id
            input.event.plannedPrescriptionID = input.state.activePrescription.id
            for index in input.event.exercises.indices { input.event.exercises[index].prescriptionID = input.state.activePrescription.id }
        }
        let original = input
        #expect(rejectsUnchanged(input))
        #expect(input == original)
    }

    @Test(arguments: ["missing", "unequal", "complete"])
    func appSideQualificationPreservesOriginalObservations(kind: String) throws {
        var input = try appInput(base: "bulgarian_split_squat", amount: "40", ceilingStreak: 1)
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        for index in input.event.exercises[row].actualSets.indices {
            input.event.exercises[row].actualSets[index].reps = kind == "unequal" ? 24 : 12 // Unequal sides retain their raw partial observation.
            input.event.exercises[row].actualSets[index].leftReps = kind == "missing" ? nil : 12
            input.event.exercises[row].actualSets[index].rightReps = kind == "missing" ? nil : (kind == "unequal" ? 10 : 12)
        }
        let original = input
        var after = input.state.exercises[id]!
        after.ceilingStreak = 0
        if kind == "complete" { after.repCeiling = 14 }
        let expected = try appGolden(input, target: id, after: after,
            action: kind == "complete" ? .extendRepCeiling : .hold,
            rules: kind == "complete" ? ["R11", "R14"] : ["R07"],
            key: kind == "complete" ? "rep_ceiling_extended" : "ineligible_observation", completed: kind == "complete")
        #expect(advanceProgram(input) == expected)
        #expect(input == original)
    }

    @Test func appComparableExposureKeepsRawBothSidesAndOriginalLog() throws {
        let input = try appInput(base: "bulgarian_split_squat", amount: "40")
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        var after = input.state.exercises[id]!
        after.ceilingStreak = 1
        let expected = try appGolden(input, target: id, after: after, action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true)
        #expect(advanceProgram(input) == expected)
        guard case let .applied(state, _, _) = advanceProgram(input) else { return }
        let exposure = state.exercises[id]!.recentComparable[0]
        #expect(exposure.log == input.event.exercises[row])
        #expect(exposure.actualSets == input.event.exercises[row].actualSets)
        #expect(exposure.actualSets[0].reps == 12 && exposure.actualSets[0].leftReps == 12 && exposure.actualSets[0].rightReps == 12)
    }
}

extension SafetyTests {
    @Test(arguments: ["baseline", "first_confirmation", "second_confirmation"], [11, 24])
    func inconsistentCompletedAppSideCountsRejectAtomically(path: String, reps: Int) throws {
        var input = try appInput(base: "bulgarian_split_squat", mode: path == "baseline" ? .baseline : .normal,
            amount: "40", ceilingStreak: path == "second_confirmation" ? 1 : 0)
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].actualSets[0].reps = reps // Both actual sides remain 12.
        let original = input
        #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["inconsistent_side_reps"]))
        #expect(input == original)
    }

    @Test(arguments: [11, 24])
    func inconsistentAppComparableSideSnapshotsRejectAtomically(reps: Int) throws {
        let input = try appInput(base: "bulgarian_split_squat", amount: "40")
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        var after = input.state.exercises[id]!
        after.ceilingStreak = 1
        guard case var .applied(state, _, _) = try appGolden(input, target: id, after: after,
            action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true) else { return }
        // Keep the exposure and its original log internally aligned with each other,
        // so rejection specifically checks the inconsistent per-side set count.
        state.exercises[id]!.recentComparable[0].actualSets[0].reps = reps
        state.exercises[id]!.recentComparable[0].log!.actualSets[0].reps = reps
        let next = try appEvent(state: state, rules: input.rules, target: id, eventID: "after-corrupt-history")
        #expect(advanceProgram(next) == .rejected(nextState: next.state, errors: ["inconsistent_side_reps"]))
    }

    @Test(arguments: ["baseline", "confirmation"])
    func archivedPerSideRepsOnlyStillRetainTheirConfirmedMeaning(path: String) throws {
        var input = try FixtureCompiler.advanceInput(caseID: path == "baseline" ? "C23" : "C04")
        input.state.config.movements[0].repCounting = .perSide
        let before = input.state.exercises["example_lift"]!
        var after = before
        after.lastCompletedDate = input.event.date
        after.load = Load(amount: path == "baseline" ? "40" : "42", unit: .lb, basis: .perImplement)
        after.mode = path == "baseline" ? .normal : .baseline
        after.ceilingStreak = 0
        let expected = try legacyGolden(input, after: after, action: path == "baseline" ? .baseline : .increaseLoad,
            rules: path == "baseline" ? ["R06"] : ["R11", "R13"], key: path == "baseline" ? "baseline_established" : "load_increased")
        #expect(advanceProgram(input) == expected)
        #expect(input.event.exercises[0].actualSets.allSatisfy { $0.leftReps == nil && $0.rightReps == nil })
    }
}

extension SafetyTests {
    @Test func unequalEarlierSetCannotMaskInconsistentLaterCompletedCount() throws {
        var input = try appInput(base: "bulgarian_split_squat", amount: "40", ceilingStreak: 1)
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].actualSets[0].rightReps = 10
        input.event.exercises[row].actualSets[1].reps = 24
        #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["inconsistent_side_reps"]))
    }

    @Test(arguments: [LogStatus.partial, .stopped])
    func explicitIncompleteSideRowsRemainRawAndIneligible(status: LogStatus) throws {
        var input = try appInput(base: "bulgarian_split_squat", amount: "40", ceilingStreak: 1)
        let id = input.state.config.activeVariantIDs!["bulgarian_split_squat"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].status = status
        input.event.exercises[row].actualSets[0].reps = 24
        let original = input
        var after = input.state.exercises[id]!
        after.ceilingStreak = 0
        let expected = try appGolden(input, target: id, after: after, action: .hold, rules: ["R07"], key: "ineligible_observation")
        #expect(advanceProgram(input) == expected)
        #expect(input == original)
    }
}
