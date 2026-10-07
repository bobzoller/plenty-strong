import Foundation
import Testing
@testable import TrainingCore

struct VariantConfigurationTests {
    @Test func newModifiedSetupHasIndependentBaselineAndOldStateIsByteIdentical() throws {
        let (state, rules, slot, oldID) = try configurationInput()
        let before = try CanonicalJSON.encode(FixtureCompiler.canonical(state.exercises[oldID]!))
        let result = try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "new", modifications: "  +25 lb  "), rules: rules, nextWorkout: slot)
        #expect(result.state.config.activeVariantIDs!["banded_pullups"] == "new")
        #expect(result.state.config.variants!["new"]!.modifications == "+25 lb")
        #expect(result.state.exercises["new"] == ExerciseState(load: nil, mode: .baseline, normalSets: 3, repFloor: 8, repCeiling: 12, ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false, recentComparable: [], setupRevision: 1))
        #expect(try CanonicalJSON.encode(FixtureCompiler.canonical(result.state.exercises[oldID]!)) == before)
        #expect(result.state.baseSafety == state.baseSafety)
    }

    @Test func repeatedSlotsResolveSameSelectedVariantAndOldVariantUsesOwnGap() throws {
        let base = "db_lateral_raise"
        var (state, rules, slot, oldID) = try configurationInput(base: base)
        state.exercises[oldID]!.lastCompletedDate = try slot.date.adding(days: -28)
        let created = try changeMovementVariant(state: state, change: .create(baseMovementID: base, variantID: "modified", modifications: "Different grip"), rules: rules, nextWorkout: slot)
        for weekly in state.config.weeklySlots.filter({ $0.movementIDs.contains(base) }) {
            let prepared = try reschedulePendingWorkout(state: created.state, slot: WorkoutSlot(date: try slot.date.adding(days: weekly.weekday!), slotID: weekly.id), rules: rules)
            #expect(prepared.workout.exercises.contains { $0.movementID == "modified" && $0.baseMovementID == base })
        }
        let selected = try changeMovementVariant(state: created.state, change: .select(baseMovementID: base, variantID: oldID), rules: rules, nextWorkout: slot)
        #expect(selected.state.exercises[oldID]!.interruptedReturn)
        #expect(selected.state.exercises[oldID]!.nextSetOverride == 2)
        #expect(selected.state.exercises["modified"] == created.state.exercises["modified"])
    }

    @Test func correctionPreservesStateAndOriginalExposureSnapshot() throws {
        let input = try appInput(variant: "saved", modifications: "Old label")
        guard case let .applied(state, _, _) = advanceProgram(input) else { Issue.record("Expected applied"); return }
        let slot = WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)
        let result = try changeMovementVariant(state: state, change: .correctDescription(variantID: "saved", modifications: "Corrected label"), rules: input.rules, nextWorkout: slot)
        #expect(result.state.exercises == state.exercises)
        #expect(result.state.processedEvents == state.processedEvents)
        #expect(result.state.exercises["saved"]!.recentComparable.first!.modificationsSnapshot == "Old label")
        #expect(result.workout.exercises.first { $0.movementID == "saved" }!.modificationsSnapshot == "Corrected label")
        let defaultID = state.config.variants!.values.first { $0.baseMovementID == "banded_pullups" && $0.modifications.isEmpty }!.id
        #expect(throws: EngineError.self) { try changeMovementVariant(state: state, change: .correctDescription(variantID: defaultID, modifications: "Added weight"), rules: input.rules, nextWorkout: slot) }
        #expect(try changeMovementVariant(state: state, change: .correctDescription(variantID: defaultID, modifications: ""), rules: input.rules, nextWorkout: slot).state == state)
    }

    @Test func duplicateLabelsStayDistinctAndInvalidChangesReject() throws {
        let (state, rules, slot, _) = try configurationInput()
        let first = try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "one", modifications: "Same"), rules: rules, nextWorkout: slot)
        let second = try changeMovementVariant(state: first.state, change: .create(baseMovementID: "banded_pullups", variantID: "two", modifications: "Same"), rules: rules, nextWorkout: slot)
        #expect(second.state.exercises["one"] != nil && second.state.exercises["two"] != nil)
        for change in [VariantChange.create(baseMovementID: "unknown", variantID: "x", modifications: "Label"), .select(baseMovementID: "incline_db_press_24", variantID: "one"), .create(baseMovementID: "banded_pullups", variantID: "one", modifications: "Conflicting"), .create(baseMovementID: "banded_pullups", variantID: "x", modifications: " "), .create(baseMovementID: "banded_pullups", variantID: "x", modifications: String(repeating: "a", count: 201))] {
            #expect(throws: EngineError.self) { try changeMovementVariant(state: second.state, change: change, rules: rules, nextWorkout: slot) }
        }
    }

    @Test func pausedBaseCannotEscapeViaCreateSelectOrCorrectionAndResumeRebaselinesAll() throws {
        var (state, rules, slot, oldID) = try configurationInput()
        state.baseSafety!["banded_pullups"]!.paused = true
        state.exercises[oldID]!.mode = .paused
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: slot.date, slotID: slot.slotID)
        let created = try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "new", modifications: "+25 lb"), rules: rules, nextWorkout: slot)
        #expect(created.state.exercises["new"]!.mode == .paused)
        let renamed = try changeMovementVariant(state: created.state, change: .correctDescription(variantID: "new", modifications: "New label"), rules: rules, nextWorkout: slot)
        let selected = try changeMovementVariant(state: renamed.state, change: .select(baseMovementID: "banded_pullups", variantID: oldID), rules: rules, nextWorkout: slot)
        #expect(selected.workout.exercises.first { $0.movementID == oldID }!.sets.isEmpty)
        let resumed = try reconfigureProgram(state: selected.state, change: .safeResume(baseMovementID: "banded_pullups", externalClearanceConfirmed: true), rules: rules, nextWorkout: slot)
        for id in [oldID, "new"] { #expect(resumed.state.exercises[id]!.mode == .baseline && resumed.state.exercises[id]!.ceilingStreak == 0) }
        let goal = try reconfigureProgram(state: resumed.state, change: .goal(.maintenance), rules: rules, nextWorkout: slot)
        #expect(goal.state.exercises["new"]!.normalSets == 2)
        #expect(goal.state.config.variants == resumed.state.config.variants)
    }
}

