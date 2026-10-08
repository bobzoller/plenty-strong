# Exact Rep Prescriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each movement a deterministic exact rep goal for every set, show previous actual performance beside today's prescription, and record actuals independently using the Trainer's conditional double progression.

**Architecture:** Add an immutable exact-rep policy alongside both frozen legacy policies. Keep TrainingCore pure, append a replayable policy-activation event rather than rewriting history, and resolve every workout/draft by its own policy. A small presentation model supplies Last time / Today's goal / Actual to SwiftUI; backup and fake-cloud recovery validate the same archived transitions.

**Tech Stack:** Swift 6.4, Xcode 27.0 (27A266a), iOS 18+, SwiftUI, SwiftData opaque payloads, Foundation/CryptoKit, Swift Testing/XCTest, native Apple frameworks only.

**Spec:** `docs/superpowers/specs/2026-10-07-exact-rep-prescriptions-trainer-consult.md` (verbatim consultation) and `docs/superpowers/specs/2026-10-07-exact-rep-prescriptions-integration-design.md` (proposed integration interpretations). Read both. Existing selection constraints: `docs/specs/2026-10-05-fixed-exercise-selection-design.md` and `docs/specs/2026-10-05-fixed-exercise-profile.json`.

## Global Constraints

- “People want prescriptions.” Show previous actual performance, today's exact reps per set and prescribed load, and blank inputs for actual performance.
- “Effort, pain, and control always override the number.” A numerical shortfall is not automatically a failed workout.
- Normal copy: “Aim for the listed reps. Stop at that number, or sooner when another good rep would leave fewer than about two reps in reserve. Stop earlier for pain or loss of control.” Stricter copy is specified in the integration design.
- All-set effort scope; one exercise-level question; separate pain/control flags; conditional missed-goal reasons `effort_limit`, `time_interruption`, `other_unknown`.
- One TOTAL rep for all-goals-met/about-right building work; two per set for too-easy work; minimum target 1; bounds from current ceiling; lowest eligible set, ties earliest.
- Two comparable ceiling confirmations; maintenance requires two too-easy confirmations; maximum automatic load increase 10%; ceiling extension +2; maxima 20 ordinary/fallback and 8 low-rep strength.
- First too-hard targets `max(1, A[i]-1)` capped at ceiling; second comparable strain lowers to nearest available load; no available lower load requires setup review.
- Two comparable effort-limited misses rebase to achieved goals without a bonus. Later-set fatigue below the nominal floor alone is not strain.
- Baseline fitting receives no bonus. No history/load increase begins at preset floor: 8 ordinary/fallback, 4 low-rep strength.
- Return threshold 28 days; one fewer set/minimum one; at least four reps left; target prefix capped at floor; highest available load at or below 90% of retained load; clean return restores baseline at returned load.
- Easier sessions retain normal targets independently, use half normal sets rounded up/capped by smaller current dose, targets capped at floor, at least four reps left; no progression/strain/plateau credit.
- Comparable context includes variant/setup revision, actual load/unit/basis, normal set count, reserve/effort policy, rest, movement position, and rep-range policy. Changing only exact goals preserves comparability.
- Bodyweight load is nil. Modifications remain opaque independent variants; no accessory selectors, assistance arithmetic, or inferred resistance.
- Fixed Sunday/Tuesday/Thursday selection remains. Preserve goal presets; no new manual progression or set-count settings.
- iOS 18 minimum; current local checks use iOS 27.0/Xcode 27.0/Swift 6.4. Zero third-party runtime dependencies; offline execution; no account/subscription/telemetry; existing tips remain optional.
- Legacy resources, wire bytes, hashes, meanings and golden outputs remain unchanged. New policy is `general-fitness-exact-v1`, contract/state/envelope version 3. Unknown schema/policy pairs fail closed.
- Use synthetic/design fixtures only. No personal Trainer edits, live services, cloud provisioning, signing, device update, publication, merge or push under this plan.
- Exact integer rules are product adaptations; describe the combined policy as evidence-informed, not a scientifically validated rep forecast.

## Review Focus

1. A legacy draft or frozen Finish exists during upgrade: complete it under its original policy; never rewrite goals or fabricate all-set feedback (Task 4 tests `legacyDraftBlocksActivationUntilFinalized`).
2. A skipped middle set or asymmetric sides precedes later observations: retain indices and both sides, never shift sets, sum sides or invent zeros (Tasks 1/5 tests `indexedSetsPreserveGaps` and `testSkippedMiddleSetSurvivesReopen`).
3. Easier sessions occur near the 28-day boundary: they cannot renew normal-capacity evidence or erase retained goals (Task 3 test `easierCannotRefreshInterruptionClock`).
4. Performance exceeds goals while feedback is hard/unknown/conflicting: safety and strain win; no bonus or ceiling confirmation (Tasks 2/3 tests `overshootNeverBypassesQualification`).
5. A legacy client forks while another client activates exact policy: retain original branches, block working admission, and explain `mixed_policy_conflict` (Task 4 test `mixedPolicyForkPreservesOriginalsAndBlocksWork`).

---

## Execution context and file map

Planning baseline is remote `main` at `3a380970b8f92362d34bbd9ea83072b08c82bf2b`, inspected October 7, 2026. Planning worktree: `.worktrees/exact-rep-plan`, branch `bobzoller/exact-rep-plan`. Only planning artifacts are written here. At execution fetch `origin --prune`, resolve current remote default, and create/reuse isolation according to using-git-worktrees; start code work from that default branch and carry these three planning documents forward. Do not start from the device-demo or old initial-ios branch. Preserve the primary checkout's user-generated Xcode workspace. Native managed chat tools are unavailable in this session; the already-authorized repo-isolated collaboration fallback remains applicable.

Map (existing files are modified in their owning tasks; new files listed explicitly):

