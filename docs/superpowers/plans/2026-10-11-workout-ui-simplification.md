# Workout UI simplification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce workout-screen density while making the current prescription, required input, and next action obvious.

**Architecture:** Keep the existing guided sheet, typed forward cursor, operation gate, and local persistence. Replace the repeated full comparison component with compact, screen-specific content. A shared secondary-action dialog routes to existing outcome commands; add one atomic model command for ending the remaining workout from the forward movement summary.

**Tech Stack:** SwiftUI, Swift Observation, SwiftData, TrainingCore; native Apple frameworks only.

**Spec:** Bob's October 11 feedback, captured in the product contract below, refines `docs/superpowers/specs/2026-10-10-guided-workout-sheet-design.md`. Where presentation differs, this contract takes precedence; existing persistence and training constraints remain binding.

**Status:** Proposed for review. Planning only; no implementation authorized yet. Inspected baseline: `bobzoller/guided-workout-sheet`, `6eb988206abb6484e8fa59eb415a9a5a5ededa0a`, the source of installed build 11. Before execution, resolve current remote main and the guided feature's current remote/local disposition; do not assume that main contains this feature or initialize a managed worktree from a cached feature branch.

## Global constraints

- Minimum iOS 18; native Apple frameworks and zero third-party runtime dependencies.
- Preserve exact decimal loads, units and per-hand/total basis; bodyweight retains null numeric load.
- Preserve immutable issued goals, independently entered actuals, per-side observations, correction audit and safety restrictions.
- Below-goal reasons remain immediate on the set screen and gate Next. Whole-movement effort remains on the movement summary.
- Rest retains its original deadline, never restarts during review and never auto-advances.
- Preserve explicit load confirmation, operation ownership, compare-and-swap, outcome saving despite UI-sidecar failure, and frozen Finish retry behavior.
- Use synthetic fixtures. No personal records, Trainer edits, cloud changes, publication, merge, push or phone installation in this scope.

## Product contract

| Screen | Visible content and actions |
|---|---|
| Movement introduction | Movement position/name, setup, compact set/rep prescription, weight selector for external loads, collapsed cues. Show one compact Last time line when available; omit empty first-workout/history placeholders. No Actual section. Primary Start movement; one secondary Skip below it, right aligned. |
| Set | Movement/set position, prominent goal reps with confirmed weight beside it, initially blank rep input, conditional missed-goal reason. No repeated First workout, Today's goal or Actual sections, accumulated actuals list, or Correct load link. Primary Next; one secondary Skip beneath it. |
| Rest within movement | Large countdown at top, upcoming set goal/weight, collapsed cues. Remove accumulated performed-set lists and explanatory boilerplate. Primary Next is available before zero; one secondary Skip beneath it. |
| Movement summary | Countdown at top when a saved deadline exists, movement name, compact Set / Goal / Done rows, actual weight, overall effort dropdown, truthful partial/safety status. Keep set correction and collapsed correction provenance. No repeated comparison sections. Primary Confirm summary; one secondary Stop workout link on the forward summary. |
| Rest between movements | Large countdown, next movement/setup/weight and collapsed cues. One secondary Skip beneath Next. Correct load is available only for an externally loaded source movement; bodyweight never shows it. |
| Workout summary before Finish | Compact movement cards show original goal reps/weight versus actual reps/weight and truthful outcomes. Remove routine Review movement links. Corrections and outstanding effort/reconfirmation happen inline, with no duplicate movement-summary visit. Primary Finish workout. |
| Saved workout summary | Show the same concise goal/actual reps and weights from the accepted event and verified original prescription. Retain next-workout information. No redundant Review link. |

“Dimmed” means secondary styling with a usable contrast and at least a 44-point tap target, not a disabled action. Hide routine Normal workout labels; retain a compact Easier workout indicator when applicable. Show pause/setup-review/retained-safety messages only when relevant; never hide an admission failure to reduce density.

### Explicit choices to review

