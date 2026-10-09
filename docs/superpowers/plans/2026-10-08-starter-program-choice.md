# Starter Program Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offer two emphasis-based starter programs, including the Trainer's whole-body/glute routine, with correct exact prescriptions, introductory dose, history-preserving switching and decorative line-art cards.

**Architecture:** Preserve the immutable schema-1/2/3 execution paths and add explicitly pinned schema-4 starter policies. A profile catalog and movement-dose resolver feed a focused new planner/advancer; shared variant capacity uses bounded context-specific evidence. Profile changes are typed, transactional journal events with retained safety and lossless replay; existing SwiftData opaque payload storage remains unchanged.

**Tech Stack:** Swift 6.4, Xcode 27, SwiftUI, Foundation, SwiftData, native CloudKit/StoreKit adapters, Swift Testing/XCTest; zero third-party runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-10-08-starter-program-choice-design.md` and verbatim `docs/superpowers/specs/2026-10-08-second-starter-program-trainer-consult.md`. Read both; Bob approved these integration decisions on October 8, 2026. Consultation SHA256: `0dcb5a00c8f817c5059553d19907a7cfe6c74864ab08b192a9f3f5a09a6d6ff6`.

## Global Constraints

- Minimum iOS 18; Xcode 27 / Swift 6.4; zero third-party runtime dependencies.
- Offer exactly **Upper-body emphasis** and **Whole-body, glute emphasis**; both available to anyone; goal remains `fat_loss`, `size`, `strength`, or `maintenance`.
- “Choose the emphasis you want. Either program is for anyone.” No sex-derived program, starting load, or eligibility.
- Sunday/Tuesday/Thursday; six movements per glute slot in the spec's exact order; two-set phase 36/12–12–12 and established size/strength 44/15–13–16 weekly/slot sets.
- Equipment: dumbbells 5–80 lb in 5 lb steps and adjustable bench; pull-up bar required only for the original upper-body profile. No accessory tracking or equipment-recommendation matrix.
- Preserve original upper routine and all schemas 1–3, resources, pins, canonical bytes, replay behavior and original raw observations. Trainer section 9 redistribution is deferred.
- Paired loads remain pounds per hand; single loads remain total; bodyweight remains null. Unilateral sets require independent sides and count once, not twice.
- Pain/control and stricter retained safety override numerical goals; no mandatory failure, fabricated actuals, inferred effective resistance or simultaneous introductory set/load increase.
- New registered schema/contract 4 policies: `general-fitness-upper-exact-v2` / `starter-upper-v1` and `general-fitness-glute-exact-v1` / `starter-glute-v1`; calculate real canonical hashes, never placeholder hashes.
- Every new glute program starts at two sets; only RDL/press/row/suitcase squat graduate to three for size/strength after two qualifying normal exposures in one context.
- Keep training deterministic/offline and independent of tips/cloud/LLMs; preserve “No account, no subscription, no telemetry.”
- Synthetic fixtures only; no edits to Bob's Trainer records, live provisioning, cloud schema, signing, purchase, install, publication, merge or push under this plan.
- Create only `bobzoller/` branches. Execution worktree starts from current remote default branch, never a cached feature ref.

## Review Focus

- A saved schema-2/3 draft or frozen Finish survives upgrade unchanged; program switching is blocked until it is explicitly resolved (Task 4).
- A paused/stricter movement absent from one profile remains restricted when switching back, including changed press/row angles and bridge loading alternatives (Task 4).
- Same-position rows following different preceding work never combine confirmations, and changing weekdays never erases another valid window (Task 3).
- An awkward bridge setup or unequal unilateral work remains representable without invented load/reps or progression credit; entry and safety controls stay usable (Tasks 2 and 5).
- Introductory set growth coinciding with a ceiling confirmation creates only the three-set baseline at the same load; completion/history show frozen actual/goal/next values despite later Settings changes (Tasks 3–5).

---

## Execution base and file structure

Planning inspected `6a1860f68214de1cca6f04290f2b6484500c03f7` on local `bobzoller/exact-rep-prescriptions`, currently kept unmerged/unpushed by Bob. This exact-rep implementation is a prerequisite, not guaranteed present on remote main. Before execution, use using-git-worktrees and initialize from freshly fetched origin default; verify that base contains the approved exact-rep implementation. If absent, obtain the integration decision or a verified authorized remote head/replay contract first. Do not start by copying a stale local feature branch or reimplementing the old ceiling policy. Planning artifacts are not implementation authorization.

| Unit | Responsibility / file group |
| --- | --- |
| Starter contracts/catalog (Task 1) | `Contracts/StarterProgram.swift`, `Program/StarterProgramCatalog.swift`, `Program/MovementDoseResolver.swift`, frozen profiles/rules; exact IDs, doses, capabilities and hashes |
| Prescriptions/configuration (Task 2) | `Program/StarterWorkoutPlanner.swift`, `Validation/StarterProgramValidator.swift`; movement-specific initialization, handling/load modes, goal/setup/easier/return preparation |
| Progression (Task 3) | `Progression/StarterProgramAdvancer.swift`, `Progression/StarterComparisonContext.swift`, `Progression/StarterIntroductoryDose.swift`; shared targets, context evidence and one-time set growth |
| Profile transition/recovery (Task 4) | `Configuration/StarterProgramSwitcher.swift`, `Configuration/StarterSafetyLedger.swift`, existing repository/backup/cloud adapters; append-only switching, atomicity and archive capability dispatch |
| Product flow/art (Task 5) | `Features/ProgramChoice/*`, onboarding/settings/setup/history adapters; selection, preview, cues, accessible vector illustrations and protected switching |
| Acceptance/release evidence (Task 6) | independent starter examples, full current/minimum checks and release docs; final source/artifact identity and retained unavailable gates |

Paths starting `Contracts/`, `Program/`, `Progression/`, `Configuration/`, or `Validation/` above are relative to `Packages/TrainingCore/Sources/TrainingCore/`. App feature paths are repository-root `Features/`, not `PlentyStrong/Features/`. Register new app/test Swift files and app JSON resources in the explicit `PlentyStrong.xcodeproj/project.pbxproj`; Swift Package resources/tests are already processed by their directories. Do not globally restructure existing files.

### Task 1: Frozen starter catalogs, contracts and dose resolution

**Files:**
- Create under `Packages/TrainingCore/Sources/TrainingCore/`: `Contracts/StarterProgram.swift`, `Program/StarterProgramCatalog.swift`, `Program/MovementDoseResolver.swift`.
- Create resources: `starter-upper-v1.json`, `starter-glute-v1.json`, `ruleset-upper-exact-v2.json`, `ruleset-glute-exact-v1.json` under that source root's `Resources/`.
- Create source design data: `docs/specs/2026-10-08-glute-starter-profile.json`.
- Modify: `Contracts/Program.swift`, `Contracts/Ruleset.swift`, `Contracts/RulesetCatalog.swift`, `Contracts/ProgramPolicy.swift`, `Program/FixedProgramSelector.swift`, `Configuration/WorkoutScheduler.swift` under the source root (registered metadata projection lookup for new profiles).
- Test: `Packages/TrainingCore/Tests/TrainingCoreTests/StarterProgramCatalogTests.swift`, existing `FixedProgramTests.swift`, `ExactRepContractTests.swift`.

**Interfaces:**
- Consumes: existing `Goal`, `Movement`, `MovementVariant`, `ExerciseState`, `ExactRepContext`, `Exposure`, `Ruleset`, `ProgramConfig`, `selectFixedProgram(goal:programID:)`, `defaultVariantID(programID:baseMovementID:)`.
- Produces: `StarterProgramChoice: String, Codable, CaseIterable, Sendable` with `.upperBody = "upper_body"`, `.wholeBodyGlutes = "whole_body_glutes"`; `StarterProgramCatalog.definition(_ choice: StarterProgramChoice) throws -> StarterProgramDefinition`; `StarterProgramCatalog.choice(for config: ProgramConfig) throws -> StarterProgramChoice` (registered old profile maps to upper for display only; unknown profile throws); `RulesetCatalog.starter(_ choice: StarterProgramChoice) throws -> Ruleset`; `selectStarterProgram(choice: StarterProgramChoice, goal: Goal, programID: UUID) throws -> ProgramConfig`.
- `StarterProgramDefinition: Decodable, Equatable, Sendable` has `choice`, `schemaVersion`, `profileID`, `contentHash`, `sourceProfileID`, `sourceProfileHash`, `variantPolicyVersion`, `daysPerWeek`, `coveragePolicy`, `movements: [Movement]`, `weeklySlots: [WeeklySlot]`, `requiredMuscleGroups: [String]`, `initialLoads: [String: Load?]`, `requiredEquipment: [String]`; schema4, three days, fixed coverage and movement-variant-v1 are frozen. Dose/safety maps live in supplied immutable rules, not duplicated in mutable configuration.
- Produces: `MovementDose: Codable, Equatable, Sendable` with `initialSets`, `establishedSets`, `repFloor`, `initialRepCeiling`, `restSeconds`, `maximumRepCeiling`, `allowsIntroPromotion`, `requiresHandlingReview`; `resolveMovementDose(config: ProgramConfig, variantID: String, exercise: ExerciseState?, rules: Ruleset) throws -> MovementDose`; `resolveEffectiveMovement(config: ProgramConfig, variantID: String, rules: Ruleset) throws -> Movement`.
- Produces optional wire fields: `ExerciseState.starterState`, `ProgramState.retainedSafety`, `MovementVariant.loadingModeOverride`; legacy nil fields omitted. `StarterExerciseState: Codable, Equatable, Sendable` contains `doseStage: StarterDoseStage` (`introductory`, `established`, `fixed`), `strengthHandling: StrengthHandlingChoice?` (`standardRange`, `lowRep(load: Load)`), `windows: [String: StarterComparisonWindow]`.
- `StarterComparisonWindow: Codable, Equatable, Sendable` contains `slotID`, `contextKey`, `context: ExactRepContext`, `precedingDose: [StarterPrecedingMovement]`, `ceilingStreak`, `strainStreak`, `shortfallStreak`, `introStreak`, `exposures: [Exposure]`; preceding entries contain `baseMovementID`, `normalSetCount`. One current window per slot, at most three. Rules gain optional `starterDoses: [String: [String: MovementDose]]` and `safetyFamilies: [String: String]` with frozen goal/movement keys.

- [ ] **Step 1: Write failing catalog/dose/legacy tests.** `allChoiceGoalPairsMatchFrozenDefinitions` checks all eight pairs, exact glute orders, initial 36/12–12–12, established 44/15–13–16, distinct equipment, paired/single/null basis and per-side meaning. Pin every range/rest/set value to the spec table. `rdlStrengthIsSixToTenAt180Seconds` for the glute profile asserts 6/10/180/cap20; approved glute press/row/squat asserts 4/6/180/cap8; upper doses match every original preset, including its original RDL strength range; other strength movements retain their listed ranges/rest. `newProfilesScheduleOnCalendarDaysAndRejectTamperedMetadata` asserts SUN2026-10-11, MON2026-10-12→TUE2026-10-13 and rejection of a tampered movement/slot/profile pin. `oldPolicyBytesAreUnchanged` checks existing profile/rules hashes, old optionals omitted and old golden bytes. `legacyNewFieldsCannotSmuggleSchemaFourMeaning` rejects non-nil starter state/retained safety/loading overrides in schemas1–3 while keeping all old nil encodings identical.

```swift
@Test func oldPolicyBytesAreUnchanged() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    #expect(try RulesetCatalog.exactV1().hash == "b5b1100ee68edbe76384c31a3c8e1af918b4f5e3737f701ed0a6745989c3c73f")
    #expect(try selectFixedProgram(goal: .size, programID: id).profileHash == "e63a0543d54108af99637ed52dacebc1276e766b4314bc095891248efd7ce8ce")
}
```

- [ ] **Step 2: Run RED.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter StarterProgramCatalogTests`. Expect named missing new contracts/catalog, not toolchain/resource failure.
- [ ] **Step 3: Implement the declared contracts/catalog/resolvers.** Copy exact tables/orders/cues/coverage accounting from the spec/consultation; upper data derives from the unchanged existing profile. Register exhaustive schema/version/hash/profile tuples through `.starterExactV1`; add `ProgramPolicy.schemaVersion` and capability checks rather than `>= 3`. Preserve old `selectFixedProgram` and metadata validation, branch new validation to its registered projection. Register P01 movement dose, P02 intro promotion, P03 comparison context, P04 program switch, P05 handling review and P06 loading alternative in both new manifests, alongside unchanged-meaning X rules; their evidence labels distinguish app adaptations and software requirements. Generate canonical pins independently from JSON excluding its own hash field; dose/safety tables are included in immutable rules. Source archives link the new upper to the existing runtime profile (ID fixed-home-gym-v0.2/hash e63a0543d54108af99637ed52dacebc1276e766b4314bc095891248efd7ce8ce) and the glute runtime to source ID glute-starter-design-v0.1/schema1/contentHash in the new source design JSON. `StarterProgramCatalog.validateProjection(_ config: ProgramConfig) throws -> Void` uses registered constant pins and supplied metadata without resource I/O; `WorkoutScheduler.nextSlot` uses it for new profile IDs while retaining the exact old-profile check. Keep core hot paths supplied-value-only, without bundle reads.
- [ ] **Step 4: Run GREEN and legacy contract checks.** Run the Step 2 command, then core filters `FixedProgramTests` and `ExactRepContractTests`; require zero failures and unchanged old resources. Mutated goal/dose/movement/profile/rules pins and unknown tuples must reject rather than fall back.
- [ ] **Step 5: Commit** the explicitly listed catalog/contracts/resources/tests: `feat: add immutable starter program catalogs and doses`.

### Task 2: Movement-specific prescriptions and honest setup modes

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Program/StarterWorkoutPlanner.swift`, `Validation/StarterProgramValidator.swift`, `Configuration/StarterProgramReconfigurer.swift`.
- Modify: `Program/ProgramInitializer.swift`, `Program/WorkoutPreparer.swift`, `Configuration/ProgramReconfigurer.swift`, `Configuration/MovementVariantManager.swift`, `Configuration/WorkoutScheduler.swift` (new-policy return dispatch), `Contracts/Journal.swift`, `Contracts/ProgramPolicy.swift` under that source root.
- Test: `Packages/TrainingCore/Tests/TrainingCoreTests/StarterWorkoutPlannerTests.swift`.

**Interfaces:**
- Consumes: Task 1 catalog, dose/effective-movement resolvers and starter state; existing `ConfigurationResult`, `WorkoutPrescription`, `prepareWorkout`, `WorkoutScheduler`.
- Produces: `plannedStarterWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription`, `prepareStarterWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool) throws -> WorkoutPrescription`, `validateStarterProgram(state: ProgramState, rules: Ruleset) throws -> Void`, `reconfigureStarterProgram(state: ProgramState, change: ConfigurationChange, rules: Ruleset, nextWorkout: WorkoutSlot) throws -> ConfigurationResult`; `markStarterInterruptedReturn(state: inout ProgramState, variantID: String, asOf: LocalDate, rules: Ruleset) throws -> Decision?`.
- Produces: `VariantChange.createLoadingMode(baseMovementID: String, variantID: String, modifications: String, mode: LoadingMode)`; admit only schema4 bridge/bodyweight creation. Switching back to numeric bridge selects its existing external-load variant; ordinary text-only variant creation retains its explicitly selected effective mode through the typed creation command, never text inference.
- Produces: `ConfigurationChange.reviewStrengthHandling(variantID: String, choice: StrengthHandlingChoice)`; the recorded low-rep load must match the confirmed current load. Existing reconfiguration/variant APIs dispatch schema 4 into the new resolver path.

- [ ] **Step 1: Write failing planner/setup tests.** `introSizeHasTwoSetsAndHeterogeneousRangesAndRest` asserts bridge targets [10,10]/rest120, calf [10,10]/90, heel tap [6,6]/60 and remaining spec floors. `strengthHandlingReviewEmitsNoWorkingSetsUntilExplicitChoice` asserts no unreviewed glute-strength press/row/squat working sets; standard choice gives 8–12, matched low-rep choice 4–6, changed load/setup invalidates approval. `bodyweightBridgeIsTypedIndependentVariant` asserts null load/empty catalog/count0/no load progression and independent baseline; external bridge retains single total load. `unilateralMissingAndUnequalSidesRemainRaw` preserves left7/rightnil and left8/right6 with no fabricated equality or credit. `easierAndReturnUseEachMovementFloorAndReserve` asserts min4 RIR and reduced sets without modifying retained normal goals. `goalAndSetupChangesResolveTheirNewDose` tests each goal, variant creation, baseline reset and strict safety.

```swift
@Test func introSizeHasTwoSetsAndHeterogeneousRangesAndRest() throws {
    let config = try selectStarterProgram(choice: .wholeBodyGlutes, goal: .size, programID: UUID())
    let rules = try RulesetCatalog.starter(.wholeBodyGlutes)
    let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
    let initial = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
    let bridge = try #require(initial.workout.exercises.first { $0.baseMovementID == "db_floor_glute_bridge" })
    #expect(bridge.sets.compactMap(\.targetReps) == [10,10])
    #expect(bridge.restSeconds == 120)
    #expect(initial.workout.exercises.reduce(0) { $0 + $1.sets.count } == 12)
}
```

- [ ] **Step 2: Run RED.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter StarterWorkoutPlannerTests`; expect missing new dispatch/planner assertions.
- [ ] **Step 3: Implement those interfaces and initialization dispatch.** New glute starts two sets; upper uses its existing goal dose. Effective bridge mode is explicit and accepted only for the schema-4 bridge; no modifications-text parsing. Unreviewed glute low-rep handling produces setup review, not assumed capability; new upper profiles retain the original eligibility. Schema4 original global `ceilingStreak`, `strainStreak`, `recentComparable` and exact `shortfallStreak` stay zero/empty; the window fields own those counters. Keep introStreak in0...1 between persisted events, counters below their configured thresholds, and at most three windows with unique slotIDs. Use existing exact stopping copy and stricter reserve handling unchanged. Validate every state's dose stage, contextual capacity, prescription identity, load catalog and per-side structure with its own registered rules; do not relax schema-3 invariants. Handle new goal/setup/handling commands with no draft-side inference; dispatch interruption preparation to `markStarterInterruptedReturn` so effective loading and all context resets remain correct; initialize current family ledger and update it through explicit safe-resume/stricter-reserve commands.
- [ ] **Step 4: Run GREEN plus regression checks.** Run the Step 2 command and filters `VariantContractTests`, `VariantConfigurationTests`, `ExactRepContractTests`; require zero failures. Compare old initialized/planned canonical objects to existing goldens.
- [ ] **Step 5: Commit** planner/configuration/contract/tests: `feat: prescribe starter movement doses and setup modes`.

### Task 3: Context-specific progression and introductory set growth

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Progression/StarterProgramAdvancer.swift`, `StarterComparisonContext.swift`, `StarterIntroductoryDose.swift`.
- Modify: `Progression/ProgramAdvancer.swift`, `Configuration/ProgramReconfigurer.swift`, `Configuration/MovementVariantManager.swift` under that source root, only new-policy dispatch/reset seams.
- Test: `Packages/TrainingCore/Tests/TrainingCoreTests/StarterProgressionTests.swift` and `StarterTestSupport.swift`.

**Interfaces:**
- Consumes: Tasks 1–2; unchanged `ExactRepPlanner.plan(_:)`, `resizeExactExerciseState(_:to:)`, `AdvanceInput`, `AdvanceResult`, `ExactRepContext`, classification/decimal primitives.
- Produces: `advanceStarterProgram(_ input: AdvanceInput) -> AdvanceResult`, `starterContextKey(state: ProgramState, prescription: WorkoutPrescription, variantID: String, rules: Ruleset) throws -> String`, `applyStarterIntroductoryDose(exercise: inout ExerciseState, dose: MovementDose, observation: Exposure, windowKey: String) throws -> Bool` (true only for one-time promotion).
- Test support produces `starterState(choice: StarterProgramChoice, goal: Goal, slotID: String) throws -> ProgramState` and `starterCompletion(state: ProgramState, actualsByBase: [String: [Int]], effortByBase: [String: Effort], problemsByBase: [String: Problem], sessionMode: SessionMode) throws -> CompletedWorkout`; fixtures explicitly populate indexed actuals, all-set scope and miss reasons, independent of expected-result computation. `starterPromotionInput() throws -> AdvanceInput` authors a SUN size RDL at50 lb, two normal targets[12,12], one prior comparable normal ceiling/intro credit and a second complete on-target[12,12] event; next slot is recorded, and no expected result comes from production code.

- [ ] **Step 1: Write failing progression tests.** `sharedTargetsAdvanceAcrossDifferentPositions` pins RDL [10,10,9]→[10,10,10] between SUN/THU while separate windows survive. `samePositionDifferentPrecedingWorkNeverCombinesConfirmations` distinguishes SUN/TUE row even at equal ordinal. `alternatingSlotsRetainTheirOwnCeilingAndStrainEvidence` returns to a prior slot and applies its second confirmation/strain; at most three windows survive. `introPromotesOnlyAfterTwoMatchingNormalExposures` requires eligible movements/size-strength, baseline excluded, same context/load/dose, two consecutive qualified normal results; easier/skips freeze, partial/unknown/hard reset, and other contexts do not join. `introWinsOverLoadIncrease` pins a permitted 50→55 lb ceiling candidate: actual[12,12] instead produces next[12,12,11], normalSets3, retained50 lb, baseline and cleared windows. A separate mid-range case pins [10,9]→[10,9,8] and saved two-set actuals; never repeat growth. `loadSetupGoalAndReturnClearAllWindows` pins reset behavior and handling review. Pin maintenance holds, 20→25 refusal, +2 ceiling caps, RDL strength upper bound, pause, no-lower-load review and unequal-side rejection to the existing policy principles.

```swift
@Test func introWinsOverLoadIncrease() throws {
    let input = try starterPromotionInput()
    guard case let .applied(state, _, _) = advanceProgram(input) else {
        Issue.record("Expected a valid introductory promotion"); return
    }
    let id = try #require(state.config.activeVariantIDs?["db_romanian_deadlift"])
    #expect(state.exercises[id]?.load?.amount == "50")
    #expect(state.exercises[id]?.normalSets == 3)
    #expect(state.exercises[id]?.exactRepState?.normalTargets == [12,12,11])
    #expect(state.exercises[id]?.mode == .baseline)
}
```

- [ ] **Step 2: Run RED.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter StarterProgressionTests`; expect missing schema-4 advancement and named behavioral failures.
- [ ] **Step 3: Implement new-policy advancement.** Context keys must use the frozen input state and issued/displayed prescription, never the partially updated per-movement loop state; record preceding normal set doses. Replace an obsolete window for the same slot, retain others, and use only matching-context counters for qualifications. Reuse numerical planning, preserve safety/return/partial/strain precedence, but obtain range/cap/rest from the resolver. Shared load changes rebaseline and clear all contexts; a new eligible intro observation takes precedence over load/rep bonus changes, then uses the existing resize primitive. Preserve schema-3 full-context equality and single-window behavior. Use the new manifests' P01–P06 dose/intro/context/profile/handling/loading rules, with existing X rules retained for reused progression meanings; classify new exact thresholds as app adaptations.
- [ ] **Step 4: Run GREEN and old progression.** Run the Step 2 command and filters `ExactRepPlannerTests`, `ExactRepTransitionTests`, `ProgressionFixtureTests`, `VariantProgressionTests`; require zero failures and old complete goldens unchanged.
- [ ] **Step 5: Commit** progression/support/tests: `feat: add starter context evidence and introductory progression`.

### Task 4: Append-only program switching, archives and recovery

**Files:**
- Create: `Packages/TrainingCore/Sources/TrainingCore/Configuration/StarterProgramSwitcher.swift`, `StarterSafetyLedger.swift`.
- Modify: `Contracts/Journal.swift`, `Configuration/BranchResolver.swift` under the source root; `PlentyStrong/Persistence/TrainingRepository.swift`, `Backup/BackupService.swift`, `PlentyStrong/Cloud/RecoveryVerifier.swift`, `PlentyStrong/Cloud/CloudRecordCodec.swift`, `PlentyStrong/AppComposition.swift`, `Features/Workout/WorkoutViewModel.swift`, `PlentyStrong.xcodeproj/project.pbxproj` (new archive resources and repository test files).
- Test: `Packages/TrainingCore/Tests/TrainingCoreTests/StarterProgramSwitchTests.swift`, `PlentyStrongTests/StarterProgramRepositoryTests.swift`, `StarterProgramRecoveryTests.swift`.

**Interfaces:**
- Consumes: Tasks 1–3, existing pinned archive/journal validation, `StoreSnapshot`, repository operation gate, expected revision/head and recorded `WorkoutSlot`.
- Produces: `JournalCommand.changeStarterProgram(choice: StarterProgramChoice, goal: Goal, next: WorkoutSlot)`; `changeStarterProgram(state: ProgramState, sourceRules: Ruleset, destinationRules: Ruleset, choice: StarterProgramChoice, goal: Goal, verifiedHistory: [JournalEnvelope], nextWorkout: WorkoutSlot) throws -> ConfigurationResult`.
- Produces: `retainedStarterSafety(state: ProgramState, verifiedHistory: [JournalEnvelope], destinationRules: Ruleset) throws -> [String: MovementSafetyState]`; `TrainingRepository.changeStarterProgram(programID: UUID, expectedRevision: Int, expectedHeadHash: String, choice: StarterProgramChoice, goal: Goal, next: WorkoutSlot) throws -> StoreSnapshot`; `WorkoutViewModel.changeStarterProgram(choice: StarterProgramChoice, goal: Goal) async throws -> Void`. Test harness `StarterRepositoryTestHarness.make(choice: StarterProgramChoice, goal: Goal) async throws -> StarterRepositoryScenario` returns repository, programID, initial: StoreSnapshot and headHash; it initializes synthetic SUN2026-10-11 through the real writer, with no live-service injection.

- [ ] **Step 1: Write failing core/repository/recovery tests.** `switchPreservesVerifiedLoadHistoryAndRules` tests 2/3→4 and 4↔4 choices, same programID, matching RDL/squat loads, fresh angle-specific press/row, immutable original envelopes and no comparison transfer. `removedFamilySafetySurvivesRoundTrip` pauses an upper-only movement, switches away/back, and requires its original pause/reserve/source IDs; explicit safe-resume remains effective and cannot silently loosen reserve. `allDraftsAndFrozenFinishBlockSwitch` covers empty/started/problem/frozen drafts, byte-equivalent export after rejection. `switchCannotEnableSecondWorkoutSameDay` rejects next slots on/before an already completed local date. `switchIsAtomicStaleSafeAndReplayable` covers stale revision/head, injected save failure, retry/reopen and ordinary/graph export/import. `newPoliciesAreDiscoveredWithoutGuessing` tests schema3+registered4 recognition, future/profile/rules tampering retained unsupported, no blanket schema-number admission. `separateProgramWithDifferentDefaultProfileKeepsAccountSafetyGates` permits a healthy, unpaused default-dose source but rejects retained drafts, unknown policies, pauses or reserves above defaults, without copying data across accounts. `mixedProfileForksKeepAllOriginalsAndBlockTraining` retains originals and export while same-policy resolution unions retained family safety.

```swift
@Test func switchIsAtomicStaleSafeAndReplayable() async throws {
    let scenario = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
    let before = try await scenario.repository.exportBackup()
    await scenario.repository.failNextSave()
    await #expect(throws: (any Error).self) {
        try await scenario.repository.changeStarterProgram(programID: scenario.programID,
            expectedRevision: 0, expectedHeadHash: scenario.headHash,
            choice: .wholeBodyGlutes, goal: .size,
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
    }
    #expect(try await scenario.repository.exportBackup() == before)
}
```

- [ ] **Step 2: Run RED.** Core: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter StarterProgramSwitchTests`. App: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project PlentyStrong.xcodeproj -scheme PlentyStrong -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -parallel-testing-enabled NO -derivedDataPath DerivedData/StarterSwitch -only-testing:PlentyStrongTests/StarterProgramRepositoryTests -only-testing:PlentyStrongTests/StarterProgramRecoveryTests CODE_SIGNING_ALLOWED=NO`. Expect named missing new command/method/dispatch assertions; preserve the legacy harness.
- [ ] **Step 3: Implement the declared transition and transaction.** Validate complete ancestry with pinned archives, preserve compatible variant IDs/setup snapshots, reconstruct revisited matching variants only from unique verified history, and reset destination baselines/dose evidence. Use explicit registered safety-family aliases from the spec; retain absent families and honor typed clearance events when verifying ancestry. Require no draft and ready/current head; preserve processedEvents/lastSessionDate, and reject next slots on/before a recorded completed date. The model chooses the next valid slot on/after max(today, pending prescription date, lastSessionDate+1), using the supplied timezone and records it in the typed command; atomically archive destination rules/profile/source, append command, update head/state/outbox. Replay recognizes the transition before validating destination rules against the old schema, like existing policy activation. Profile-specific archive selection replaces the unconditional old-profile packaging only for new policies; register all new app/source archives and test Swift files in PBX here. For `requireSafeNewProgram`, retain the old path for legacy clients and compare schema4 destination safety by registered family rather than missing-ID→0; any old pause, stricter-than-default reserve, draft or unsupported lineage still blocks separate-account creation. Do not transfer records across accounts. Extend supported command/tuple/capability checks in backup, fake cloud, app training admission and journal processing; preserve unknown originals. Correct discovery's schema1/2-only recognition with strict registered-policy checks for 3/4. No new SwiftData tables, live cloud service or cross-policy conflict resolver.
- [ ] **Step 4: Run GREEN and boundary regressions.** Run Step 2 commands plus app suites `ExactPolicyRepositoryTests`, `BackupTests`, `CloudRecoveryTests`, `CloudConflictTests`; require zero failures, source byte-preservation assertions, real native completion, and no live-development smoke. Existing schema2→3 activation remains unchanged.
- [ ] **Step 5: Commit** transition/archive/recovery/tests: `feat: switch starter programs without losing history or safety`.

### Task 5: Emphasis cards, program preview and guided entry

**Files:**
- Create: `Features/ProgramChoice/ProgramChoiceView.swift`, `ProgramChoiceIcon.swift`, `ProgramPreviewView.swift`, `StarterProgramPresentation.swift`.
- Modify: `Features/Onboarding/OnboardingView.swift`, `Features/Settings/ProgramSettingsView.swift`, `Features/Workout/MovementSetupView.swift`, `WorkoutViewModel.swift`, `MovementPrescriptionSummary.swift`, `SetEntryView.swift` under `Features/Workout/`; `Features/History/WorkoutDetailView.swift`, `PlentyStrong/AppComposition.swift`, `PlentyStrong/PlentyStrongApp.swift`, `Resources/Localizable.xcstrings`, `PlentyStrong.xcodeproj/project.pbxproj`.
- Test: `PlentyStrongTests/StarterProgramPresentationTests.swift`, `PlentyStrongUITests/StarterProgramChoiceTests.swift`; existing `ExactRepWorkoutModelTests`, `MovementPrescriptionSummaryTests`, `MovementSetupTests`, `HistorySettingsTests`.

**Interfaces:**
- Consumes: Task 1 choice/definition/resolvers, Task 4 switch method and existing shared operation gate, immutable historical envelopes.
- Produces: `ProgramChoiceView(selection: Binding<StarterProgramChoice?>)`, `ProgramChoiceIcon(choice: StarterProgramChoice): View`, `ProgramPreviewView(choice: StarterProgramChoice, goal: Goal)`; `StarterProgramPresentation.details(choice: StarterProgramChoice, goal: Goal) throws -> StarterProgramDetails` derived from the frozen choice and consultation. Details contains title/description/duration strings, equipment:[String], cuesByMovementID:[String:[String]], coverageRows:[StarterCoverageRow] and limitations:[String]; coverage rows contain muscle, initialWork, establishedWork and days strings reproducing the Trainer table without falsely summing overlapping work. Upper coverage is derived from its original profile and honestly notes its once-weekly lower/trunk allocation.
- Produces: onboarding confirmation closure `(StarterProgramChoice, Goal) async -> Void`; `AppComposition.confirm(choice: StarterProgramChoice, goal: Goal) async`; thread explicit choice through separate-account new-program creation without bypassing existing cross-account/safety gates. Add `WorkoutViewModel.reviewStrengthHandling(variantID: String, choice: StrengthHandlingChoice) async throws -> Void` and `selectBridgeLoadingMode(variantID: String, mode: LoadingMode) async throws -> Void` adapter methods over typed commands/variants.

- [ ] **Step 1: Write failing presentation/UI tests.** `testSelectionRequiresEmphasisAndGoal` pins the two explicit selection gates. `eitherEmphasisCanPairWithEveryGoal` verifies choice and goal independent, no sex input, explicit selection, and no preselected emphasis. `restoreKeepsItsStoredProgramWithoutNewSelection` bypasses onboarding creation. `programPreviewMatchesDoseAndHonestCoverage` pins copy, 45–65 minute estimate, equipment difference and muscle counts/caveats. `switchCancelAndDraftLockPreserveProgram` tests no-op cancellation, disabled guarded change and preserved history after success. `bridgeAndStrengthChecksCreateOnlyTypedReviewedSetup` checks both bridge alternatives, further bodyweight modifications retaining that mode, bodyweight history labels after switching programs, and low-rep/standard handling flows. `perSideEntryAndStopsWorkAtLargestTextWithKeyboard` preserves left/right actuals and reachable entry/stop controls. `introCompletionAndHistoryRemainPinnedAfterProgramChange` shows two-set actuals versus three-set saved next, then another program's Settings without recomputation. Inspect both icons and selection states in light/dark, largest Dynamic Type and Reduce Motion; readable labels and VoiceOver semantics must carry choice without icons.

```swift
@MainActor func testSelectionRequiresEmphasisAndGoal() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-reset-local-store"] // synthetic UI test only
    app.launch()
    XCTAssertFalse(app.buttons["onboarding.confirm"].isEnabled)
    app.buttons["onboarding.program.whole_body_glutes"].tap()
    XCTAssertFalse(app.buttons["onboarding.confirm"].isEnabled)
    app.buttons["onboarding.goal.size"].tap()
    XCTAssertTrue(app.buttons["onboarding.confirm"].isEnabled)
    XCTAssertTrue(app.buttons["onboarding.program.upper_body"].exists)
}
```

- [ ] **Step 2: Run RED.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project PlentyStrong.xcodeproj -scheme PlentyStrong -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -parallel-testing-enabled NO -derivedDataPath DerivedData/StarterUI -only-testing:PlentyStrongTests/StarterProgramPresentationTests -only-testing:PlentyStrongUITests/StarterProgramChoiceTests CODE_SIGNING_ALLOWED=NO`. Expect missing choice/preview controls or their named assertions.
- [ ] **Step 3: Implement the declared flows and art.** Use the two exact titles/descriptions and choice help in the spec; no sex labels or gender-gated logic. Native Shape paths reproduce the provided adult male V-taper and slim/curvy adult female SVG concepts on a 96×128 normalized canvas; round strokes, foregroundStyle tint, decorative accessibilityHidden, program buttons with full labels/selected traits and at least44-point hit areas. Preview incorporates Trainer cues and direct/compound/indirect accounting, with no physique promise or upper-profile redistribution. Upper preview states “Pull-ups and chin-ups need a setup you can perform comfortably. A bar alone may not be sufficient.” Implement guided bridge and handling choices only while existing setup-edit guards permit; no reset fixtures on real devices. Display introductory status/set-growth copy; use policy capability checks for exact fields across3/4. Historical naming/doses/effective loading resolve from the recorded envelope's profile and variant, never today's active profile. Register source files/resources/English strings without unrelated project cleanup.
- [ ] **Step 4: Run GREEN and UI regressions.** Run Step 2 command and the listed model/presentation/setup/history regression suites; require zero failures and save unedited screenshots/accessibility hierarchies for both cards and the protected entry/completion/history cases. Check largest text/keyboard stop reachability and inspect actual rendered icon paths, not only path serialization.
- [ ] **Step 5: Commit** app flows/art/copy/tests: `feat: offer emphasis-based starter program selection`.

### Task 6: Independent examples and final candidate verification

**Files:**
- Create: `Packages/TrainingCore/Tests/TrainingCoreTests/Fixtures/starter-program-examples.json`, `StarterProgramFixtureTests.swift`.
- Modify: `docs/release/v1-checklist.md`, `docs/release/testflight-notes.md`, `PlentyStrong.xcodeproj/project.pbxproj` (app Debug/Release local build number7 only).
- Evidence: owned ignored `.superpowers/sdd/2026-10-08-starter-program-choice/`, preserved after review outside its execution worktree.

**Interfaces:**
- Consumes: Tasks 1–5's public selectors/initialization/advancement/switching plus existing native verification/archive tooling.
- Produces: independently authored complete expected states/prescriptions/decisions, source/command/visual/archive manifests and an honest release checklist; no new production API. Test-only `StarterProgramFixtureCompiler.input(_ id: String) throws -> AdvanceInput` and `expected(_ id: String) throws -> StarterExpectedAdvance`; expected DTO contains nextState: ProgramState, nextWorkout: WorkoutPrescription, decisions:[Decision].

- [ ] **Step 1: Write independently authored failing fixture tests.** `trainerEstablishedWeekMatchesSavedPrescriptions` pins all SUN/TUE/THU exercise/order/load/basis/target examples from consultation section8, with established dose explicitly represented as synthetic prehistory (never a user bypass of introductory rules). `rdlWorkedExampleSeparatesPreviousGoalActualAndNext` pins previous10/10/8→goal10/10/9→actual10/10/9→next10/10/10, first-miss repeat and too-easy12/12/11. Include full expected intro promotion, context-local ceiling/strain, bodyweight bridge, stronger retained safety, switch/replay and exact unavailable-future results. Author expected values without running the production engine to generate them; existing fixtures remain untouched.

```swift
@Test func rdlWorkedExampleSeparatesPreviousGoalActualAndNext() throws {
    let input = try StarterProgramFixtureCompiler.input("rdl-about-right")
    let expected = try StarterProgramFixtureCompiler.expected("rdl-about-right")
    guard case let .applied(state, workout, decisions) = advanceProgram(input) else {
        Issue.record("Expected the authored RDL transition"); return
    }
    #expect(state == expected.nextState)
    #expect(workout == expected.nextWorkout)
    #expect(decisions == expected.decisions)
    let id = try #require(state.config.activeVariantIDs?["db_romanian_deadlift"])
    #expect(state.exercises[id]?.exactRepState?.normalTargets == [10,10,10])
}
```

- [ ] **Step 2: Run RED.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/TrainingCore --filter StarterProgramFixtureTests`; require meaningful missing fixture/implementation differences, not invented changes solely to force a red run. If earlier tasks already satisfy an independently added acceptance case, record that first pass honestly.
- [ ] **Step 3: Implement only the fixture loader and any smallest confirmed in-scope correction; record local candidate build7.** Add explicit app Debug/Release build-number edits before freezing runtime/config. Include new archives in the app build while preserving package bundles and all old JSON byte identities. Fix a demonstrated defect at its owning boundary; do not broaden policy or rewrite expected results to match it.
- [ ] **Step 4: Run GREEN fixtures and full current verification once on frozen final inputs.** Run Step 2 and `make verify-current DERIVED_DATA=DerivedData/StarterFinal`; require native terminal0 for core, model/UI, six macOS disk-kill proofs and unsigned Release build. Preserve optional live-service skips and any warning/diagnostic limitations separately. Capture source and reused/changed dependencies exactly if a later localized correction requires component reruns; never relabel a failed literal Make command.
- [ ] **Step 5: Run the actual minimum matrix.** `make verify DERIVED_DATA=DerivedData/StarterMinimum`. Require actual iOS18 native passes to close that gate; if missing, record command failure/unavailable, refresh inventory and keep the gate open. Do not substitute current runtime or silently download one.
- [ ] **Step 6: Produce and inspect unsigned artifact.** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild archive -project PlentyStrong.xcodeproj -scheme PlentyStrong -configuration Release -destination 'generic/platform=iOS' -derivedDataPath DerivedData/StarterArchive -archivePath DerivedData/StarterArchive/PlentyStrong-0.1.0-7-Unsigned.xcarchive CODE_SIGNING_ALLOWED=NO`. Require ARCHIVE SUCCEEDED/exit0, actual0.1.0(7)/min18, packaged old/new resource hashes, binary/dSYM UUIDs, recorded source/build bindings and explicit unsigned status. Human Trainer/VoiceOver/comprehension, physical phone/Files, actual cloud/conflict resolution, signing/purchases/distribution remain independent gates.
- [ ] **Step 7: Update release evidence and commit** fixtures, scoped candidate configuration and evidence-only release notes: `test: verify selectable starter programs and candidate identity`. Preserve the prior signed phone6 artifact and report all actual passed/failed/unavailable checks. Do not push/merge/sign/install/publish.

## Self-review and handoff

The plan covers all ten consultation sections: choice/copy (Task5), full schedule/dose/coverage/goals (Tasks1–2/5), introductory transition and all progression details (Task3), program changes/versioning/history (Task4), complete worked examples (Task6), and explicit deferred upper-routine revision/future matrix (global scope). Each Review Focus item has a named owning test. Contract names and parameter names above are authoritative; new optional Codable fields must remain absent in legacy values. Profile data drives movement-specific behavior; no scattered new movement-name cases outside the typed catalog/resolvers/safety mapping.

Planning self-review is inline, not another subagent review. Before implementation Bob reviews the proposed engineering interpretations and icon concepts. Preserve the previously chosen subagent-driven execution method once this plan is approved; fresh per-task implementer/reviewer gates and one final whole-branch review. Later integration, phone replacement, live cloud and distribution require their own concrete authorized action.