extension VariantConfigurationTests {
    @Test func descriptionCorrectionPreservesExactUnicodeSpellingAndGraphemeLimit() throws {
        let (state, rules, slot, _) = try configurationInput()
        let original = "caf\u{00e9}"
        let corrected = "cafe\u{0301}"
        let created = try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "unicode", modifications: original), rules: rules, nextWorkout: slot)
        let changed = try changeMovementVariant(state: created.state, change: .correctDescription(variantID: "unicode", modifications: corrected), rules: rules, nextWorkout: slot)
        #expect(changed.state.config.variants!["unicode"]!.modifications.utf8.elementsEqual(corrected.utf8))
        #expect(changed.state.revision == created.state.revision + 1)
        #expect(changed.state.exercises == created.state.exercises)
        let emoji = String(repeating: "👩🏽‍🚀", count: 200)
        #expect(try changeMovementVariant(state: changed.state, change: .create(baseMovementID: "banded_pullups", variantID: "emoji", modifications: emoji), rules: rules, nextWorkout: slot).state.config.variants!["emoji"]!.modifications.count == 200)
        #expect(throws: EngineError.self) { try changeMovementVariant(state: changed.state, change: .create(baseMovementID: "banded_pullups", variantID: "too-long", modifications: emoji + "👩🏽‍🚀"), rules: rules, nextWorkout: slot) }
        #expect(throws: EngineError.self) { try changeMovementVariant(state: changed.state, change: .create(baseMovementID: "banded_pullups", variantID: "control", modifications: "text\u{0001}"), rules: rules, nextWorkout: slot) }
    }

    @Test func selectingRecentSavedVariantRestoresCountersAndOwnLoad() throws {
        var (state, rules, slot, oldID) = try configurationInput(base: "db_lateral_raise")
        state.exercises[oldID]!.load = Load(amount: "15", unit: .lb, basis: .perImplement)
        state.exercises[oldID]!.lastCompletedDate = try slot.date.adding(days: -27)
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: slot.date, slotID: slot.slotID)
        let created = try changeMovementVariant(state: state, change: .create(baseMovementID: "db_lateral_raise", variantID: "new", modifications: "Setup"), rules: rules, nextWorkout: slot)
        let selected = try changeMovementVariant(state: created.state, change: .select(baseMovementID: "db_lateral_raise", variantID: oldID), rules: rules, nextWorkout: slot)
        #expect(selected.state.exercises[oldID] == state.exercises[oldID])
        #expect(selected.state.exercises["new"]!.load == nil)
    }
}