| Boundary | Main files and responsibility |
| --- | --- |
| Wire/policy contracts | `Contracts/ExactRep.swift` (new), existing Prescription/Observation/Program/Ruleset/RulesetCatalog: nil-preserving fields, exact-policy validation, immutable parameters/evidence |
| Supported policy dispatch | `Contracts/ProgramPolicy.swift` (new): exhaustive supported schema/version/hash capabilities |
| Vector planner | `Progression/ExactRepPlanner.swift` (new): rep-vector changes only, no load/calendar/UI work |
| Exact transitions | `Progression/ExactProgramAdvancer.swift`, `Progression/ExactExposureClassifier.swift`, `Program/ExactWorkoutPlanner.swift` (new): qualification, load progression, baseline, return, easier and configuration integration |
| Activation/replay | `Configuration/ProgramPolicyActivator.swift` (new), Journal/BackupService/TrainingRepository/RecoveryVerifier: immutable policy boundary and transactional admission |
| Workout observations | existing WorkoutViewModel/SetEntryView/EffortPicker plus `Features/Workout/MissedGoalReasonPicker.swift` (new): raw performed data, skipped slots, conditional reason |
| Presentation | `Features/Workout/MovementPrescriptionSummary.swift`, `Features/Workout/PrescriptionComparisonView.swift` (new), Today/Workout/History: prior result, exact goal and actual inputs |
| Tests | new exact suites alongside frozen core, repository, backup, cloud, model and UI suites; add explicit PBX references for new app/test files |

All `Contracts/`, `Progression/`, `Program/`, `Configuration/` paths in this map are below `Packages/TrainingCore/Sources/TrainingCore/`. Do not split unrelated legacy code or alter immutable legacy resources.

## Task 1: Versioned exact-policy contracts with legacy byte preservation

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Contracts/ExactRep.swift`, `Contracts/ProgramPolicy.swift`, `Resources/ruleset-exact-v1.json`.
- Modify: `Packages/TrainingCore/Sources/TrainingCore/Contracts/{Prescription,Observation,Program,Ruleset,RulesetCatalog}.swift`.
- Create/Test: `Packages/TrainingCore/Tests/TrainingCoreTests/ExactRepContractTests.swift`.
- Existing regression tests: `ContractTests.swift`, `PrimitiveTests.swift`, `FixedProgramTests.swift`, `ProgressionFixtureTests.swift` in the same test directory.

**Interfaces:**
- Produces `public enum ProgramPolicy: Equatable, Sendable { case numericV02, fixedCeilingsV1, fixedExactV1; static func resolve(schemaVersion: Int, rules: Ruleset) throws -> ProgramPolicy }`; allow only schema 1/numeric, 2/swift1, 3/exact-v1 with verified pinned hashes. Add `usesVariants: Bool` and `usesExactTargets: Bool` computed properties. No unknown-version fallback.
- Produces `validateExactRepContract(state: ProgramState, rules: Ruleset) throws` and `validateIndexedExactLog(_ log: ExerciseLog, prescription: ExercisePrescription) throws` for schema3 semantic validation; call them at admission/transition boundaries. They preserve partial/stopped raw zero/missing-side observations but require valid target shapes, scope and index binding; only ordinary complete qualification requires positive/equal-side work.
- Produces `RulesetCatalog.exactV1() throws -> Ruleset`, `RulesetCatalog.resolve(version: String, hash: String) throws -> Ruleset`; existing accessors remain frozen.
- Produces `MissedGoalReason` cases `.effortLimit`, `.timeInterruption`, `.otherUnknown` with specified snake-case wire values, and `EffortScope.allWorkingSets` (`all_working_sets`).
- Add `SetPrescription.targetReps: Int? = nil`; `ActualSet.setIndex: Int? = nil`, `missedGoalReason: MissedGoalReason? = nil`; `ExerciseLog.effortScope: EffortScope? = nil`, `skippedSetIndices: [Int]? = nil`, `mixedLoads: Bool? = nil`.
- Produces `ExactRepState: Codable, Equatable, Sendable` with `normalTargets: [Int]`, `shortfallStreak: Int`, `lastSuitableNormalDate: LocalDate?`, `setupReviewRequired: Bool`; add `ExerciseState.exactRepState: ExactRepState? = nil`.
- Produces `ExactRepContext: Codable, Equatable, Sendable` with `variantID: String`, `setupRevision: Int`, `load: Load?`, `normalSetCount: Int`, `minimumRir: Int`, `effortScope: EffortScope`, `restSeconds: Int`, `movementPosition: Int`, `repFloor: Int`, `repCeiling: Int`, `rulesetHash: String`; add `Exposure.prescribedTargets: [Int]?`, `exactRepContext: ExactRepContext?`.
- Add `PrescriptionKind.setupReview` (wire `setup_review`, no working sets). Existing initializer signatures remain source-compatible through trailing nil defaults.
- Add `ExactRepParameters` with `normalIncrementTotal = 1`, `easyIncrementPerSet = 2`, `minimumTargetReps = 1`, `returnMaximumLoadPercent = 90`; `RuleParameters.exactRep: ExactRepParameters? = nil`. Nil keys are omitted, never encoded as null.

- [ ] **Step 1: Write `ExactRepContractTests` with failing assertions.**

```swift
@Test func policiesAreExplicit() throws {
    let rules = try RulesetCatalog.exactV1()
    #expect(rules.version == "general-fitness-exact-v1")
    #expect(rules.contractVersion == 3)
    #expect(try ProgramPolicy.resolve(schemaVersion: 3, rules: rules) == .fixedExactV1)
    #expect(throws: EngineError.self) {
        try ProgramPolicy.resolve(schemaVersion: 2, rules: rules)
    }
    #expect(throws: EngineError.self) {
        try ProgramPolicy.resolve(schemaVersion: 4, rules: rules)
    }
}
```

Add `legacyOptionalFieldsRemainAbsent`: canonical encoding of legacy SetPrescription/ActualSet/ExerciseLog/ExerciseState/Exposure contains none of the added keys; decoding and encoding existing golden archives leaves bytes and all IDs unchanged. Add `indexedSetsPreserveGaps`: performed indices [0,2], skipped [1], raw reps [10,9] round-trip unchanged. Add `exactStateRejectsMissingOrInvalidTargets`: schema 3 requires targets count equal to normal sets, each 1...ceiling, explicit relevant snapshot fields, unique in-range actual/skip indices; schema 2 does not infer targets/scope. Reject malformed hash, unknown policy and changed parameter values without accepting caller-provided executable rules.

- [ ] **Step 2: Run failing contracts.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter ExactRepContractTests`. Expect missing symbols/fields initially; inspect the actual diagnostic.
- [ ] **Step 3: Implement the contracts and immutable manifest.** Keep explicit Codable implementations and `encodeIfPresent` for all new optional keys. Put schema-specific validation in ProgramPolicy/contract helpers, not fabricated decode defaults. `ruleset-exact-v1.json` retains existing goal presets/profile hash, sets `sourceRulesetHash` to `RulesetCatalog.fixedRulesetHash`, records all exact constants and the consultation's evidence limitations, and uses rule IDs X01–X13 (safety, observations, baseline, rep increments, ceiling/load, strain, shortfalls, return, easier, comparability, plateau, variants/configuration, activation). Source IDs EX01–EX09 correspond in order to ACSM 2026, Plotkin 2022, Refalo 2024, Halperin, ACSM 2009, NASM, Currier 2023, Murphy/Koehler 2022, Bickel 2011; use the consultation's URLs/limits, with operational rules `.appAdaptation` and activation `.softwareRequirement`. Compute the new canonical hash excluding `hash`, pin `RulesetCatalog.exactRulesetHash`, and validate the entire new manifest against that pinned value. Leave old manifests/constants byte-identical.
- [ ] **Step 4: Run `make test-core`.** Expect exit 0, new contract assertions and all legacy suites passing. Compare old resource SHA256 values to the execution baseline.
- [ ] **Step 5: Commit only Task 1 contracts/resource/tests.** `git commit -m "feat: add versioned exact-rep contracts"` after staging the explicit Task 1 files.

