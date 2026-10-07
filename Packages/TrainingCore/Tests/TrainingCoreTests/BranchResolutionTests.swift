import Foundation
import Testing
@testable import TrainingCore

struct BranchResolutionTests {
    @Test func selectingCleanBranchCannotClearOtherBranchPain() throws {
        let fixture = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch")
        let result = try resolveCloudBranches(fixture.input)
        #expect(result == fixture.expected)
        #expect(try CanonicalJSON.encode(FixtureCompiler.canonical(result)) == CanonicalJSON.encode(FixtureCompiler.canonical(fixture.expected)))
        #expect(result.state.exercises[result.state.config.activeVariantIDs!["incline_db_press_24"]!]!.mode == .paused)
        #expect(result.state.exercises[result.state.config.activeVariantIDs!["incline_db_press_24"]!]!.ceilingStreak == 0)
    }
}

extension BranchResolutionTests {
    @Test func compatibleDistinctVariantsStaySeparateAndBodyweightTextIsOpaque() throws {
        var input = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch").input
        let base = "banded_pullups"
        for i in input.branches.indices {
            let id = i == 0 ? "saved-left" : "saved-right"
            let result = try changeMovementVariant(state: input.branches[i].state,
                change: .create(baseMovementID: base, variantID: id, modifications: "+25 lb"), rules: input.rules, nextWorkout: input.next)
            input.branches[i].state = result.state
        }
        input.selection.configurationHeadHash = input.selection.selectedHeadHash
        let original = input
        let resolved = try resolveCloudBranches(input)
        for id in ["saved-left", "saved-right"] {
            #expect(resolved.state.config.variants![id]!.modifications == "+25 lb")
            #expect(resolved.state.exercises[id]!.load == nil)
            #expect(resolved.state.exercises[id]!.mode == .baseline)
            #expect(resolved.state.exercises[id]!.ceilingStreak == 0)
        }
        #expect(resolved.state.config.activeVariantIDs![base] == "saved-left")
        #expect(input == original)
    }
    @Test func exactUnicodeDescriptionConflictNeedsExplicitDefinitionChoice() throws {
        var input = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch").input
        for i in input.branches.indices {
            let state = try changeMovementVariant(state: input.branches[i].state,
                change: .create(baseMovementID: "banded_pullups", variantID: "same-id", modifications: i == 0 ? "cafe\u{0301}" : "caf\u{00e9}"), rules: input.rules, nextWorkout: input.next).state
            input.branches[i].state = state
        }
        input.selection.configurationHeadHash = input.selection.selectedHeadHash
        #expect(throws: EngineError.self) { try resolveCloudBranches(input) }
        input.selection.variantDefinitionHeadHashes = ["same-id": "clean-head"]
        let result = try resolveCloudBranches(input)
        #expect(Array(result.state.config.variants!["same-id"]!.modifications.utf8) == Array("cafe\u{0301}".utf8))
        input.selection.variantDefinitionHeadHashes = ["same-id": "pain-head"]
        #expect(throws: EngineError.self) { try resolveCloudBranches(input) }
    }
    @Test func selectedConfigurationCannotWaiveSiblingVariantPauseOrRestrictions() throws {
        var input = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch").input
        let base = "incline_db_press_24"
        input.branches[0].state = try changeMovementVariant(state: input.branches[0].state,
            change: .create(baseMovementID: base, variantID: "new-press", modifications: "Clean setup"), rules: input.rules, nextWorkout: input.next).state
        #expect(throws: EngineError.self) { try resolveCloudBranches(input) }
        input.selection.configurationHeadHash = "clean-head"
        let result = try resolveCloudBranches(input)
        #expect(result.state.baseSafety![base] == MovementSafetyState(paused: true, minimumRir: 4, sourceEventIDs: ["pain-observation"]))
        for (id, definition) in result.state.config.variants! where definition.baseMovementID == base {
            #expect(result.state.exercises[id]!.mode == .paused)
            #expect(result.state.exercises[id]!.ceilingStreak == 0)
            #expect(result.state.exercises[id]!.recentComparable.isEmpty)
        }
        #expect(result.workout.exercises.first { $0.baseMovementID == base }!.sets.isEmpty)
    }
}

extension BranchResolutionTests {
    @Test func unrelatedAncestorAndDuplicateHeadsReject() throws {
        var input = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch").input
        let saved = input
        input.commonAncestor.config.programID = "00000000-0000-0000-0000-000000000999"
        // Valid fixed profile with newly derived IDs, but an unrelated program.
        input.commonAncestor = try initializeProgram(config: selectFixedProgram(goal: .size,
            programID: UUID(uuidString: input.commonAncestor.config.programID)!), rules: input.rules, firstWorkout: input.next).state
        #expect(throws: EngineError.self) { try resolveCloudBranches(input) }
        input = saved; input.competingHeadHashes.append(input.competingHeadHashes[0])
        #expect(throws: EngineError.self) { try resolveCloudBranches(input) }
    }
}