1. **First workout:** hide Easier until this program has a finalized workout containing at least one performed set. An initialization event, discarded draft or all-skipped session does not count. A new movement variant within an experienced program does not reset this visibility. Keep the existing preparation lock and all engine rules.
2. **Weight confirmation:** a native menu-style Picker defaults to the prescription, with units and basis in its label. Selecting a value only changes local selection. An explicit Confirm weight button saves it; Start remains disabled until the required confirmed weight is durably saved. Changing an unperformed movement's selection requires confirmation again. Once sets exist, keep the confirmed weight read-only.
3. **Skip:** use a native confirmation dialog. Introduction offers Skip movement. Set/intra-movement rest offers Skip next set when it is unperformed, and End movement early. End movement early saves partial if any sets were performed, skipped otherwise. Pain / Loss of control remain explicit safety choices. Skip next set is unavailable when typed actuals would be discarded; ending early retains valid pending raw observations. Cancel makes no changes. Ordinary skips require no new reason field: the current policy has none.
4. **Between-movement Skip:** skip the upcoming movement, not the completed source. A safety report or external-load correction applies to the source and says its name in the dialog. Preserve existing correction/mixed-load semantics inside contextual secondary options rather than showing them on the set page.
5. **Stop workout:** confirmation says “Keep your results and skip the remaining movements?” Save the current summary and mark untouched remaining movements skipped, then open the workout summary; Finish still explicitly saves the event and advances rotation. Keep previously acknowledged outcomes, safety flags and partial observations. Do not fabricate effort or summary confirmation for other performed movements. Backward summary review does not expose this forward-only termination action. Its safety dialog can still record a problem for the reviewed movement.
6. **Inline review:** normal cards have no Review link. Existing recorded sets remain correctable from their rows until Finish. A correction updates effective actuals, exposes collapsed provenance, and creates a visible inline Confirm changes action; Finish stays blocked until every required review/effort answer is explicitly saved. Frozen Finish is read-only.
7. **Effort selection:** replace effort links with a native menu-style Picker, both on the movement summary and wherever pending effort is collected inline. Label it “How hard were the working sets?” for all-set scope, retaining “How hard was that?” for legacy scope. Start at “Choose effort…” with no answer selected; options remain Too easy, About right, Too hard, and I'm not sure. I'm not sure is an explicit saved answer, not the placeholder. Keep option meanings in a collapsed “What do these mean?” disclosure. Selection changes local input; the existing summary confirmation saves it. Restore an already saved answer when reviewing; never infer one from reps. No performed sets means no required effort dropdown.

## Review focus

- A picker default is not evidence of confirmed or performed weight: task 1 pins explicit confirmation and selection changes.
- Consolidated Skip must retain pending reps and separate skipped slots from performed partial work: task 2 exercises both, including per-side/pain.
- Between-movement actions must target the next movement or named source correctly: task 2 checks both bindings.
- Stop/retry must preserve prior outcomes and cannot partially skip a workout on a failed write: task 3 checks atomicity, relaunch and duplicate invocation.
- Inline corrections must retain originals and require explicit reconfirmation without altering a frozen Finish: task 4 checks demotion, provenance and freeze.

## File map

- `Features/Workout/WorkoutView.swift`: introduction, rest integration, final review and accepted summary.
- `Features/Workout/SetEntryView.swift`: focused goal/weight/input layout; preserve existing reason admission.
- `Features/Workout/GuidedRestView.swift`: countdown/next preview; footer layout without permanent safety-link rows.
- `Features/Workout/MovementSummaryView.swift`: timer-first comparison and summary/termination actions.
- `Features/Workout/EffortPicker.swift`: compact optional-selection dropdown and collapsed option meanings; preserve scope and explicit-answer semantics.
- Create `Features/Workout/WorkoutSecondaryActions.swift`: context-aware dialogs; no authoritative persistence of its own.
- Create `Features/Workout/WorkoutComparisonRows.swift`: compact goal/actual rows, reusable in movement and workout summaries; no training decisions.
- `Features/Workout/WorkoutViewModel.swift`: first-workout visibility projection, atomic stop, explicit inline-summary confirmation.
- `PlentyStrong.xcodeproj/project.pbxproj`: register new Swift sources in applicable targets; preserve crash-harness shared-source membership.
- Existing `PrescriptionComparisonView.swift` remains available to non-guided consumers; do not globally delete its history semantics.

## Execution and verification