## Task 2: Pure conditional rep-vector planning

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Progression/ExactRepPlanner.swift`.
- Create/Test: `Packages/TrainingCore/Tests/TrainingCoreTests/ExactRepPlannerTests.swift`.

**Interfaces:**
- Consumes Task 1 `Goal`, `Effort`, `PrescriptionPhase`, `MissedGoalReason`, parameters.
- Produces `ExactRepPlanningInput` with constructor `(prescribed: [Int], actual: [Int], ceiling: Int, goal: Goal, phase: PrescriptionPhase, effort: Effort, missReasons: [MissedGoalReason?], shortfallStreak: Int)`; `ExactRepPlanningResult` fields `targets: [Int]`, `shortfallStreak: Int`, `kind: ExactRepPlanKind`.
- `ExactRepPlanKind`: `.hold`, `.increment`, `.rebase`, `.adopt`, `.fitBaseline`, `.reduceTargets`, `.observationConflict`.
- `ExactRepPlanner.plan(_ input: ExactRepPlanningInput) throws -> ExactRepPlanningResult`; accepts only complete indexed positive actuals normalized to set order, phase baseline/normal, no safety/unequal/mixed-load/floor-strain issue. Task 3 owns qualification/load actions.
- `resizeExactTargets(_ targets: [Int], to count: Int) throws -> [Int]` for a count-only transition: prefix on shrink, descending-by-one/minimum-one append on growth. `resizeExactExerciseState(_ exercise: ExerciseState, to count: Int) throws -> ExerciseState` applies that vector, updates normalSets, clears comparisons/shortfall/temporary-dose flags, retains load/setup/dates, and enters baseline (retained paused mode remains paused). This helper does not add a user-configurable dose.

- [ ] **Step 1: Write table-driven failing tests for the exact vectors.**

```swift
@Test func conditionalTargets() throws {
    let cases: [(Effort, [Int])] = [
        (.onTarget, [10,10,10]), (.tooEasy, [12,12,11]), (.tooHard, [9,9,8])
    ]
    for (effort, expected) in cases {
        let input = ExactRepPlanningInput(prescribed: [10,10,9], actual: [10,10,9],
            ceiling: 12, goal: .size, phase: .normal, effort: effort,
            missReasons: [nil,nil,nil], shortfallStreak: 0)
        #expect(try ExactRepPlanner.plan(input).targets == expected)
    }
    #expect(try resizeExactTargets([10,10,9], to: 4) == [10,10,9,8])
    #expect(try resizeExactTargets([2,1], to: 4) == [2,1,1,1])
}
```

Add `tieBreakAndSaturation`: [10,10,10] -> [11,10,10], [11,10,10] -> [11,11,10], [12,12,11] -> [12,12,12], all-12 remains all-12. Add `shortfallUsesPriorGoalsAndReason`: P=[10,10,10], A=[10,10,9], reason [nil,nil,.effortLimit] repeats P with streak 1, then rebases A with streak 0 on next matching miss; time/unknown reason repeats P and clears streak; no extra rep on rebase. Add `baselinePreservesFatigue`: baseline P=[8,8,8], A=[8,7,6], on-target -> [8,7,6] with no bonus. Add `maintenanceAndUnknownHold`: maintenance/about-right and unknown repeat P. Add `overshootNeverBypassesQualification`: P=[10,10,9], A=[11,11,10], known/non-hard -> A without bonus; A above ceiling holds P; hard feedback applies capped A-1 first; missed goal plus too-easy returns conflict/holds P. Add `resizingStateRetainsLoadAndRebaselines`: 40 lb/normal/[10,10,9]/3 sets with nonzero streaks becomes 40 lb/baseline/[10,10,9,8]/4 sets with zero comparisons and retained setup/date. Add invalid lengths, nonpositive targets/actuals, out-of-range P, invalid streak/phase, and bounded 1/20 targets; raw observations are not clamped.

- [ ] **Step 2: Run `xcrun swift test --package-path Packages/TrainingCore --filter ExactRepPlannerTests` with command-local DEVELOPER_DIR.** Expect missing planner symbols, then explicit unmet vector assertions; don't accept an unrelated build failure as evidence.
- [ ] **Step 3: Implement the planner and two resizing signatures.** Apply baseline/no-bonus, unknown/conflict, too-hard, within-ceiling overshoot adoption, reason-specific misses, maintenance hold, and met-goal effort rules in that order. Too-hard precedence over overshoot is intentional. Cap only generated targets; all-ceiling handling is a hold here because Task 3 owns confirmation/load/extension. Do not redistribute equal totals, infer RIR capacity, or consult dates/network.
- [ ] **Step 4: Run the planner suite and `make test-core`.** Expect exact vectors and all frozen suites passing.
- [ ] **Step 5: Commit the two Task 2 files.** `git commit -m "feat: plan conditional per-set rep goals"`.

## Task 3: Exact-policy transitions, qualification, fitting and recovery

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Progression/ExactProgramAdvancer.swift`, `Progression/ExactExposureClassifier.swift`, `Program/ExactWorkoutPlanner.swift`.
- Modify dispatch/integration only: `Progression/ProgramAdvancer.swift`, `Program/ProgramInitializer.swift`, `Program/WorkoutPreparer.swift`, `Program/FixedProgramSelector.swift`, `Configuration/WorkoutScheduler.swift`, `Configuration/ProgramReconfigurer.swift`, `Configuration/MovementVariantManager.swift`, `Configuration/BranchResolver.swift`.
- Create/Test: `Packages/TrainingCore/Tests/TrainingCoreTests/ExactRepTransitionTests.swift`, `ExactRepFixtureCompiler.swift`, `Fixtures/exact-rep-examples.json`.
- Existing regression tests: every legacy core fixture suite.

