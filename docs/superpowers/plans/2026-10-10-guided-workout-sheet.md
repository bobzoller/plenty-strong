# Guided Workout Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved resumable workout sheet, movement summaries and audited unfinished-workout corrections without changing training progression.

**Architecture:** Keep effective actuals in existing exercise logs; store correction originals in a versioned optional audit carried into the immutable completion event. Optional draft flow and an exact pending-Finish payload make navigation/submission durable; a composition-scoped local sidecar preserves unsaved text. SwiftUI presents these contracts through the active real/demo composition.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation, XCTest/Swift Testing; existing pure TrainingCore package; iOS 18 minimum.

**Spec:** `docs/superpowers/specs/2026-10-10-guided-workout-sheet-design.md` (Bob approved: “LGTM, let's go!”). Its `8982a84` baseline is historical. This plan is based on verified remote main `75973b3dfe1f30f599a21af7789fb758b0ff2e97`; developer-demo-mode PR #2 is now merged. The unchanged design was rebased locally as `81cc5dbc644b689fbe9904aa4b888a903fad22e5`.

## Global Constraints

- “Use native Apple frameworks, no third-party runtime dependencies, and synthetic fixtures only.”
- “Goals, Last time, effort and reasons never prefill performed reps.”
- “Both rest screens use the same existing prescription duration.” “Zero never automatically advances.”
- “Safety stops cannot reopen or promote; review does not create a new working attempt.”
- “Ordinary `saveDraft` retains its immutable performed/skipped prefixes and acknowledged-outcome restrictions.”
- “No accepted journal is rewritten.” Preserve exact decimal loads and every existing policy/profile hash and progression golden output.
- No historical editing, per-set effort, new rest policy, live cloud/account work, personal records, signing, phone installation, purchases, push, merge or publication.
- Preserve detached CPU work, captured admission, repository transactions and the existing `TrainingOperationGate`. No full repository save on each keystroke.
- Work only on `bobzoller/` branches; register new app/test files in `PlentyStrong.xcodeproj/project.pbxproj`, including every app/crash target compiling their dependent types.
- Bob selected subagent-driven execution. Parent must obtain plan review before implementation; fresh implementer/reviewer per task, no worker child agents. Execute dependency order; these tasks share state.

## Review Focus

1. Goal 8 with left 8/right 6: disclose reason immediately, preserve both originals, exclude unequal work from completion; returning to goal clears selection, lowering again requires a fresh answer. Owner Task 5/7.
2. Ordinary-save bypass attempts: cannot forge/remove audit, change/clear pending Finish, reopen stopped work, or submit an event omitting audit/changing next slot. Owner Task 3/4.
3. Correcting a previously reviewed movement from Workout review: open its invalidated Summary transiently, keep forward progress and original timer, and prevent Finish until reconfirmed. Owner Task 5/7.
4. Real/demo switching during an outstanding scratch write: no text/cursor/data adoption across compositions or dataset/store identities. Owner Task 6/7.
5. Relaunch after last-set save or frozen Finish at midnight: restore Summary or exact frozen retry, no duplicate actual, timer restart or invented new session date. Owner Task 4/5/7.

---

## File map and verification conventions

TrainingCore adds `Contracts/ObservationAudit.swift` and `Validation/ObservationAuditValidator.swift`; `Contracts/Observation.swift` carries optional completion audit. App backup adds `Backup/WorkoutFlow.swift` and optional draft fields in `BackupDocument.swift`. Repository mutation remains in `TrainingRepository.swift`; model coordination remains in `WorkoutViewModel.swift`. New `Features/Workout/SetEntryDraft.swift`, `WorkoutScratchStore.swift`, `MovementSummaryView.swift` and `GuidedRestView.swift` have entry validation, local persistence, summary and rest responsibilities respectively. Reuse existing setup/cues/comparison/effort/reason views rather than duplicating policy.

Use actual Makefile commands below. `make test-app XCODEBUILD='xcodebuild -project PlentyStrong.xcodeproj -scheme PlentyStrong -only-testing:PlentyStrongTests/SuiteName'` runs a selected suite with the Makefile's current simulator, Debug configuration, signing disabled and development-cloud smoke disabled. UI selectors use `PlentyStrongUITests/SuiteName`. Substitute each named owning suite for SuiteName; this is a command convention, not a new runner. Run `make check-current` before app testing. Parent inventory currently has only iOS27.0; required minimum iOS18 remains unavailable, never a pass. Core tests use `make test-core` or the stated `xcrun swift test --package-path Packages/TrainingCore --filter ...` after `make check-toolchain`. No commands below were executed during planning.

New fixtures live in `PlentyStrongTests/Support/GuidedWorkoutFixture.swift`: `@MainActor struct GuidedWorkoutFixture { let model: WorkoutViewModel; let repository: TrainingRepository; let storeURL: URL }`, with `static func make(schemaVersion: Int = 4, goal: Goal = .size) async throws -> GuidedWorkoutFixture`. Task 2 owns this helper: temporary directory, synthetic UUIDs, fixed `2026-10-10T20:00:00Z`, `Pacific/Honolulu`, schema-3 fixed exact or schema-4 upper-body starter registration, then existing `WorkoutViewModel.start(easierToday: false)`. Tests close repositories and never reuse personal stores.

The short snippets below are representative assertions inside each named test, after that test's described synthetic setup; local event/draft/key values are test data, not additional production interfaces.

### Task 1: Admit and preserve correction audit contracts

**Files:** Create `Packages/TrainingCore/Sources/TrainingCore/Contracts/ObservationAudit.swift`, `.../Validation/ObservationAuditValidator.swift`, `Packages/TrainingCore/Tests/TrainingCoreTests/ObservationAuditTests.swift`. Modify `.../Contracts/Observation.swift`, `Backup/BackupService.swift`; test `PlentyStrongTests/BackupTests.swift`.

**Interfaces:** Produce public Codable/Equatable/Sendable `ObservationAudit(version: Int = 1, corrections: [SetCorrection])`; `SetCorrection(operationID: UUID, movementID: String, setIndex: Int, before: ActualSet, after: ActualSet, beforeStatus: LogStatus, afterStatus: LogStatus, outcomeAcknowledged: Bool)`. Add `CompletedWorkout.observationAudit: ObservationAudit? = nil`, preserving existing initializer calls. Produce `ObservationAuditValidator.originalLogs(effective: [ExerciseLog], audit: ObservationAudit?, prescription: WorkoutPrescription, config: ProgramConfig, schemaVersion: Int) throws -> [ExerciseLog]`. Consumes issued policy/contracts, never app-layer WorkoutDraft or future goals.

- [ ] **Step 1: Add failing contract/replay tests.** `ObservationAuditTests.originalsReplayAndLegacyBytes` asserts correction 7→8 at index 0 reconstructs 7, leaves goal 8/load unchanged, and nil audit retains original encoded bytes. `legacyArrayBindingRetainsNilIndexAndNoTarget` preserves schema2 nil setIndex/target/reason and original effort scope. `rejectsForgedChainsAndOutcomePromotion` asserts duplicate UUID, changed index, disconnected before/after chain, final mismatch, negative originals, unknown version, and acknowledged stopped→completed throw. Add backup test asserting a nonnil trail affects event/envelope hashes and nil does not introduce a key.

```swift
#expect(originals[0].actualSets[0].reps == 7)
#expect(effective[0].actualSets[0].reps == 8)
let value = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(legacyEvent))
#expect(try CanonicalJSON.encode(value) == originalLegacyBytes) // Frozen canonical legacy fixture.
```
- [ ] **Step 2: Run red.** `xcrun swift test --package-path Packages/TrainingCore --filter ObservationAuditTests`; expected missing types/validator failures.
- [ ] **Step 3: Implement the interfaces.** Use nil omission; explicit version admission. Reverse corrections then replay forward; validate original structural values/outcome restrictions. Schema3/4 bind explicit setIndex; legacy logs use stable array position while preserving nil setIndex and their original admission/effort semantics. Unsupported archives stay read-only in the app. Audit cannot change load/setup/skips/safety. `BackupService.transition(state:command:rules:legacyHistory:archivedRules:archivedProfiles:)` passes pinned prescription/config/schema to audit validation before existing workout transition. Do not alter progression or expose audit as comparison evidence.
- [ ] **Step 4: Run green.** Run the core filter and selected `BackupTests`; assert untouched existing exact/legacy golden outputs with `make test-core`. Expected all executed cases pass.
- [ ] **Step 5: Commit.** Stage only these contracts/validation/tests; commit `feat: preserve audited workout set corrections`.

### Task 2: Define admitted durable flow and pending-Finish data

**Files:** Create `Backup/WorkoutFlow.swift`, fixture above, `PlentyStrongTests/WorkoutFlowContractTests.swift`; modify `Backup/BackupDocument.swift`, `Backup/BackupService.swift`, project registration.

**Interfaces:** Produce Codable/Equatable/Sendable `WorkoutStep`: `.introduction(movementID:)`, `.set(movementID:index:)`, `.rest(sourceMovementID:sourceSetIndex:destination:)`, `.summary(movementID:)`, `.workoutReview`; `WorkoutRestDestination`: `.set(movementID:index:)`, `.introduction(movementID:)`. Produce `WorkoutFlow(version: Int = 1, forward: WorkoutStep, reviewedSummaryMovementIDs: [String])` and `PendingWorkoutFinish(version: Int = 1, event: CompletedWorkout, next: WorkoutSlot, expectedRevision: Int)`. Add optional `flow`, `observationAudit`, `pendingFinish` to `WorkoutDraft`. Produce `WorkoutFlowResolver.reconciled(_ draft: WorkoutDraft) throws -> WorkoutFlow` and `validate(_ draft: WorkoutDraft) throws`.

- [ ] **Step 1: Add failing tests.** `nilMetadataPreservesCanonicalDraft`, `legacyReconciliationNeverInfersCompletion`, `invalidCursorAndFutureVersionsReject`, `pendingFinishBindsAllInputs` assert nil-key omission; first unhandled/next unoccupied behavior; summary after last occupied index; all acknowledged→review; impossible set/rest/summary binding rejection; and exact event/audit/next/revision/timing binding. Ambiguous legacy deadline never establishes ownership.

```swift
let flow = try WorkoutFlowResolver.reconciled(lastOccupiedDraft)
#expect(flow.forward == .summary(movementID: movementID))
#expect(lastOccupiedDraft.logs[0].status == .partial)
```
- [ ] **Step 2: Run red.** Selected `WorkoutFlowContractTests`; expected missing contracts/resolver failures.
- [ ] **Step 3: Implement typed contracts/resolver and fixture.** Reviewed IDs are unique, outcome-acknowledged and issued; current forward may stay Workout review while a corrected summary is unreviewed. Keep forward readiness separate from Finish readiness. Pending Finish requires every explicit outcome plus all flow summaries reviewed, valid audit, original draft identity/date/zone/start/prescriptions/session mode, expected revision, and valid next schedule. Wire `BackupService.validateDraft(_:state:rules:)`; both format validators already call it. Register dependencies in app and crash harness sources.
- [ ] **Step 4: Run green.** Selected suite plus existing `WorkoutViewModelTests/testOldAndNewDraftMetadataBackupRoundTripsAndRejectsUnknownAcknowledgement` and `make crash-proof` after target registration. Expected unchanged old bytes and valid new round trips; report unavailable gates.
- [ ] **Step 5: Commit.** Commit `feat: admit durable guided workout state`.

### Task 3: Add the explicit atomic correction writer

**Files:** Modify `PlentyStrong/Persistence/TrainingRepository.swift`; create `PlentyStrongTests/WorkoutCorrectionRepositoryTests.swift`; extend `PlentyStrongTests/BackupTests.swift`, `PlentyStrongTests/Support/CrashHarness/main.swift`, `PlentyStrongTests/Support/run-crash-proof.py`.

**Interfaces:** Produce `@discardableResult nonisolated func correctDraftSet(programID: UUID, expectedDraftHash: String, operationID: UUID, movementID: String, setIndex: Int, replacement: ActualSet) async throws -> StoreSnapshot`. Extend existing `saveDraft(_:expectedExistingDraft:)` with defaulted `expectedDraftHash: String? = nil` for cursor CAS; existing repair parameter remains temporarily until Task 4. Consumes Task 1 audit validator and Task 2 draft/flow admission.

- [ ] **Step 1: Add failing tests.** `correctionRetainsOriginalAndIsIdempotent` asserts 7→8 audit before=7/after=8; duplicate UUID is identical after snapshot changes, conflicting reuse rejects, unchanged replacement is no-op. `ordinarySaveCannotRewriteAuditOrRawData` attempts forged audit/removal/replacement, load/skip/safety/outcome rewrites and expects rejection without writes. `staleCorrectionDemotesWithoutReopening` asserts exact-draft mismatch rejects, completed→zero becomes partial, acknowledgement remains, reviewed summary clears, rest deadline unchanged and subsequent working append rejects. Preserve acknowledged partial/stopped decisions and missing-side originals.

```swift
await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forgedAuditDraft) }
#expect(try await f.repository.snapshot(programID: f.model.programID).draft == before)
```
- [ ] **Step 2: Run red.** Selected `WorkoutCorrectionRepositoryTests`; expected missing writer/protection failures.
- [ ] **Step 3: Implement synchronous transactional correction body via existing `offMain`.** Check stable operation identity before stale-CAS rejection for successful retries; validate exact current hash, revision/health/prescription, globally absent completed event and nil pending Finish. Change only targeted set, append trail, invalidate summary review and demote as required. Ordinary save requires audit byte equality and preserves all current prefix guards; cursor-only save checks CAS. Reuse counting/reason rules, including any entered below-goal side, while retaining explicit stopped/partial raw exemptions.
- [ ] **Step 4: Run green.** Selected suite and both-format corrected draft reopen. Extend harness setup/commit/verify modes for correction: SIGKILL exact child at before_save leaves original draft; after_commit leaves effective correction plus full original trail, unchanged journal/head/outbox. Run `make crash-proof`; report added cases separately from preexisting6/6. Existing `ExactRepWorkoutModelTests` must still reject ordinary prefix rewriting.
- [ ] **Step 5: Commit.** Commit `feat: correct unfinished workout sets with retained originals`.

### Task 4: Persist exact Finish and admit explicit rejected repair

**Files:** Modify `TrainingRepository.swift`, `Features/Workout/WorkoutViewModel.swift`, `Backup/BackupService.swift`; create `PlentyStrongTests/PendingWorkoutFinishTests.swift`; extend `PlentyStrongTests/CloudRecoveryTests.swift`, crash harness/script from Task3.

**Interfaces:** Produce repository `freezeDraftFinish(programID: UUID, expectedDraftHash: String, submission: PendingWorkoutFinish) async throws -> StoreSnapshot` and `repairRejectedDraft(programID: UUID, expectedDraftHash: String) async throws -> StoreSnapshot`. Preserve existing `finalize(programID:expectedRevision:event:next:)` and model `finish() async throws -> FinalizationReceipt`, `recoverRejectedCompletion() async throws` signatures. Replace old repair bypass usage of `saveDraft(expectedExistingDraft:)`; that argument becomes CAS-only, never authority to clear a freeze or rewrite outcomes.

- [ ] **Step 1: Add failing tests.** `frozenSubmissionSurvivesRelaunchAtMidnight` asserts identical event/audit/timing/next/revision after retry, one accepted envelope. `ordinarySaveCannotForgeOrClearFreeze` rejects adding/replacing/removing lock. `finalizeRejectsChangedFrozenPayload` rejects omitted/different audit, changed next/date/event/expected revision. `repairRechecksAbsentEventAndExactDraft` retains originals/audit, demotes only proven invalid completed logs, clears lock atomically, rejects accepted-event/stale/missing proof and rollback failure.

```swift
#expect(reopened.draft?.pendingFinish == frozen)
#expect(reopened.draft?.pendingFinish?.event.observationAudit == frozen.event.observationAudit)
#expect(retried.history.filter { $0.eventID == frozen.event.eventID }.count == 1)
```
- [ ] **Step 2: Run red.** Selected `PendingWorkoutFinishTests`.
- [ ] **Step 3: Implement freeze and repair under repository transactions/offMain.** Freeze validates Task 2 bindings and stores exact payload before submission. Model initialization/reopen adopts saved pending submission; `editableDraft` and preparation/feedback reject pending Finish. Finalize requires pending event and next equality when present and always exact draft/event audit equality. Allow nil pending Finish for archived legacy callers. Repair derives allowed demotions from the retained frozen rejected event, proves pinned-core acceptance without journal writes and clears the lock only with existing unchanged-revision/absent-event proof. Double Finish retains existing shared task and operation gate.
- [ ] **Step 4: Run green.** Selected suite plus existing Finish/repair cases. Add freeze-specific process-kill modes: before_save has no pending payload; after_commit reopens identical event/audit/next/revision without a journal advance. Run `make crash-proof`, reporting correction/freeze proof counts honestly. Verify accepted corrected events through both-format `BackupService.validate` and `RecoveryVerifier().verify(BackupService.recoveryRecords(document))`; unknown audit versions quarantine.
- [ ] **Step 5: Commit.** Commit `feat: freeze guided workout submissions durably`.

### Task 5: Implement guided model transitions and entry semantics

**Files:** Create `Features/Workout/SetEntryDraft.swift`, `PlentyStrongTests/GuidedWorkoutModelTests.swift`; modify `WorkoutViewModel.swift`, `SetEntryView.swift`, `Backup/WorkoutFlow.swift`, `scripts/measure-workout-responsiveness.py`, project registration.

**Interfaces:** Produce Codable/Equatable/Sendable `SetEntryDraft(reps: String = "", left: String = "", right: String = "", reason: MissedGoalReason? = nil)`, `mutating func update(reps: String, left: String, right: String, target: Int?, repCounting: RepCounting)`, `observation(target: Int?, repCounting: RepCounting, exact: Bool) -> ActualSet?`, `requiresReason(target: Int?, repCounting: RepCounting) -> Bool`. Model produces `beginMovement(movementID: String) async throws`, `advanceRest() async throws`, `confirmMovementSummary(movementID: String, effort: Effort?, status: LogStatus, reviewing: Bool) async throws`, `correctSet(movementID: String, index: Int, replacement: ActualSet, operationID: UUID) async throws`, `resumeGuidedWorkout() async throws`. Add transient `reviewStep: WorkoutStep?` and read-only `visibleStep: WorkoutStep?`. Existing recordSet/skipSet/problem/status commands persist resulting flow in their one save, without nested gated calls.

- [ ] **Step 1: Add failing tests.** `perSideReasonAndStaleSelection`: goal8 left8/right6 requires explicit reason, returns original sides, remains non-completable; at8/8 reason becomes nil; at8/6 again requires fresh selection. `setRestSummaryAndBackAreExactlyOnce`: save one indexed set+deadline+cursor, duplicate save does not append, skip has no new timer, last occupied→summary, effort does not restart timer. `correctionFromReviewOpensSummaryWithoutRewind`: forward stays review, visible becomes invalidated summary, Finish blocked until reconfirmed. `resumeDoesNotStartOrMutateFrozenPausedDraft`: retains exact pending payload/date/safety/flow and performs no start admission. `newWritesKeepMainActorHeartbeatAlive`: synthetic delayed transition/correction/freeze commits keep busy feedback and MainActor heartbeat live; reuse existing responsiveness patterns, no new SLA. Add early stop, all skip, shared restriction/date-choice and failed-save tests.

```swift
var entry = SetEntryDraft(left: "8", right: "6", reason: .effortLimit)
entry.update(reps: "", left: "8", right: "8", target: 8, repCounting: .perSide)
#expect(entry.reason == nil)
entry.update(reps: "", left: "8", right: "6", target: 8, repCounting: .perSide)
#expect(entry.requiresReason(target: 8, repCounting: .perSide) && entry.reason == nil)
```
- [ ] **Step 2: Run red.** Selected `GuidedWorkoutModelTests`.
- [ ] **Step 3: Implement typed entry projection and commands.** Parse nonnegative integers without summing sides; clear stale reason. Require any observed below-goal side consistently; preserve raw stop exemptions. New Start prepares; Resume presents existing draft without start/setup exposure admission and reconciles only permitted nil metadata, preserving frozen payload/date-choice. Summary requires explicit effort only for exact allWorkingSets logs; supported legacy retains legacy scope/copy. Status respects permanent stops. Review stays transient and never advances/restarts rest. Compute heavy policy/audit/CAS off-main under existing gate; register dependencies in responsiveness source list.
- [ ] **Step 4: Run green.** Selected suite plus `ExactRepWorkoutModelTests` and `WorkoutViewModelTests`; run `python3 scripts/measure-workout-responsiveness.py --output /tmp/plenty-guided-responsiveness-<unique>` once, using a fresh output path. Require heavy admitted/replay/repository work to remain off-main in emitted diagnostics; latency findings are evidence, not fabricated universal thresholds.
- [ ] **Step 5: Commit.** Commit `feat: coordinate guided workout steps and movement summaries`.

### Task 6: Preserve scratch within the active composition

**Files:** Create `Features/Workout/WorkoutScratchStore.swift`, `PlentyStrongTests/WorkoutScratchStoreTests.swift`; modify `WorkoutViewModel.swift`, `PlentyStrong/AppComposition.swift`, `PlentyStrong/DeveloperDemoMode.swift`, `PlentyStrongTests/DeveloperDemoModeTests.swift`, project/harness registrations.

**Interfaces:** Produce `WorkoutScratchKey(storeID: String, datasetID: String, programID: String, draftID: UUID, prescriptionID: String, step: WorkoutStep, expectedObservationHash: String?)`, `WorkoutScratch(version: Int = 1, generation: UInt64, key: WorkoutScratchKey, entry: SetEntryDraft)`. Actor `WorkoutScratchStore(directory: URL)` exposes `load(key: WorkoutScratchKey) async throws -> WorkoutScratch?`, `save(_ scratch: WorkoutScratch) async throws`, `invalidate(draftID: UUID, throughGeneration: UInt64) async throws`, `remove(draftID: UUID) async throws`. Model exposes `entryDraft: SetEntryDraft`, `flushScratch() async throws`; defaulted scratch injection preserves existing initializers.

- [ ] **Step 1: Add failing tests.** `scratchRelaunchDoesNotBecomeActual` restores strings but log stays empty; invalid/corrupt/version-mismatched file rejected without draft mutation. `staleAndOutOfOrderWritesCannotCrossContext` holds real write, switches demo, then releases it; only original store/key changes, later entry generation wins, stale expected observation never overwrites actual. `pendingFinishAndDiscardCleanScratch` deletes only owned draft sidecar. Extend demo tests to prove cursor/sidecar isolation and restore original real entry.

```swift
try await store.save(WorkoutScratch(generation: 2, key: key, entry: SetEntryDraft(reps: "8")))
try await store.save(WorkoutScratch(generation: 1, key: key, entry: SetEntryDraft(reps: "7")))
#expect(try await store.load(key: key)?.entry.reps == "8")
```
- [ ] **Step 2: Run red.** Selected `WorkoutScratchStoreTests` and `DeveloperDemoModeTests`.
- [ ] **Step 3: Implement serialized atomic local writes.** Persist monotonically increasing generation per draft, continue from loaded generation and reject delayed older writes; navigation invalidates through its generation and completed removal tombstones that draft. Directory is beside each own store; real/synthetic load and demo sandbox setup configure it before publishing active. Identity uses standardized store path and unique verified initialization dataset, never descriptive backup.datasetID. Add defaulted `scratchDirectory: URL?`/`scratchStoreID: String?` to composition init. Late callbacks cannot adopt into replaced models. Flush before dismissal/navigation/suspension; Finish/discard cleans only matching scratch. Surface write failure while retaining text; force quit may lose unfinished writes.
- [ ] **Step 4: Run green.** Selected suites and reopen tests; verify scratch never appears in exported draft/event/cloud payload and repository commit count does not rise per keystroke. Update responsiveness source registration for new compiled model dependencies.
- [ ] **Step 5: Commit.** Commit `feat: retain workout input per active local composition`.

### Task 7: Present the sheet and accessible task screens

**Files:** Modify `PlentyStrong/PlentyStrongApp.swift`, `Features/Today/TodayView.swift`, `Features/Workout/{WorkoutView,SetEntryView,EffortPicker,MissedGoalReasonPicker}.swift`; create `Features/Workout/{MovementSummaryView,GuidedRestView}.swift`, `PlentyStrongUITests/GuidedWorkoutFlowTests.swift`; adapt `PlentyStrongUITests/{ExactRepFlowTests,WorkoutFlowTests,StarterProgramChoiceTests,HistorySettingsTests,OfflineAcceptanceTests,DeveloperDemoModeTests,MovementSetupTests}.swift` and existing shared XCUIApplication helpers; project registration.

**Interfaces:** Retain `WorkoutView(model:close:)`. Produce `MovementSummaryView(model:row:reviewing:)`, `GuidedRestView(model:step:)`; consume Task 5 visibleStep/commands and Task 6 entryDraft/flush. Reuse `MovementSetupView`, `PrescriptionComparisonView`, cues and `RestTimer(deadline:).remaining(at:)`. Preserve existing accessibility IDs for actuals/goals/safety; add `workout.resume`, `guided.next`, `guided.back`, `movement.summary`, `summary.confirm`, `correction.save`.

- [ ] **Step 1: Add failing UI tests.** `testSheetResumeAcrossTabsAndRelaunch`, `testImmediatePerSideMissReasonClearsAndRequiresFreshAnswer`, `testSummaryCorrectionFromReviewReturnsWithoutReplay`, `testExpiredRestNeverAutoAdvances`, `testKeyboardLargeTextAndReduceMotionKeepActionsReachable`, `testDemoSwitchRestoresOnlyItsOwnDraft`. Assert blank actuals, immutable displayed goal, explicit reason gating, summary all intended slots/sides/skips, aggregate question only at summary, early safe stops, duplicate tap/save feedback, focus dismissal and flush. Use existing synthetic exact/starter fixtures/launch flags and UI helpers; no new production fixture route.

```swift
app.enterPerformedReps("8", field: "set.left-reps")
app.enterPerformedReps("6", field: "set.right-reps")
XCTAssertTrue(app.buttons["reason.effort_limit"].exists)
XCTAssertFalse(app.buttons["set.save"].isEnabled)
```
- [ ] **Step 2: Run red.** Selected `GuidedWorkoutFlowTests`; expected absent sheet/screens/IDs.
- [ ] **Step 3: Implement large native sheet/NavigationStack at active tab container.** Both Today Resume and global Resume use Task5 resume, never start. Preserve today.start/tab.today/tab.history/tab.settings/workout.close and applicable set.save/workout.finish IDs. Forward/transient review navigation cannot replay saves. Introduction retains admission/setup/easier locks; set/correction reason validation and raw partial paths remain. Pin safety/action/error/busy UI; zero is display-only; Reduce Motion removes slide/pulse. Flush on explicit/interactive dismissal; preserve date-choice/store/repair/receipt states. Adapt all listed helper/navigation assumptions while keeping their safety/actual/restore assertions.
- [ ] **Step 4: Run green.** Selected new suite plus all seven adapted UI suites. Capture synthetic keyboard/accessibility-size/summary/correction screenshots. Automated reachability and manual simulator VoiceOver/native-back checks are separate evidence; report unrun checks.
- [ ] **Step 5: Commit.** Commit `feat: guide workouts in a resumable native sheet`.

### Task 8: Expose correction provenance and close integration gates

**Files:** Modify `Features/History/WorkoutDetailView.swift`, `PlentyStrongTests/MovementPrescriptionSummaryTests.swift`, `PlentyStrongTests/CloudRecoveryTests.swift`, `PlentyStrongTests/BackupTests.swift`, `PlentyStrongUITests/HistorySettingsTests.swift`, relevant `docs/release` validation notes. Add `PlentyStrongTests/WorkoutCorrectionHistoryTests.swift`; project registration.

**Interfaces:** Produce `WorkoutDetailView.corrections(event: CompletedWorkout, movementID: String, setIndex: Int) -> [SetCorrection]`; use Task 1 trail, existing issued-workout reconstruction and effective log display. No target calculation or original/effective pooling.

- [ ] **Step 1: Add failing tests.** `historyShowsOriginalAndEffectiveWithoutRewritingGoals` asserts issued8, original7, effective8 and accessible correction detail; missing side stays unrecorded. `correctedEventRoundTripsAndRecovers` checks formats1/2, active/inactive variants, retained original hashes/bytes, fake cloud shuffled recovery and tampered-audit denial. Compare audited versus otherwise identical truthful unaudited workouts only for exercise progression fields, issued next prescription and decisions. Explicitly assert distinct event/envelope hashes and retained audit provenance; `ProgramState.processedEvents` may legitimately differ, so do not compare whole states or strip provenance. Nil-audit historical fixtures retain exact whole-byte/hash comparisons. `oldDecoderCannotStripAuditAndAccept` drops unknown fields through a synthetic old envelope representation and proves canonical/hash admission rejects. UI verifies History has provenance after accepted Finish.

```swift
let edits = WorkoutDetailView.corrections(event: event, movementID: movementID, setIndex: 0)
#expect(edits.map(\.before.reps) == [7] && edits.map(\.after.reps) == [8])
#expect(event.exercises[0].actualSets[0].reps == 8)
```
- [ ] **Step 2: Run red.** Selected `WorkoutCorrectionHistoryTests`, added backup/recovery/history UI cases.
- [ ] **Step 3: Implement provenance projection/disclosure.** Current effective actual remains the primary history value; show ordered original/replacement/reason details only for corrected indices. Use existing variant filtering and issued goal reconstruction. Fix integration admission gaps in their owning layer; no manifest/progression golden rewrites. Release notes record correction-format downgrade limits, scratch scope and separate unavailable gates.
- [ ] **Step 4: Run green and whole-branch evidence.** Run selected suites, then `make verify-current` and `make verify` for required current/minimum matrix. Report missing minimum iOS18 or other gate explicitly. After final changes, run `git diff --check`; retain synthetic responsiveness evidence from Task5 unless subsequent CPU changes justify rerun. No signing/install/live service tests. Whole-branch review follows passing available evidence and reports unavailable gates honestly.
- [ ] **Step 5: Commit.** Commit `feat: show retained workout correction provenance`.

## Self-review and handoff

Coverage: experience/entry/summary/rest/safety→Tasks5/7; durable cursor/legacy reconciliation→2/5; audit/CAS/protected ordinary writes→1/3; exact Finish/rejected repair→2/4; scratch/dataset/demo identity→6/7; canonical old bytes/both backup formats/fake recovery/History→1/4/8; accessibility/performance→5/7. All five Review Focus classes have owning named tests. Interfaces and consumers above use the same names; each task has red/implement/green/commit and registers its own files. No unresolved product decisions: reason timing and group effort are settled; notes are excluded. Actual installed-runtime availability and automated-versus-human accessibility evidence are verification limits, not deferred design choices.

This is a plan for review, not code authorization by the worker. Parent presents it to Bob, preserves subagent-driven execution, and waits for plan confirmation. No implementation, tests/builds, device actions, push or PR occurred while authoring it.
