# Responsive workout actions — local verification

Confirm program, Start workout, and Confirm prescribed load now keep repository replay and action admission off the main thread. The existing model executor remains the sole serial writer; mutations and saves have no suspension point. The shared UI operation lease stays held until durable completion and snapshot adoption. Each action displays progress while its controls remain guarded.

A snapshot uses the admitted replay from the same immutable backup capture. Graph manifest and health reuse the exact captured verified recovery batch. Rule archives are admitted once per capture, then their exact policies still replay every event and validate drafts. Draft save returns its admitted value projection only after the transaction/save succeeds, avoiding immediate whole-history readback. All-root projection retains exact opaque archived IDs as well as app-created UUID roots; a regression verifies that an opaque root contributes stricter shared safety while its original journal bytes remain unchanged. No cache survives an operation. Import/restore/cloud admission retains full causal, hash, canonical, replay, projection, and outbox checks. TrainingCore, archived bytes, schema/wire format, progression, and safety policy are unchanged.

## Reproducible synthetic responsiveness proof

Run from the isolated checkout with installed Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/measure-workout-responsiveness.py --output /tmp/plenty-responsiveness-fresh
```

The script builds current Debug native Mac sources/TrainingCore, copies and instruments them externally, preserves source/object SHA256 bindings and command logs/exits, and runs a real `RunLoop.main` with a 10ms heartbeat. Start/load invoke the actual MainActor WorkoutViewModel. Fresh-program setup mirrors AppComposition's pure fresh-store checks; the simulator regression separately invokes actual AppComposition.confirm. Both a main-created repository and the app's background factory are exercised. Every store and observation is synthetic; this never opens the application's store.

Baseline source: `49de4c22d082b41fa370ce5084afc688fe752390`; original immutable diagnosis evidence is retained externally in `.superpowers/performance/2026-10-09`. Final measured source hashes and logs are in `.superpowers/responsive-workout-actions/ReviewPerformance` (external to the checkout). The tiny fixture has zero completed workouts and two journal entries after Start; these are Debug Mac measurements, not iPhone timings or history-scaling claims.

| Action | Baseline wall / CPU | New wall / CPU, UI factory | Full validations, before → after | Canonical bytes calls, before → after | Main heartbeat gap, before → after |
| --- | --- | --- | --- | --- | --- |
| Confirm program | 0.798 / 0.793s | 0.558 / 0.557s | 4 → 3 | 39 → 28 | 753 → 13.9ms |
| First Start | 5.860 / 5.855s | 2.339 / 2.318s | 15 → 5 | 389 → 148 | 1548 → 14.5ms |
| Confirm prescribed load | 1.645 / 1.643s | 0.401 / 0.401s | 4 → 1 | 119 → 34 | 880 → 14.8ms |
| Start with existing draft | 1.343 / 1.341s | 0.497 / 0.498s | 3 → 1 | 86 → 29 | 764 → 14.9ms |

All ten measured actions completed; all instrumented heavy entries were physically off main, and every main heartbeat gap was below 100ms. The main-created variant also passed. Rule-admission counts for the UI-factory first Start/load/existing Start were 9/1/1, versus baseline 53/17/12. The first Start still performs about 2.3 seconds of CPU work; its UI can render progress during that time. Synchronous read-only SwiftUI movement/previous-goal rendering helpers still resolve policies on MainActor. This proof measures the target action model and heartbeat, not full SwiftUI rendering or long-history scaling; unrelated Settings/Finish/import actions are not a general responsiveness claim.

## Gates and limits

Installed toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4. Current simulator runtime: iOS 27.0 (24A434). Commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `CODE_SIGNING_ALLOWED=NO`.

- TrainingCore: `make test-core` passed 241 Swift Testing tests in 27 suites, with zero XCTest cases (the package uses Swift Testing).
- Latest native durability: `make crash-proof DERIVED_DATA=<FinalAdmissionPerformance/DerivedData>` passed all six process-kill/fresh-reopen proofs, covering before-save/after-commit boundaries for finalization, conflict resolution, and policy activation, with full archived replay.
- Latest unsigned iOS Release: `xcodebuild build -project PlentyStrong.xcodeproj -scheme PlentyStrong -configuration Release -destination 'generic/platform=iOS' ... CODE_SIGNING_ALLOWED=NO` passed.
- Latest performance script: passed ten actions, physical-thread and heartbeat assertions, and bounded full-replay counts. Source hashes were checked again after execution.
- Visible busy-state UI (iPhone 17/iOS 27): all three selected UI cases passed, including new program/Start progress and guarded controls, prescribed-load progress, and prior/goals/blank actuals through History. The actual AppComposition/WorkoutViewModel MainActor slow-save test also passed.
- Selected simulator persistence/recovery: 43 XCTest cases plus 115 Swift Testing tests in 12 suites passed with zero failures (`test-persistence-final.log`). This includes repository, backup, cloud conflict/recovery/lifecycle, exact-policy admission, migration, starter switching, flexible scheduling/timing and selected callable workout/settings safety checks. Its binary preceded only the final legacy activation off-main wrapper, exact opaque-ID projection and busy Start label. Those deltas receive final-source focused coverage below.
- Final-source simulator deltas and UI: two XCTest physical-thread/responsiveness cases passed; the migration test (two variants) and 16 existing repository tests passed; all three UI cases passed. That mixed run exited 65 because the new opaque-root fixture changed a program ID without regenerating its registered variant IDs. Admission correctly rejected it. After correcting only the synthetic fixture, four focused Swift Testing tests in two suites passed (exit 0): opaque-root shared safety/original bytes, durable draft receipt/rollback, stale-head/CAS/save rollback and retained-draft activation blocking. `test-final-deltas-ui.log` retains the fixture failure and successful cases; `test-corrected-admission.log` records the passing corrected checks. No production source changed between these runs.

`make check-current` passed. `make check-minimum` failed because the required iOS 18/iPhone 16 runtime is absent. Full `make verify` and `make verify-current` were not rerun; selected checks do not establish a full minimum/current or current-only release gate.

Exploratory logs remain separate: an earlier broader app-test run was intentionally interrupted after source refinement; a first UI run passed actual MainActor slow-save admission and onboarding/Start busy feedback, but two UI tests tapped Start before startup admission released its gate. Their retained hierarchy showed Today with no draft/error. The tests now explicitly await enabled Start and the workout screen. A concurrent second Xcode test invocation could not start cleanly; its diagnostic/result log is retained and is not counted as verification. Two initially narrow Swift Testing selectors omitted their required `()` suffix and executed no cases; the corrected four-test run uses the full identifiers. Initial implementation compiler errors were corrected; their logs remain. Initial temporary instrumented-harness setup errors are described in `initial-harness-setup-notes.json`; those superseded raw compile logs are unavailable. All original baseline failure logs remain untouched.

Expected migration-failure fixtures emit CoreData store-load diagnostics and pass their rollback assertions. Non-blocking SDK diagnostics include skipped AppIntents metadata extraction (no framework dependency) and simulator PointerUI/launch-measurement messages. No physical-device access/installation, real-account/service, signing/provisioning, production-store reset, deployment, or publication verification was performed. Simulator launches reset only their explicitly synthetic fixture store. Synthetic UI fixtures use a DEBUG-only one-second save delay to verify visible progress and guarded controls; release behavior has no injected delay. No dependency, network, entitlement, privacy manifest, or archived-resource change is made.

## Selected simulator command

Build the same configuration/destination with `xcodebuild build-for-testing` before this command. The retained run used the external `FinalTests` derived-data directory.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test-without-building \
  -project PlentyStrong.xcodeproj -scheme PlentyStrong -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -parallel-testing-enabled NO -derivedDataPath <FinalTests> CODE_SIGNING_ALLOWED=NO \
  -only-testing:PlentyStrongTests/RepositoryTests \
  -only-testing:PlentyStrongTests/BackupTests \
  -only-testing:PlentyStrongTests/ExactPolicyRepositoryTests \
  -only-testing:PlentyStrongTests/FlexibleMigrationAdmissionTests \
  -only-testing:PlentyStrongTests/StarterProgramRepositoryTests \
  -only-testing:PlentyStrongTests/FlexibleTimingAdmissionTests \
  -only-testing:PlentyStrongTests/FlexibleSchedulingRepositoryTests \
  -only-testing:PlentyStrongTests/StarterProgramRecoveryTests \
  -only-testing:PlentyStrongTests/CloudRecoveryTests \
  -only-testing:PlentyStrongTests/CloudConflictTests \
  -only-testing:PlentyStrongTests/CloudRecoveryLifecycleTests \
  -only-testing:PlentyStrongTests/MigrationTests \
  -only-testing:PlentyStrongTests/WorkoutViewModelTests \
  -only-testing:PlentyStrongTests/ExactRepWorkoutModelTests/testConcurrentSaveFinishAndActivation \
  -only-testing:PlentyStrongTests/ExactRepWorkoutModelTests/testExplicitPartialPendingShortfallCannotPromoteOrRewrite \
  -only-testing:PlentyStrongTests/HistorySettingsModelTests/testBasePauseCannotBeBypassedAndSafeResumeNeedsExplicitClearance \
  -only-testing:PlentyStrongTests/HistorySettingsModelTests/testExistingRestoreRejectsConfigurationAndStartAcrossCallableTabEntries \
  -only-testing:PlentyStrongTests/HistorySettingsModelTests/testCommittedQuarantineRemainsLockedUntilAuthoritativeModelReload
```