**Interfaces:**
- Consume Tasks 1–2; preserve public `initializeProgram(config:rules:firstWorkout:)`, `prepareWorkout(state:rules:easierToday:)`, `advanceProgram(_:)`, `reconfigureProgram(state:change:rules:nextWorkout:)`, `prepareInterruptedReturn(state:asOf:rules:)` and `changeMovementVariant(state:change:rules:nextWorkout:)` signatures.
- Produce internal `advanceExactProgram(_ input: AdvanceInput) -> AdvanceResult`, `plannedExactWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription` and `prepareExactWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool) throws -> WorkoutPrescription` behind exhaustive policy dispatch. Legacy code paths retain behavior.
- `ExactExposureClassifier.classify(log: ExerciseLog, prescription: ExercisePrescription, movement: Movement, state: ExerciseState, context: ExactRepContext) throws -> ExactExposureClassification`; classification contains actual vector, prior target vector, completion/side/load/reason qualification, goals-met/overshoot/floor/strain flags. Preserve original log separately.
- `sameExactContext(_ lhs: ExactRepContext, _ rhs: ExactRepContext) -> Bool`: compare every declared context field; exact target vector is deliberately outside the context.
- Test support `ExactRepFixtureCompiler.input(_ id: String) throws -> ExactRepFixtureOperation`, `expected(_ id: String) throws -> CanonicalValue`, `run(_ operation: ExactRepFixtureOperation) throws -> CanonicalValue`, `selectedMovementID(_ id: String) throws -> String` load frozen synthetic fixtures. `ExactRepFixtureOperation: Equatable` contains typed initialization, AdvanceInput, preparation, return-sequence and target-resizing inputs; `run` calls actual public core APIs and canonicalizes full results, while `expected` reads independently authored JSON. X10 is initialization, X14 is easier preparation plus unchanged normal state, X18 is return preparation then clean completion, X19 is the count-only exercise-state resizing helper; the remaining rows are advances. Full fixed-profile config; choose incline press for loaded examples, a permitted bodyweight variant for bodyweight, mark unrelated rows skipped. Encode exact scope/indices/reasons and consistent prescription hashes; no personal records.

- [ ] **Step 1: Add failing full-output transition fixtures for the consultation's 19 worked rows.** Store independent expected state/prescription/decisions in JSON, not outputs generated by the engine under test. Number X01–X19 in consultation table order; helper compiles only supplied input fields and independently declared expected outputs. Assert both repeated determinism and original input equality.

```swift
@Test(arguments: (1...19).map { String(format: "X%02d", $0) })
func trainerWorkedTransitions(_ id: String) throws {
    let input = try ExactRepFixtureCompiler.input(id)
    let original = input
    let expected = try ExactRepFixtureCompiler.expected(id)
    #expect(try ExactRepFixtureCompiler.run(input) == expected)
    #expect(try ExactRepFixtureCompiler.run(input) == expected)
    #expect(input == original)
}
```

Pin 40:[10,10,10], 40:[12,12,11], 40:[9,9,8], second-hard 35:[8,8,8]/baseline; first miss repeats [10,10,10], second miss [10,10,9]; first ceiling 50:[12,12,12], second 55:[8,8,8]; blocked 40->45 extends ceiling14 and yields [13,12,12]; no-history20:[8,8,8]; clean baseline[8,7,6]; bodyweight nil-load[10,10,10]; maintenance40:[10,10]; easier40:[8,8]/4 reserve retaining normal[10,10,9]; partial keeps [10,10,9]; overshoot adopts [11,11,10]/no confirmation; strength55:[4,4,4]; interruption45:[8,8]/4 reserve then baseline; count-only four-set [10,10,9,8]. X19 validates the full resized exercise state (same load, baseline mode, four targets and cleared counters); do not invent a manual four-set editor or violate the fixed profile to force an AdvanceInput. Two-step examples must assert both intermediate and following states.