Use an isolated `bobzoller/` worktree with the reviewed guided feature integrated before making changes. Record the actual starting SHA. Use the repository's installed toolchain and synthetic fixtures. For targeted Xcode checks below, use:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer PLENTY_RUN_DEVELOPMENT_CLOUD_SMOKE=NO xcodebuild test -project PlentyStrong.xcodeproj -scheme PlentyStrong -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -parallel-testing-enabled NO -derivedDataPath DerivedData/WorkoutCleanup CODE_SIGNING_ALLOWED=NO -only-testing:<test target/class>
```

Replace the final selector with the named owner(s) in each task. Pass means process exit 0 and every selected test passing; retain failures/unavailable gates honestly.

### Task 1: Simplify movement preparation and confirm weight

**Files:** Modify `WorkoutView.swift`, `WorkoutViewModel.swift`; tests `PlentyStrongTests/GuidedWorkoutModelTests.swift`, `PlentyStrongUITests/GuidedWorkoutFlowTests.swift`.

**Interfaces:** Add read-only `WorkoutViewModel.canOfferEasierWorkout: Bool`, combining preparation availability with this program's performed-workout history. Keep `confirmLoad(movementID: String, load: Load) async throws` authoritative. View-local selection uses `Load?`, never floating-point conversion.

- [ ] Add model cases proving Easier is hidden for first/all-skipped sessions and shown after performed history, subject to the observation lock. Add UI coverage: default selected weight does not enable Start; explicit confirmation does; changing selection requires confirmation; bodyweight has no selector.
- [ ] Run those new cases and confirm they fail on the old UI/model.
- [ ] Replace load-button carousel with the Picker plus Confirm weight state; remove Actual and empty history placeholders; retain compact set targets and optional Last time. Preserve load handling review, paused/setup-review admission and read-only resumed performed weight.
- [ ] Run the two named owners; confirm no duplicate generic comparison blocks. Commit `feat: simplify workout preparation and weight confirmation`.

### Task 2: Focus set/rest content and consolidate early actions

**Files:** Create `WorkoutSecondaryActions.swift`; modify `WorkoutView.swift`, `SetEntryView.swift`, `GuidedRestView.swift`, project source registration; update `PlentyStrongUITests/GuidedWorkoutFlowTests.swift`, `WorkoutFlowTests.swift`, shared helpers in `HistorySettingsTests.swift` and all affected UI call sites.

**Interfaces:** `WorkoutSecondaryActions(model: WorkoutViewModel, step: WorkoutStep, row: ExercisePrescription, pendingActual: Binding<ActualSet?>)` owns the single Skip entry point and context-specific dialog. It calls existing `skipSet`, `recordStatus`, `recordProblem`, `recordMixedLoads` and `stopForLoadCorrection`; it does not rewrite saved reps or load. Footer callers supply their secondary view explicitly rather than automatically getting two safety buttons.

- [ ] Add UI cases for dialog cancellation; empty skip versus pending partial; immediate below-goal reason gating; per-side raw pain stop; intra-rest skip-next-set; between-rest next-movement skip/source safety; bodyweight has no Correct load.
- [ ] Run new cases and verify the old presentation/bindings fail.
- [ ] Place weight beside set goal, remove repeated comparisons/actual lists and set Correct load. Make rest timer prominent with compact next preview. Move early and safety actions into the dialog; retain pending input on cancellation/error and clear only after accepted commands. On correction pages, keep Save correction and its existing safety behavior without allowing a new working attempt.
- [ ] Update synthetic UI helpers to choose weight then explicitly confirm and open dialogs before selecting existing safety/outcome actions. Preserve the assertions those tests protect; update obsolete layout assertions rather than dropping safety coverage.
- [ ] Run GuidedWorkoutFlowTests and WorkoutFlowTests plus every owner with changed helpers/call sites. Commit `feat: streamline workout set and rest actions`.

### Task 3: Compact movement summary and terminate remaining workout

**Files:** Create `WorkoutComparisonRows.swift`; modify `MovementSummaryView.swift`, `EffortPicker.swift`, `WorkoutViewModel.swift`, project registration; tests `PlentyStrongTests/GuidedWorkoutModelTests.swift`, `WorkoutFlowContractTests.swift`, `PlentyStrongUITests/GuidedWorkoutFlowTests.swift` and affected effort-selection UI helpers/call sites.

**Interfaces:** Add `stopWorkout(movementID: String, effort: Effort?, status: LogStatus) async throws`, admitted only for that forward summary before frozen Finish. Share summary-validation logic with `confirmMovementSummary` inside the existing operation gate, not by nesting public gated commands. Save one compare-and-swap draft containing the confirmed current outcome, remaining truthful outcomes and `.workoutReview` cursor. Reuse existing draft fields; no new schema or reason taxonomy.

- [ ] Add model cases proving stop preserves completed/stopped/demoted outcomes, audits, actuals and loads; marks only empty unhandled work skipped and other unfinished performed work partial; retains outstanding review/effort requirements; never invents skipped-set observations; rejects frozen/wrong-step/stale requests. Inject save failure and duplicate/relaunch to prove one atomic result and no rotation advance before Finish.
- [ ] Add UI coverage that “Choose effort…” leaves required confirmation disabled; every explicit option enables it, including I'm not sure; an accepted answer survives review/relaunch; empty skipped work requires no answer; option meanings remain available by disclosure. Update existing tests to open the menu before choosing effort, retaining their outcome assertions.
- [ ] Run these cases and verify failure before implementation.
- [ ] Move existing deadline to the top, use compact comparison rows, remove generic comparison and standing safety rows. Keep correction/provenance and replace effort links with the optional-selection dropdown defined above, preserving `EffortPicker`'s existing binding interface. Add secondary Stop workout with confirmation and explicitly named pain/control choices; require current performed movement effort before ordinary Stop. A safety outcome can still save immediately without invented effort and remain pending review.
- [ ] Implement atomic termination with existing repository admission and authoritative outcome saving. Do not synthesize review acknowledgement for other performed movements; the final inline review in task 4 resolves it.
- [ ] Run named model/flow/UI owners; inspect summary timer and all-skipped summary. Commit `feat: simplify movement summary and stop remaining workout`.

### Task 4: Show complete workout comparisons and resolve review inline

**Files:** Modify `WorkoutView.swift`, `WorkoutComparisonRows.swift`, `WorkoutViewModel.swift`; tests `PlentyStrongTests/GuidedWorkoutModelTests.swift`, `WorkoutCorrectionHistoryTests.swift`, `PendingWorkoutFinishTests.swift`, `PlentyStrongUITests/GuidedWorkoutFlowTests.swift`, `HistorySettingsTests.swift` and affected WorkoutFlowTests review assertions.

**Interfaces:** Add `confirmWorkoutReviewSummary(movementID: String, effort: Effort?) async throws`, admitted only at `.workoutReview` before frozen Finish. Preserve the stored acknowledged status and demotion; validate explicit effort when performed sets require it; update only effort and that summary's review acknowledgement atomically. Reuse existing native correction entry and `correctSet` audit command; correction returns to its workout card, without pushing a duplicate summary screen.

- [ ] Add coverage for distinct goal/actual weight, units/basis, bodyweight versus unknown load, per-side skipped/unrecorded slots, correction audit/demotion and pending inline confirmation, stopped workout with performed outstanding review, and frozen Finish read-only retry. Confirm new cases fail first.
- [ ] Render compact goal/actual cards before and after Finish, using the current issued draft before save and verified accepted-event projection afterward. Remove routine Review links; retain compact row corrections and collapsed audit. Render effort/Confirm changes only where required, and gate Finish with clear inline guidance.
- [ ] Run named owners and all updated UI owners. Run `make build-app` for unsigned Release. Inspect screenshots of all six stages at normal and accessibility text sizes, including keyboard, Reduce Motion and skip dialogs. Confirm primary/secondary actions are reachable, contrast is usable, and no duplicate sections remain.
- [ ] Review the combined diff against every product-contract row; record exact verification results and any unavailable iOS 18/manual checks. Commit `feat: show workout results and confirm corrections inline`. Hand back for review; build preparation/installation/integration remain subsequent user requests.

## Self-review

Every feedback item maps to a product-contract row and one of tasks 1–4. The five review risks have targeted cases. Goals, actuals, bodyweight, safety and timer semantics remain distinct. The only new authoritative operations are narrowly scoped atomic stop and inline-summary confirmation; persistence schema and progression remain unchanged.