Final-source deltas used the same project/scheme/configuration/destination above, with the `FinalLegacy` build-for-testing product and these selectors:

```sh
-only-testing:PlentyStrongTests/RepositoryTests
-only-testing:PlentyStrongTests/FlexibleMigrationAdmissionTests
-only-testing:PlentyStrongTests/WorkoutViewModelTests/testLegacyStartPolicyActivationCommitsOffMain
-only-testing:PlentyStrongTests/WorkoutViewModelTests/testStartAndConfirmLoadKeepMainActorResponsiveDuringDurableSave
-only-testing:PlentyStrongUITests/WorkoutFlowTests/testProgramAndStartShowBusyFeedbackWhileSaving
-only-testing:PlentyStrongUITests/WorkoutFlowTests/testConfirmPrescribedLoadShowsBusyFeedbackWhileSaving
-only-testing:PlentyStrongUITests/ExactRepFlowTests/testLastTodayActualAreIndependent
```

The corrected synthetic fixture was rebuilt into `FixtureCorrected`, then the same test command used these four exact Swift Testing selectors:

```sh
'-only-testing:PlentyStrongTests/RepositoryTests/opaqueArchivedRootContributesSafetyWithoutChangingItsBytes()'
'-only-testing:PlentyStrongTests/RepositoryTests/draftReceiptIsDurableAndFailedSaveRetainsPreviousProjection()'
'-only-testing:PlentyStrongTests/ExactPolicyRepositoryTests/activationAtomicityAndStaleHead()'
'-only-testing:PlentyStrongTests/ExactPolicyRepositoryTests/legacyDraftBlocksActivationUntilFinalized()'
```