Add `firstSetFloorSignalDoesNotPunishLaterFatigue` with baseline [8,7,6] accepted; first set 7 first occurrence holds P, second strain lowers; too-easy/floor contradiction holds. Add `contextBoundaries`: changing goals only remains comparable, changing actual load/basis/rest/position/reserve/range/variant/setup revision resets counters/window. Add `safetyWinsInEveryMode` pain/control in normal/baseline/easier/return/partial pauses shared base and emits no working sets. Add `overshootNeverBypassesQualification`: hard above-goal work reduces/reviews; unknown/asymmetric/mixed loads never confirms load; above-hard-ceiling actuals remain raw. Add `easierCannotRefreshInterruptionClock` spanning days 27/28 with an easier completion between; test date source uses last suitable normal, return boundary inclusive, paused setup unchanged, no date means baseline. Test return highest eligible load <=90%, no lower eligible equipment, and bodyweight variant unchanged. Add maintenance easy/non-easy streak distinction, baseline/return exclusion from ceiling, skips freeze versus unknown/partial resets, minimum-load/bodyweight second strain setup-review gate, counts-only resize versus goal-range reseeding, restricted movements, decimal 10% equality and large gap limits, six-comparable-exposure plateau for size/strength only, and stale/event-ID replay/no-mutation rejection.

- [ ] **Step 2: Run `xcrun swift test --package-path Packages/TrainingCore --filter ExactRepTransitionTests` with DEVELOPER_DIR.** Expect schema/policy rejection or missing helper tests until exact dispatch is implemented; retain legacy pass evidence separately.
- [ ] **Step 3: Implement exact transitions and integrate dispatch.** Use the integration design's precedence and explicit interpretations; qualification selects the Task 2 planner or baseline/return/load path. At ceiling, two qualifying known/non-hard normal confirmations choose the nearest higher load only within 10%; otherwise permitted +2 ceiling then apply effort rule under expanded ceiling. Above-goal adoption supplies no confirmation. No ceiling credit from baseline/return/easier/unknown/partial. Persist normal targets independently of temporary doses and dates only from suitable normal/baseline work. A count/range/setup context change clears all relevant counters. Existing shared restrictions and variant admission operate for schemas 2 AND 3 via ProgramPolicy, not numeric fallback. Pause/setup-review sets remain empty. Exact same-policy branch selection clears comparison windows, retains unioned safety and seeds a baseline; cross-policy resolution throws `mixed_policy_conflict` without mutations. Define all X01–X13 decision evidence/classification through the frozen exact rules archive. Keep v1 ProgressionRules/RecoveryRules/ExposureClassifier behavior untouched.
- [ ] **Step 4: Run `make test-core`.** Expect all 19 full golden cases plus additional qualification tests and unchanged legacy outputs. Add a bounded property sweep of target vectors 1...20 and confirm no generated goal lies outside 1...ceiling or safety gating.
- [ ] **Step 5: Commit explicit Task 3 source/fixtures/tests.** `git commit -m "feat: advance exact prescriptions with fitting and recovery"`.

## Task 4: Append-only policy activation and portable replay

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Configuration/ProgramPolicyActivator.swift`.
- Modify: `Packages/TrainingCore/Sources/TrainingCore/Contracts/Journal.swift`, `Backup/BackupService.swift`, `PlentyStrong/Persistence/TrainingRepository.swift`, `PlentyStrong/Cloud/RecoveryVerifier.swift`, `PlentyStrong/AppComposition.swift`, `Features/Onboarding/OnboardingView.swift`, `Features/Settings/ConflictResolutionView.swift`, `PlentyStrong.xcodeproj/project.pbxproj`.
- Create/Test: `Packages/TrainingCore/Tests/TrainingCoreTests/ExactPolicyActivationTests.swift`, `PlentyStrongTests/ExactPolicyRepositoryTests.swift`.
- Modify/Test: `PlentyStrongTests/{BackupTests,CloudRecoveryTests,CloudConflictTests}.swift`, `PlentyStrongTests/Support/CrashHarness/main.swift`, `PlentyStrongTests/Support/run-crash-proof.py`.

**Interfaces:**
- Consume exact policy and Task 3 transition APIs; existing opaque SwiftData payload schema remains unchanged.
- Produce `JournalCommand.activatePolicy(sourceRulesetHash: String, destinationRulesetHash: String, normalEvidenceEventIDs: [String], next: WorkoutSlot)` with kind `activatePolicy`, distinct keys and schema-3 envelope; preserve all old command encodings.
- Produce `public func activateProgramPolicy(state: ProgramState, sourceRules: Ruleset, destinationRules: Ruleset, legacyHistory: [JournalEnvelope], nextWorkout: WorkoutSlot) throws -> ConfigurationResult`: supported schema2->3 only; same exact policy is no-op. Preserve identity/load/safety/processed events/history clock, reset comparisons, seed floor targets in baseline, revise state and hash next workout.
- Produce `policyActivationEvidenceEventIDs(state: ProgramState, history: [JournalEnvelope]) throws -> [String]`: sorted source workout IDs from the verified causal prefix, used only to derive per-variant interruption dates. Select the latest legacy complete normal/non-hard/controlled same-load/setup workout or successful baseline with a confirmed load; validate its source prescription/phase through its verified parent. No legacy RIR scope or exact targets are synthesized. Activation replay verifies those IDs against the prior verified chain.
- Produce actor `TrainingRepository.activateExactPolicy(programID: UUID, expectedRevision: Int, expectedHeadHash: String) throws -> StoreSnapshot`; atomic source/destination archives, activation envelope, head and durable outbox. It uses the pending workout's slot/date; no external clock in replay. Require health ready and no saved draft of any kind.
- Extend `BackupService.transition(state: ProgramState, command: JournalCommand, rules: Ruleset, legacyHistory: [JournalEnvelope] = []) throws -> ConfigurationResult` and graph verifier to resolve archived source AND destination on activation; ordinary commands remain bound to their own state/policy. Add repository rule lookup `rules(for state: ProgramState) throws -> Ruleset` (exact version/hash), plus shared `RulesetCatalog.resolve` for view models.

- [ ] **Step 1: Add failing pure activation and repository/replay tests.**

```swift
@Test func activationKeepsLegacyMeaning() throws {
    let config = try selectFixedProgram(goal: .size, programID: UUID())
    let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
    let old = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: slot)
    let result = try activateProgramPolicy(state: old.state, sourceRules: RulesetCatalog.fixedV1(),
        destinationRules: RulesetCatalog.exactV1(), legacyHistory: [], nextWorkout: slot)
    #expect(result.state.schemaVersion == 3)
    #expect(result.state.config == old.state.config)
    #expect(result.state.processedEvents == old.state.processedEvents)
    #expect(result.workout.exercises.first?.sets.compactMap(\.targetReps) == [8,8,8])
    #expect(old.workout.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps == nil } })
}
```

`legacyDraftBlocksActivationUntilFinalized`: empty, observed and stopped old drafts all block; resume/finalize with v1, preserve raw bytes, then activate once, append exact workout and reopen. Frozen duplicate Finish must not produce two workouts or two activation records. `activationNormalEvidenceIgnoresLaterEasier`: legacy normal evidence then easier/partial sessions selects the normal source date; activation records exact source IDs, missing/stale/foreign evidence is rejected, and return due after 28 days remains due. `activationAtomicityAndStaleHead`: wrong revision/head, unhealthy store, wrong source hash and injected persistence failure leave exported old store identical. Extend process-kill proof around activation before/after save and reopen, verifying a wholly old OR wholly upgraded causal chain with matching head/outbox. `mixedArchivesReplayBothFormats`: exact root and v1->activation->exact chain round-trip in backup formats1/2, duplicate import idempotent, old prefix/archive bytes unchanged, missing source rules and future unknown policy reject before writes. `mixedPolicyForkPreservesOriginalsAndBlocksWork`: v1 fork with pain and exact activation fork both retained; health blocks training/activation and emits mixed-policy reason, no silent head preference/downgrade, export remains lossless. Ordinary schema3 same-policy conflict keeps explicit selection and unioned pause. `oldClientStyleAdmissionRejectsSchema3` proves an old version cannot silently read it as v1. New-policy unknown or malformed records are quarantined by fake-cloud recovery without altering verified originals.

- [ ] **Step 2: Run core activation tests and model tests.** Core: `xcrun swift test --package-path Packages/TrainingCore --filter ExactPolicyActivationTests`. App: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project PlentyStrong.xcodeproj -scheme PlentyStrong -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -parallel-testing-enabled NO -derivedDataPath DerivedData/Exact -only-testing:PlentyStrongTests CODE_SIGNING_ALLOWED=NO`. Expect missing activation API/unsupported schema while tests initially fail; use simulator-only synthetic stores.
- [ ] **Step 3: Implement activation transaction and archived-policy replay.** Add exhaustive activation decoding/admission, exact-rule archive selection and schema3 replay validation. Do not modify old rules or run a bulk re-encoding migration. Preserve the old parent `inputStateHash`; validate activation source under source rules and result under destination. New programs use exactV1; for existing healthy programs schedule activation at operation-idle/next-start with zero retained draft and no Finish in flight. Derive legacy normal dates only from the verified history/evidence IDs for conservative return checking, not exact-policy qualifications. Thread the verified prefix through BackupService activation replay in both formats and RecoveryVerifier; other transitions ignore that optional argument. No standalone user programming choice is required. Conflict UI explains “Workouts use different prescription versions. Your records are preserved; resolve this version conflict before continuing.” and supports existing lossless export; cross-policy resolution is deliberately deferred and a live-cloud release gate. Register new app/test files in all owning PBX targets, including crash harness where shared model files are compiled.
- [ ] **Step 4: Run core, full model suites and `make crash-proof`.** Expect both backup formats/replay, retained legacy draft, activation rollback/reopen, fake-cloud conflict and real process-kill assertions passing. No live account or schema/purchase calls. Keep historical failed/unavailable release gates separate from these fresh results.
- [ ] **Step 5: Commit explicit Task 4 activation/adapter/tests/project files.** `git commit -m "feat: activate exact policy without rewriting workout history"`.

## Task 5: Durable actuals, skipped slots and all-set effort feedback

**Files:**
- Modify: `Features/Workout/WorkoutViewModel.swift`, `Backup/BackupDocument.swift`, `Backup/BackupService.swift` draft validation, `PlentyStrong/Persistence/TrainingRepository.swift` draft prefix/admission validation.
- Create/Test: `PlentyStrongTests/ExactRepWorkoutModelTests.swift`.
- Modify/Test: `PlentyStrongTests/WorkoutViewModelTests.swift`, `PlentyStrong.xcodeproj/project.pbxproj`.

**Interfaces:**
- Preserve `recordSet(movementID:index:actual:) async throws`, `recordEffort(movementID:effort:) async throws`, `recordProblem(...)`, `recordStatus(...)`, `finish()`; v3 records assign/validate explicit set indices; legacy behavior unchanged.
- Produce `WorkoutViewModel.nextSetIndex(for movementID: String) -> Int?`, `skipSet(movementID: String, index: Int) async throws`, `recordMixedLoads(movementID: String) async throws`; `recordSet` receives ActualSet.missedGoalReason for an exact-goal shortfall. Shortfall reason is required for ordinary v3 performed-set logging, but emergency pain/control retention cannot be blocked for a missing reason.
- New v3 drafts initialize explicit `.allWorkingSets` metadata with unknown effort; `recordEffort` retains that scope only for v3. Normal shortfall with other/unknown reason holds without qualifying a miss streak; stopping early at intended effort can still be completed when all intended slots were performed.
- `WorkoutDraft.hasObservations` includes skipped slot acknowledgments/mixed-load flags as well as actuals/problems; skip must not unlock setup/easier changes or authorize silent discard. `validCompletion` counts explicit performed slots, not compact-array position; any skipped/missing/unequal slot is partial.

- [ ] **Step 1: Write failing XCTest model tests.** Add a local test helper `private func makeExact(goal: Goal = .size, date: String = "2026-10-08") async throws -> (WorkoutViewModel, TrainingRepository, URL)` using the existing temporary repository/clock pattern with exact-rule initialization; no shared real store. Include this concrete test before the additional named cases:

```swift
func testActualsRemainEmptyUntilRecorded() async throws {
    let (model, repository, _) = try await makeExact()
    try await model.start(easierToday: false)
    let draft = try XCTUnwrap(model.snapshot.draft)
    XCTAssertEqual(draft.displayed.exercises.first?.sets.compactMap(\.targetReps), [8,8,8])
    XCTAssertTrue(draft.logs.allSatisfy { $0.actualSets.isEmpty && $0.actualLoad == nil })
    XCTAssertTrue(draft.logs.allSatisfy { $0.effortScope == .allWorkingSets })
    await repository.close()
}
```

`testSkippedMiddleSetSurvivesReopen`: save set0=10, skip1, save set2=9; reopened indices [0,2], skipped[1], next index nil, actuals [10,9], truthful partial status, frozen observations unchanged. `testMissReasonChangesOnlyFuturePolicy`: same goal [10,10,10]/actual [10,10,9] with effort-limit versus time reasons yields different streaks; raw observation fields survive restart/Finish retry. `testEffortScopeAndLegacyDraft`: new scope explicit/all sets; old reopened draft keeps nil scope and old copy/qualification until completion. `testActualsRemainEmptyUntilRecorded`: starting goals creates no performed reps/load confirmation; over-goal values preserved; negative/malformed input rejected. `testPainWithPendingShortfallNeedsNoReason`: pain preserves pending raw reps and pauses even when reason/side/load unavailable. `testMixedLoadsPreservePartialWithoutAveraging`: mixed load flag/stop recorded once, no confirmation or invented per-set resistance. `testConcurrentSaveFinishAndActivation`: operation gate prevents activation/rebinding during Save/Finish; duplicate retries append one event; repair uses draft's original policy. Add count0/Int.max/duplicate-index/out-of-range-index raw input cases and explicit unknown shortfall reason.

- [ ] **Step 2: Run `xcodebuild test` using Task 4 settings plus `-only-testing:PlentyStrongTests/ExactRepWorkoutModelTests`.** Expect missing skip/index/metadata behavior; verify the failure is the new assertion.
- [ ] **Step 3: Implement the model interfaces and draft admission.** Use union of performed/skipped indices to select the next slot; skipping a slot must not acknowledge/lock the entire movement while later slots remain available; never use actual array count for v3. Keep one movement-level confirmed load, mixed-load correction partial, and original pending/problem preservation. Resolve rules from snapshot/draft policy for safety, preparing and Finish repair; remove fixedV1 hardcoding from these flows without changing legacy semantics. Preserve prefix immutability, operation leases, frozen Finish payload and rest timer. Add PBX test registration. Do not prefill actuals from target/last-time values.
- [ ] **Step 4: Run the new model suite and full `PlentyStrongTests` target with Task 4 command.** Expect raw data and operation/restart tests plus existing safety/lifecycle tests passing.
- [ ] **Step 5: Commit explicit Task 5 model/draft/tests/project files.** `git commit -m "feat: persist exact-workout observations and missed-goal reasons"`.

## Task 6: Last time / today's goal / actual workout experience

**Files:**
- Create: `Features/Workout/MovementPrescriptionSummary.swift`, `Features/Workout/PrescriptionComparisonView.swift`, `Features/Workout/MissedGoalReasonPicker.swift`.
- Modify: `Features/Today/TodayView.swift`, `Features/Workout/{WorkoutView,SetEntryView,EffortPicker}.swift`, `Features/History/{HistoryView,WorkoutDetailView,DecisionExplanationView}.swift`, `PlentyStrong.xcodeproj/project.pbxproj`.
- Create/Test: `PlentyStrongTests/MovementPrescriptionSummaryTests.swift`, `PlentyStrongUITests/ExactRepFlowTests.swift`.
- Modify/Test: `PlentyStrongUITests/{WorkoutFlowTests,HistorySettingsTests,OfflineAcceptanceTests}.swift`; test-only fixture setup where currently owned by `PlentyStrong/AppComposition.swift`.
- Modify: `docs/release/offline-acceptance.md`, `docs/release/v1-checklist.md`, `docs/release/testflight-notes.md` to state new comprehension/migration gates and mixed-policy conflict limitation.

**Interfaces:**
- Produce `MovementPrescriptionSummary.make(row: ExercisePrescription, state: ProgramState, history: [JournalEnvelope], draft: WorkoutDraft?) -> MovementPrescriptionSummary` with `prior: PriorPerformance?`, `targetReps: [Int]?`, `prescribedLoad: Load?`, `actualSets: [ActualSet]`, `isPriorComparable: Bool`, `policy: ProgramPolicy?` (invalid policy renders an unavailable/error state, never fabricated targets).
- `PriorPerformance`: date, raw actual sets, actual load, session mode, phase, effort scope, status. Choose most recent same-variant workout with performed observations before the current draft; do not substitute a default/sibling variant. Label different-load/easier/partial/legacy results explicitly as context, not qualifying comparable performance. Compare actual load, all required context and scope; no unavailable “last time” rep vector is invented.
- Produce `PrescriptionComparisonView(summary: MovementPrescriptionSummary, repCounting: RepCounting)` and `MissedGoalReasonPicker(selection: Binding<MissedGoalReason?>)`. Movement summary is read-only projection; the core, not the view, owns targets.
- New-policy labels exactly `Last time`, `Today's goal`, `Actual`; empty history `First workout for this setup`; normal goal string `10 / 10 / 10 reps` (append `per side` when applicable). Individual row `Set 1 goal: 10 reps`; actual field blank with `Reps performed`. Preserve legacy `Up to N good reps` copy only for legacy records/drafts.
- Effort question `How hard were the working sets?` with meanings from integration design. Miss-reason question `Why did you stop before the goal?`, options `Effort limit`, `Time or interruption`, `Other / I'm not sure`; shown only for below-goal new-policy sets. Continue pain/control stop without requiring reason. `Skip this set` records an explicit skip. Setup-review gate offers existing movement-setup/reset flow, no accessory prompt.

- [ ] **Step 1: Add failing projection and UI assertions.**

`lastPerformanceIsVariantSpecificAndRaw`: same-variant 40:[10,10,9] is shown beside next 40:[10,10,10]; earlier sibling record never borrowed; new-load 55:[8,8,8] shows prior50:[12,12,12] labeled different load; legacy range history supplies actuals but not implied previous exact goals. `partialSidesAndEasierStayVisible`: retain missing/unequal sides, different mode and indexed gaps. `noHistoryHasGoalsButNoActuals`: baseline [8,8,8], first-workout copy, all input fields empty.

```swift
func testLastTodayActualAreIndependent() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-reset-local-store", "-fixture-exact-reps"]
    app.launch()
    app.buttons["today.start"].tap()
    // New synthetic fixture: same variant, actual 40:[10,10,9], next 40:[10,10,10].
    XCTAssertEqual(app.staticTexts["movement.last-reps"].label, "10 / 10 / 9 reps")
    XCTAssertEqual(app.staticTexts["movement.goal-reps"].label, "10 / 10 / 10 reps")
    XCTAssertTrue(["", "Reps performed"].contains(app.textFields["set.reps"].value as? String ?? ""))
}
```

Create deterministic test-only exact fixture modes for normal, no-history, baseline, legacy unfinished, easier, per-side and setup-review cases; all use disposable simulator stores with a fixed synthetic clock (`2026-10-08T20:00:00Z`, Pacific/Honolulu), no phone launch/reset flags. Test conditional reason appears only below goal; all-set effort definitions; skip middle slot retains correct third goal; pause wins despite pending reason; Today/active/finished summary/history display exact planned versus actual versus saved next goals. Legacy histories/drafts keep ceiling copy and old feedback wording. VoiceOver labels distinguish prior/goal/actual and each side; largest text size, dark mode and Reduce Motion do not hide entry/stop controls. History states product-adaptation basis without claiming validated forecasts; decision copy explains repeat, +one total, easy +two per set, rebase, strain, new load, baseline, return, equipment/setup limits and no-comparison outcomes.

- [ ] **Step 2: Run projection tests and ExactRepFlowTests using Task 4 xcodebuild settings with `-only-testing:PlentyStrongTests/MovementPrescriptionSummaryTests` and `-only-testing:PlentyStrongUITests/ExactRepFlowTests`.** Expect missing summary/copy/fixture failures. Register tests in project before attempting discovery.
- [ ] **Step 3: Implement projections and views.** Read the frozen row/draft target values and immutable accepted history, never calculate next targets in SwiftUI or prefill actuals. Add PBX app/test references and test-only fixture registration; runtime fixture switches remain Debug-only and inert services. Show target vector/load on Today, active movement and completion summary; display prescribed/actual/saved-next separately in workout details. Explain correct early stopping without a failure badge or demand to beat last time. Offer explicit setup review and unsupported mixed-policy conflict handling as specified. Update release docs to describe human comprehension checks, versioned-data upgrade proof and deferred cross-policy conflict resolution before live cloud rollout.
- [ ] **Step 4: Run targeted UI/projection suites, then `make verify-current` and `make verify`.** Use current/minimum destinations from Makefile; record actual nonzero results or unavailable runtimes as open gates. Required evidence is source-bound core/model/UI/crash/unsigned Release results, not a synthetic list of passes. Full old/new suites must cover archived migration, offline actual logging and exact next targets. Minimum iOS 18 and human comprehension remain required gates; a current-runtime pass does not waive them. Do not install this build on Bob's phone or enable cloud during tests. Update release checklist only with actual evidence, no historical pass-count substitution.
- [ ] **Step 5: Commit explicit Task 6 presentation/tests/release docs/project files.** `git commit -m "feat: show prior results exact goals and independent actuals"`.

## Completion and review contract

Execute Task 1 -> 2 -> 3 -> 4 -> 5 -> 6; each is a separate implement/test/review gate. Preserve Bob's previously chosen subagent-driven execution method: fresh implementer and fresh reviewer per task, followed by whole-branch review. Do not dispatch helpers from implementers/reviewers. Root handles plan self-review, not a new review subagent. Delegated work receives a self-contained scope/interfaces/test contract and successful parent started/material/completion messages under Tech Lead AGENTS.md. Use Sol 6.1 High for hard implementation/review, Medium for bounded work, isolated `bobzoller/` branches from refreshed remote default.

After local implementation, report exact source SHA, failures/unavailable gates, new/legacy fixture results, backup/restart/activation proof and remaining human/cloud/device/publication limits. No merge, push or deployment follows automatically. A phone update is a distinct user-authorized action preserving its existing data. Execution approval is not approval to resolve mixed-policy cloud branches by dropping records.

## Plan self-review record

- Spec coverage: consultation sections 1/9 provenance are Task 1 manifest/release copy; section2 targets/effort/reasons Tasks1/5/6; sections3/4 vectors/load/strain Tasks2/3; section5 goals/equipment Tasks2/3; section6 initial/return/count changes Tasks2/3; section7 raw/incomplete behavior Tasks1/3/5; all 19 section8 examples Task3 full outputs; pure/versioned offline execution Tasks1–6. Integration activation/version/conflict constraints Task4; user Last/Goal/Actual experience Task6.
- Type consistency: optional wire fields and explicit all-set metadata are defined in Task1; planner inputs/results in Task2; full fixture/compiler and transition APIs in Task3; activation command/repository API Task4; indexed raw logging Task5; projection and UI Task6. No later task consumes an undeclared function.
- Review Focus: each of five classes names its owning test above. Legacy archive bytes and new policy admission are tested separately, not relabeled or regenerated.
- Proportion/steps: six meaningful gates, signatures plus assertions rather than implementation transcripts; setup/project registration included with the deliverable that needs them. The separate integration spec openly marks proposed interpretations, including the deliberately deferred mixed-policy recovery capability.
- Validation at planning time: document/reference/coverage checks only. No product code changed or runtime verification claimed. Execution must establish its own current baseline and required gate evidence.
