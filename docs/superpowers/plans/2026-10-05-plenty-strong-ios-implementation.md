# Plenty Strong iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a free, open-source native iPhone app that prescribes and records the supplied fixed strength-training program offline, with private Apple-account recovery and an optional tip jar.

**Architecture:** A pure Swift package owns program selection and deterministic progression. A local-only SwiftData store, written exclusively by one model actor, persists original observations, accepted transitions, drafts, and a durable cloud outbox; SwiftUI reads projections rather than changing persistence directly. A separate CKSyncEngine adapter mirrors immutable records into the user's private CloudKit database, and StoreKit 2 handles optional consumable tips.

**Tech Stack:** Swift 6 language mode; SwiftUI, Observation, Foundation, CryptoKit, SwiftData, CloudKit/CKSyncEngine, StoreKit 2; iOS 18 minimum; Xcode 27.0 / Swift 6.4 planning baseline; Swift Testing, XCTest UI tests; zero third-party runtime dependencies.

**Spec:** Read all of these together:
- `docs/specs/2026-10-05-general-fitness-progression-design.md`
- `docs/specs/2026-10-05-fixed-exercise-selection-design.md`
- `docs/specs/2026-10-05-fixed-exercise-profile.json`
- Referenced acceptance fixture: `docs/specs/2026-10-05-general-fitness-progression-examples.json`

## Global Constraints

- Philosophy: **“No account, no subscription, no telemetry.”** No app login, backend, advertising, paid training features, or analytics/crash-reporting SDK. Apple's optional iCloud/App Store processing is disclosed separately.
- All four goals: `fat_loss`, `size`, `strength`, `maintenance`.
- Active profile `fixed-home-gym-v0.2` derives from archived source `fixed-home-gym-v0.1` with October 6's accessory-free presentation/prerequisite changes: Sunday/Tuesday/Thursday, weekdays `0/2/4`, five ordered movements per slot, 12 base movements, 15 appearances. Initially there is one default variant/state per base movement; additional saved setups have independent states. Maintenance also uses this three-day schedule.
- Equipment: **5, 10, 15, …, 80 lb per dumbbell**; pull-up bar; adjustable bench. Optional free-text **Modifications** describes a saved movement setup; no accessory-specific requirements, selectors, onboarding copy or setup measurements. Do not import Bob's personal loads or assistance setting.
- Exact instruction: **“Stop when you think you could do two more good reps. Stop earlier for pain or loss of control.”** Exact ceiling copy: **“Up to 12 good reps”**, parameterized by the actual ceiling.
- Fat loss: 2 sets, 8–12, 120 seconds. Size: 3 sets, 8–12, 120 seconds. Strength: 3 sets, 4–6 on its four permitted movements, otherwise 8–12, 180 seconds. Maintenance: 2 sets, 8–12, 120 seconds.
- Retain generic numeric-fixture behavior, including size with two days → 4 sets; do not offer two-day scheduling in this fixed-profile app.
- Upward step ≤10%, two comparable confirmations; no forced weekly rep increment; rep-ceiling extension +2/max 20, or max 8 for low-rep strength.
- Two comparable setbacks; interruption boundary 28 calendar days; plateau window six comparable exposures; preserve R01–R16 and evidence IDs E01–E13.
- Easier control: **“I need an easier workout today”**, before working sets only. Sets `max(1, ceil(normalSets / 2))`, capped by a smaller current dose; effort at least `max(4, minimumRir)`; no progression/baseline/recovery-return qualification.
- External loads use canonical positive decimal strings with explicit `kg|lb` and `per_implement|total`. Bodyweight/manual assistance have null load and empty catalogs; null never means zero resistance.
- Per-side reps are never summed; unequal/unfinished sides are partial. Triceps uses one dumbbell/total load; eight other loaded movements use two dumbbells/per-implement load.
- `setupRevision` starts at 1. A new setup has its own stable variant ID and baseline state; explicit reset of an existing setup clears only that variant's comparisons. For bodyweight movements, modified setups still progress reps only. Modifications are opaque text: no added-weight field, signed load, assistance calculation, or automatic change to bodyweight difficulty.
- Problems beat performance, including on skipped/partial/easier logs. Already-paused movements cannot resume through ordinary logging, cloud resolution, or easier preparation.
- Core has no I/O, clock reads, randomness, LLM, or runtime executable rule callbacks. Retain immutable rules/profile versions and hashes and replayable decision traces.
- Event replay precedes date validation: identical ID/content is no-op; changed content is `event_id_conflict`. One applied workout/day; missing rows and stale displayed/planned IDs reject without mutation.
- MIT is the proposed license. Preserve Kado attribution for copied code; use our own branding, identifiers, products, support links, and privacy policy.
- Initial app: iPhone portrait and landscape; system appearance, Dynamic Type and VoiceOver; iPad must remain usable but specialized iPad layouts are deferred.
- No general exercise picker, creation of unrelated custom exercises, custom schedule/equipment, HealthKit, Watch, widgets, Siri, wearables, readiness survey, automatic timed deload, nutrition, rehabilitation, competition, or optional LLM in v1. Saved modified setups of the fixed base movements are supported.

## Review Focus

- Pain/control-loss attached to incomplete or skipped work: actuals survive, the movement pauses, and no positive feedback or restore clears it. Tasks 4 and 7.
- Duplicate/conflicting finalization after crash or from two devices: one local commit per event, no overwritten observations, divergent branches stay visible. Task 6 and cloud Tasks 1–2.
- Missed days, DST, travel, and changed phone clock: never fabricate completion or queue catch-up workouts; calendar changes never rewrite recorded dates. Task 5.
- Unequal sides, unknown effort/load, and a mid-exercise load edit: preserve actuals and require an honest partial/corrected log; never create qualifying reps by normalization. Tasks 2, 4 and 7.
- iCloud unavailable, full, signed out, switched, or partly restored: training remains local, unsent history is preserved, account histories cannot cross-upload, recovery status is truthful. Task 6 and cloud Tasks 1–3.

---

## Planning status and execution boundaries

The app's name is **Plenty Strong**. Use `PlentyStrong` for Swift/Xcode targets, scheme and source folders, and `Plenty Strong` for the displayed app name. Proposed future root is the repository root, bundle ID `us.zoller.PlentyStrong`, private container `iCloud.us.zoller.PlentyStrong`; publisher identifiers remain subject to signing/provisioning review. This is a plan: no application repository has been created and no Swift code has been compiled.

The progression spec is still proposed and its profile extension is not implemented. The decisions below make a concrete, reviewable Swift integration contract; they do not silently edit Trainer documents or Bob's workout program. Bob/trainer review of that contract is a gate before prescribing to users.

The independent cloud and commerce/release subsystems have separate plans:
1. **Offline app:** this plan, Tasks 1–8. Produces a usable local-only app with export/import.
2. **Cloud recovery:** [companion plan](2026-10-05-plenty-strong-icloud-recovery.md), after Task 6; integrate with the offline app before v1 release.
3. **Tips and release:** [companion plan](2026-10-05-plenty-strong-tips-release.md), after the app shell; final release waits for both previous milestones.

At execution time create the new repository and its repo-specific Codex project with that checkout as its only source. Establish a remote default branch, then create workers' isolated worktrees from its freshly fetched HEAD, using only `bobzoller/` branch names. Do not use the Tech Lead checkout as the application repo. Managed project/thread tools are unavailable in this planning session; provision that routing at execution rather than claim it exists.

This Mac currently has only Command Line Tools selected and no Xcode.app was found. Xcode 27 requires macOS Tahoe 26.6 or later. Provision a compatible Mac/Xcode and validate simulator destinations before running app checks; do not install tools during this planning turn. Hosted CI availability for that toolchain is unverified.

## Reference decisions: what to borrow from Kado

Current source reviewed at `scastiel/kado` commit `f3827a68f6e117ba9378f691f485260a4bdd7dae`:
- Borrow SwiftUI/Observation, a focused pure Swift package, native persistence, versioned exports/migrations, native settings/accessibility, and the StoreKit 2 tip lifecycle.
- Kado's current floor is iOS 18. Its production container always enables private CloudKit mirroring; optional access is controlled through iOS Settings, despite README “opt-in” wording.
- Its consumable tips unlock nothing. Its newer cosmetic Supporter Pack is excluded here: all our app functionality remains free.
- Do not copy its mutable-UUID overwrite importer, CloudKit mirrored model constraints, unrelated habit scoring, product IDs, branding, website, widget surface, or settings unrelated to training.
- Depart from automatic SwiftData mirroring: Apple's account transitions can remove even unsent local mirrored data, and CloudKit cannot enforce the local event uniqueness contract. Local SwiftData + explicit private CKSyncEngine transport keeps the authoritative history under our control. No custom backend is needed.
- Kado's public workflow deploys its website; it is not evidence of green iOS CI. Build our own app checks.

Primary sources and pinned file links: [research evidence](../../../research/2026-10-05-strength-app-reference/evidence.md); [Kado README](https://github.com/scastiel/kado/blob/f3827a68f6e117ba9378f691f485260a4bdd7dae/README.md); [Apple mirroring account behavior](https://developer.apple.com/forums/thread/811294); [CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine).

## Proposed contract resolutions for review

1. **Versioning:** production combined state schema is 2, ruleset version `general-fitness-v0.2+fixed-home-gym-v0.2.swift1`. Numeric v0.2 fixtures retain schema 1 and their original frozen rules hash; fixed v0.1 fixtures retain their original source contract. Store active `profileId`, `profileHash`, original `sourceProfileId`/`sourceProfileHash`, rules hash, and byte checksums of the original source artifacts. Never reinterpret a saved event under a later policy.
2. **Hashing:** canonical UTF-8 JSON, recursively sorted keys, compact separators, unescaped Unicode/slashes, standard JSON control-character escaping, integer JSON numbers, explicit null, no floats/NaN. Loads remain strings. Exclude the rules `hash` or profile `contentHash` field from its hash payload. This proposed profile convention reproduces the archived source's declared hash `508cff9a8cc292defccd8c017da28af28007942946d268b8468f6c5a6cc8bb15`; the convention itself was absent from the original prose. Preserve source bytes separately. Compute the derived v0.2 active profile's hash from its actual bytes at implementation time; never reuse the source hash for changed content.
3. **Interruption R05:** the detecting workout is retained but cannot progress; gap detection marks baseline and pending return, clears comparisons, and makes the next exposure one set smaller. A clean, complete, known non-hard reduced return clears the flag/override, restores preset dose and normal mode with zero streaks; that return also cannot progress. No additional return gate. This resolves the parameter table's baseline wording against the detailed rule/fixtures; do not declare full-output R05 goldens approved until reviewed.
4. **Per-side raw data:** `ActualSet` adds nullable `leftReps`/`rightReps`. Completed per-side work requires both positive/equal and `reps` equal to that per-side count. Unequal sides become partial, retaining both originals; derived `reps = min(left,right)` is only a summary and cannot qualify. An unfinished side leaves `reps=0` and status partial. No invented total/extra set.
5. **Scheduling:** pure `reschedulePendingWorkout` changes only the unperformed active prescription/date and revision, with a separately journaled schedule event. Before a workout starts, a missed slot moves to the first future fixed slot; no missed workout is inserted. On an actual scheduled day, allow that day's workout before the user begins. The next date after finalization is strictly future. An existing draft retains its date/ID; crossing midnight requires explicit retain-as-history or discard/restart rather than rebucketing.
6. **Reconfiguration:** explicit goal, stricter restriction, variant create/select/description correction, setup reset, and safe resume commands are journal events. Only affected states reset. Base-movement safety restrictions carry across all its variants; a new variant never clears a pause. Relaxing an external safety restriction is not an ordinary automatic command; require external clearance confirmation and preserve provenance. Do not offer general profile/equipment editing.
7. **Baseline:** use the prescribed number of working sets, as the fixtures do; never turn a single calibration set into a completed full workout. Unknown effort is permitted to save truthful work, but blocks baseline/progression and prompts for missing feedback.
8. **Recovery scope:** cloud covers finalized history, configuration, archived rules/profile, and accepted schedule/resolution events. In-progress drafts are durable on the phone; v1 does not claim cloud recovery for an unfinished draft. The UI discloses this boundary. Sync is offered during onboarding and can be enabled later; declining it never blocks training.
9. **Progression vs history editing:** accepted observations are immutable. V1 supports draft correction before finalization and preserves rejected/remote raw observations separately; retroactive accepted-workout correction requires a future explicit replay contract, not editing rows in place.
10. **October 6 user override — exercise modifications:** remove accessory-specific prerequisites and names from the app. Display generic movement names such as “Pull-up,” “Chin-up” and “Bent-knee hanging leg raise”; do not expose legacy source IDs as labels. Keep original source artifacts/hashes for provenance, but the active selector omits accessory-only requirements and applies these user-requested label overrides. Add optional free-text **Modifications** to identify a saved variant; the program compares performances within that variant without interpreting the description. Serialize/hash the derived `fixed-home-gym-v0.2` and combined variant-aware contract separately and retain original source hashes. No changes to Trainer records are implied.

## Saved movement setups: October 6 decision

Use a standard base movement with an optional free-text **Modifications** field, rather than a separate custom-exercise library. The field describes a saved setup/variant, not a numeric loading model. A user can write “+25 lb” or “35 lb assistance”; the app does not parse either value, infer a sign or effective load, or generate setup suggestions. Dips remain an example for the future exercise library, not an addition to the fixed routine.

- **Identity:** `MovementVariant(id: String, baseMovementID: String, modifications: String)`. IDs are persisted and independent of description text. The default variant has an empty description and a deterministic ID derived from program/base IDs; a new variant receives a caller-supplied opaque ID. Core functions never generate random IDs. Exact default ID payload is the canonical array `["movement-variant-v1", programID, baseMovementID, "default"]`, hashed with SHA-256.
- **State:** `ProgramConfig.variants: [String: MovementVariant]` and `activeVariantIDs: [String: String]` map variant IDs and each base movement's selected variant. In the app contract, `ProgramState.exercises` is keyed by variant ID. Slots and fixed metadata retain base IDs; preparation resolves them through activeVariantIDs. Log/prescription/exposure `movementID` is the resolved variant ID, with `baseMovementID` and a description snapshot recorded alongside it. Archived source contracts keep their original base-ID keys/serialization.
- **Progression:** a new variant starts in baseline with zero streaks/window unless shared base safety requires a pause; it inherits the base movement's permissions/equipment metadata and leaves old variants untouched. Its initial load is null, not borrowed from another variant's performance. Existing bodyweight/manual modes retain null numeric loads and rep-only progression even when their description contains a number. Never derive automatic load progression, a load catalog or an assistance adjustment from text.
- **Switching:** selecting an existing variant restores its saved state/history; interruption rules use that variant's last completed date. Shared base movements across multiple weekly slots use the same selected variant. A variant switch journals a revision change and invalidates unperformed prescription IDs; it cannot happen after a draft's working sets start.
- **Text changes:** “Change setup” creates a new variant or selects a saved one. A separate “Correct description” action preserves identity/counters and does not rewrite accepted historical snapshots. Text is plain, trimmed UTF-8, maximum 200 grapheme clusters; no inferred equivalence, numeric parsing or implicit merging. New saved variants need a nonempty description; the default remains valid with an empty one.
- **Safety:** `ProgramState.baseSafety: [String: MovementSafetyState]`, where `MovementSafetyState` contains paused/minimumRir/sourceEventIDs, gates every variant of a base movement. A pain/control pause propagates to that base safety state; creating/selecting/renaming/resetting a variant cannot clear it. Only the reviewed explicit safe-resume path can clear the shared pause. Variant changes cannot loosen safety restrictions.
- **History and recovery:** retain the base ID, variant ID and original description with every accepted event; immutable journal commands reconstruct the variant registry, selection and independent states. Backup/cloud recovery preserve inactive variants too. Same ID with an incompatible independently-created definition is an integrity conflict; never merge variants by label.

The frozen active profile contains base metadata and the variant-policy version; user-created variants belong to program configuration and journal events, not to the global profile archive/hash. Archived fixture schemas omit these new app-only fields when serializing; do not change their canonical hashes by encoding empty variant dictionaries or null snapshots.

Tasks 2, 4, 5, 6 and 7 below own these contracts/tests; cloud Task 2 owns cross-device replay/conflicts. This replaces the former typed added-weight proposal. No new measured-load policy or body-mass field is needed.

## File and interface map

Paths below are relative to the future app repo, not this Tech Lead folder.

| Location | Responsibility |
| --- | --- |
| `Packages/TrainingCore/Package.swift` | Pure Apple-platform package, resources and tests |
| `Sources/TrainingCore/Contracts/{Program,Observation,Prescription,Ruleset,Journal}.swift` | Codable/Sendable value contracts, inside that package |
| `Sources/TrainingCore/Primitives/{CanonicalJSON,ExactLoad,LocalDate}.swift` | IDs, exact load validation/comparison, calendar dates |
| `Sources/TrainingCore/Program/{FixedProgramSelector,ProgramInitializer,WorkoutPreparer}.swift` | Fixed config and pure prescriptions |
| `Sources/TrainingCore/Progression/{ProgramAdvancer,ExposureClassifier,RecoveryRules,ProgressionRules}.swift` | Ordered transitions and explanation records |
| `Sources/TrainingCore/Configuration/{ProgramReconfigurer,WorkoutScheduler}.swift` | Explicit configuration/schedule events |
| `Sources/TrainingCore/Resources/{fixed-exercise-profile,ruleset-swift1}.json` | Frozen profile and typed source/rule catalog |
| `Tests/TrainingCoreTests/` | Primitives, validation, C/F fixtures, safety and scheduling |
| `PlentyStrong/Persistence/{TrainingSchemaV1,TrainingMigrationPlan,TrainingRepository}.swift` | Local schema, versioned migration, exclusive writer |
| `PlentyStrong/Backup/{BackupDocument,BackupService}.swift` | Lossless versioned file export/import |
| `PlentyStrong/{PlentyStrongApp,AppComposition}.swift` | Composition and app lifecycle |
| `PlentyStrong/Features/{Onboarding,Today,Workout,History,Settings}/` | Focused views/models named in Tasks 7–8 |
| `PlentyStrongTests/`, `PlentyStrongUITests/` | On-disk persistence, UI, failure/restart/accessibility checks |
| `PlentyStrong/Cloud/`, `PlentyStrong/Monetization/` | Companion-plan features |
| `docs/specs/`, `docs/decisions/`, `docs/release/` | Frozen inputs, approved resolutions, release evidence |

Core path notation: `Contracts/`, `Primitives/`, `Program/`, `Progression/`, `Configuration/` and `Resources/` below expand to `Packages/TrainingCore/Sources/TrainingCore/<path>`; `Tests/` expands to `Packages/TrainingCore/Tests/`; package `Package.swift` is `Packages/TrainingCore/Package.swift`. App path notation: unprefixed `Persistence/`, `Backup/`, `Features/` and app `Resources/` in Tasks 6–8 expand to `PlentyStrong/<path>`. Tests/project/docs use the repository-root paths shown. Files change alongside the tests owning their behavior. Store persistence schema versions and backup/envelope versions independently of the algorithm version.

### Task 1: Establish the pure package, source provenance and deterministic primitives

**Files:** Create `Package.swift`; `Primitives/CanonicalJSON.swift`, `Primitives/ExactLoad.swift`, `Primitives/LocalDate.swift`; `Tests/TrainingCoreTests/PrimitiveTests.swift`; copy the four source documents unchanged to repo `docs/specs/`; create `docs/decisions/0001-swift-contract.md`. Source directories use the map above.

**Interfaces:** `CanonicalValue` is null/bool/integer(Int64)/string/array/object, never floating point; `CanonicalJSON.encode(_:) throws -> Data`, `sha256(_:) throws -> String`. Sort keys by Unicode scalar order to match the source Python hash convention; don't normalize Unicode content. `ExactLoad.init(canonicalAmount: String) throws`, `allowsIncrease(to: ExactLoad) throws -> Bool`; checked Foundation Decimal operations reject overflow/loss of precision rather than round. `LocalDate.init(iso8601: String) throws`, comparable and Codable, calendar-day addition/difference using Gregorian dates and explicit supplied timezone in adapters. Manifest: Swift tools 6.4, library/target `TrainingCore`, resources processed, test target `TrainingCoreTests`, platforms iOS 18/macOS 15 so pure tests run on a Mac.

- [ ] **Step 1:** Bootstrap the minimal package/test manifest, then write failing `PrimitiveTests`: decode copied raw JSON, remove only `contentHash`, assert hash equals `508cff9a8cc292defccd8c017da28af28007942946d268b8468f6c5a6cc8bb15`; frozen fixture rules excluding `hash` equal `cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb`. Assert reordering object keys does not change bytes, array ordering does, Unicode stays UTF-8, newline escaping is stable, `40→44` and `50→55` allowed, `40→44.004` and `15→20` denied, invalid/overflow decimals rejected, February 30 rejected.

```swift
@Test func tenPercentBoundaryIsExact() throws {
    let current = try ExactLoad(canonicalAmount: "40")
    #expect(try current.allowsIncrease(to: ExactLoad(canonicalAmount: "44")))
    #expect(try !current.allowsIncrease(to: ExactLoad(canonicalAmount: "44.004")))
    #expect(try !ExactLoad(canonicalAmount: "15")
        .allowsIncrease(to: ExactLoad(canonicalAmount: "20")))
}
```

- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter PrimitiveTests`; expect missing primitives/failing assertions before implementation.
- [ ] **Step 3:** Implement these exact primitive boundaries; record the proposed resolutions above and source byte checksums. Reuse only audited MIT utility patterns; do not rewrite the source specs or generate a physiological rule from a citation.
- [ ] **Step 4:** Run the same command; expect all assertions pass. Review the contract resolutions with Bob/trainer before implementing policy-specific Tasks 3–5; plan approval may serve as that review if the resolutions were explicitly included.
- [ ] **Step 5:** `git add Packages/TrainingCore docs/specs docs/decisions; git commit -m "feat: establish deterministic training core contracts"`.

### Task 2: Implement runtime contracts and the frozen program selector

**Files:** Create `Contracts/{Program,Observation,Prescription,Ruleset,Journal,RulesetCatalog}.swift`; `Program/FixedProgramSelector.swift`; `Resources/{fixed-exercise-profile,ruleset-swift1,numeric-v02-ruleset}.json`; `Tests/TrainingCoreTests/{ContractTests,FixedProgramTests}.swift`. `RulesetCatalog` provides `static func fixedV1() throws -> Ruleset` and `static func numericV02() throws -> Ruleset`, loading validated bundled immutable resources; extract the numeric v0.2 rules object from the unchanged source examples into `numeric-v02-ruleset.json` without changing its content/hash.

**Interfaces:** Port every field in the source API to Codable/Equatable/Sendable values, explicit JSON CodingKeys preserving source names. Define `Goal`, `Effort`, `LoadingMode`, `Load`, `Movement`, `ProgramConfig`, `ExerciseState`, `ProgramState`, `ActualSet`, `ExerciseLog`, `CompletedWorkout`, `Exposure`, `Ruleset`, prescriptions, decisions, `EngineError(code: String, field: String)`, `AdvanceInput`, `AdvanceResult`. `selectFixedProgram(goal: Goal, programID: UUID) throws -> ProgramConfig`; `validate(config:rules:) throws`; `normalizeSideLog(_ log: ExerciseLog, movement: Movement) throws -> ExerciseLog`.

`Exposure` includes original event/date/log, load, actual sets, dose/range/instruction, session mode/phase, loading mode, setup revision, rep convention and the app's base/variant IDs plus description snapshot. Add the exact `MovementVariant`, variant registry/selection and `MovementSafetyState` fields defined above to the app schema; source fixture schemas keep their original serialization. `Ruleset` contains typed presets/parameters and R01–R16/E01–E13 records with source URL, locator, population, limitations, relevant passage reference and adaptation rationale. `JournalEnvelope` includes schemaVersion, datasetID, programID, eventID, eventHash, parentEnvelopeHash, inputRevision, inputStateHash, rules/profile identifiers, original typed command, returned state/prescription/decisions and envelopeHash. `JournalCommand` is initialize/workout/reconfigure/variantChange/reschedule/interruption; cloud resolution will extend this explicitly. Parentless initialize envelopes are roots. No clock/wall-time field determines progression ordering.

- [ ] **Step 1:** Write failing selector/contract tests covering F01/F02/F10–F13 and catalog/null/setup validation. Assert 12 states, 15 ordered appearances, exact SUN/TUE/THU lists from the source JSON, 16 weights for each of nine loaded movements, 3 empty catalogs, all initial loads null, strength low-rep set exactly `{incline_db_press_24,chest_supported_db_row_38_neutral,suitcase_db_squat,db_romanian_deadlift}`. Assert different returned configs do not share mutation; `left=12,right=10` remains partial with originals retained; triceps 35 stays total 35; row 40 stays 40/hand. Add active-profile tests for generic movement labels, omitted accessory-only prerequisites, unchanged movement identities/order, and separate original-source/active-profile hashes; preserve original F expectations as archived-source tests where metadata differs.

Original fixed-profile expectations run against their archived v0.1 profile; production selector tests use v0.2 expectations with the explicit metadata/variant changes. Fixture compilation dispatches by archived profile/rules version instead of replacing old expected IDs/hashes with the current profile. Add `VariantContractTests.swift`: assert exactly 12 default variants/states, empty descriptions, stable default IDs, one selected variant per base, unresolved/wrong-base/duplicate IDs rejected, and correct plain-text length validation. The base routine's identities/order remain unchanged when a selected variant changes.

```swift
@Test func maintenanceKeepsFixedThreeDaySplit() throws {
    let config = try selectFixedProgram(goal: .maintenance,
        programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    #expect(config.daysPerWeek == 3)
    #expect(config.movements.count == 12)
    #expect(config.weeklySlots.map(\.id) == ["SUN", "TUE", "THU"])
    #expect(config.weeklySlots.flatMap(\.movementIDs).count == 15)
    #expect(config.initialLoads.values.allSatisfy { $0 == nil })
}
```

Use idiomatic Swift `...ID` property names (`movementIDs`, `programID`); CodingKeys preserve the source JSON's `...Id`/`...Ids` keys.
- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter 'ContractTests|FixedProgramTests'`; expect missing types/selector failures.
- [ ] **Step 3:** Implement the exact field contracts and selector, applying October 6's accessory-free active-profile and variant identity contract and retaining original source hashes separately. Fixed coverage validates base identities against the active profile, not generic twice-weekly validation; report actual counts. Persist variant states and base safety separately from immutable routine metadata. External missing permissions default to denied; preserve v0.2 external-load default only for numeric fixtures. Supply all E/R catalog records without implying the numeric policies were experimentally validated. Modifications are descriptive; do not create a signed-load field or parse them into load inputs.
- [ ] **Step 4:** Run the same command; expect all pass, including unknown movement, duplicate ID, wrong basis/unit, nonpositive setup revision, overlapping muscle roles and malformed catalogs rejecting.
- [ ] **Step 5:** Commit only these contracts/resources/tests: `git commit -m "feat: select and validate fixed training profile"` after staging the listed files.

### Task 3: Initialize baselines and derive normal/easier prescriptions

**Files:** Create `Program/ProgramInitializer.swift`, `Program/WorkoutPreparer.swift`; `Tests/TrainingCoreTests/PreparationTests.swift`, `FixtureCompiler.swift`; copy source example JSON into `Tests/TrainingCoreTests/Fixtures/source-examples.json` unchanged.

**Interfaces:** `initializeProgram(config: ProgramConfig, rules: Ruleset, firstWorkout: WorkoutSlot) throws -> InitializedProgram` where `WorkoutSlot(date: LocalDate, slotID: String)` and `InitializedProgram(state: ProgramState, workout: WorkoutPrescription)`. `prepareWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool = false) throws -> WorkoutPrescription`. `FixtureCompiler.prepareInput(caseID:) throws -> (ProgramState, Ruleset, Bool)` and `advanceInput(caseID:) throws -> AdvanceInput` expand independent fixtures by recursive object merge/array replacement; valid readable normal IDs are replaced with canonical IDs and valid easier references recalculated, while intentional stale/mismatched cases remain invalid. Task 4 extends the compiler with `expectedAdvanceResult(caseID: String) throws -> AdvanceResult` and `advanceCaseIDs: [String]`, loading independently reviewed complete-result goldens and categorizing all 47 source C IDs by their API.

- [ ] **Step 1:** Write failing C17/C30/C41/C46/C47 and F08 tests: normal preparation exactly equals active prescription; size easier yields 2 sets/ceiling 8/floor 0/effort ≥4 with load unchanged and no state/revision mutation; stricter minimum 5 remains 5; paused sets remain empty; generic two-day size yields 4; all 12 initial fixed states are baseline. Repeated preparation hashes match; bad rules/hash fail without a prescription.

```swift
@Test func easierPreparationReducesDoseWithoutChangingState() throws {
    let (state, rules, _) = try FixtureCompiler.prepareInput(caseID: "C41")
    let original = state
    let easier = try prepareWorkout(state: state, rules: rules, easierToday: true)
    #expect(easier.exercises.first!.sets.count == 2)
    #expect(easier.exercises.first!.sets.allSatisfy {
        $0.repFloor == 0 && $0.repCeiling == 8
    })
    #expect(state == original)
    #expect(easier.exercises.first!.load == state.activePrescription.exercises.first!.load)
}
```
- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter PreparationTests`; expect failure before initializer/preparer exist.
- [ ] **Step 3:** Implement exact initializer/preparer, normal deterministic prescription IDs and the source's exact five-key easier-ID payload. Instructions are stable semantic strings in prescription hashes; localized UI rendering does not change stored IDs. Restriction-specific wording teaches the active minimum. Unknown load stays null; easier ceiling/set count never increases displayed work; pauses and overrides survive.
- [ ] **Step 4:** Run the same command; expect all pass. Check full prescription contents and input equality, not just ID/count projections.
- [ ] **Step 5:** Stage the initializer/preparer/test resources; `git commit -m "feat: prepare baseline and optional easier workouts"`.

### Task 4: Implement the ordered progression transition and all worked examples

**Files:** Create `Progression/ProgramAdvancer.swift`, `ExposureClassifier.swift`, `RecoveryRules.swift`, `ProgressionRules.swift`; `Tests/TrainingCoreTests/{ProgressionFixtureTests,SafetyTests,RecoveryTests}.swift`; `Fixtures/complete-expected-results.json`.

**Interfaces:** `advanceProgram(_ input: AdvanceInput) -> AdvanceResult`, with source applied/no_op/rejected cases and unchanged returned state on rejection. Helpers stay internal; rules operate on values and never perform writes. Complete expected fixture results are independently authored from reviewed policy, not captured from the implementation being tested.

- [ ] **Step 1:** Add failing parameterized C01–C47 tests (prepare cases delegate to Task 3) and F03–F07/F14 integration tests. Each asserts the supplied projection plus complete next state, prescription and decision trace from reviewed goldens. Add independent tests for pain on skipped/partial rows, baseline too-hard, unknown effort, changed actual load, 27/28-day gap, strain at minimum one-set dose, nonnumeric setback/manual_setup_limit, maintenance on-target/easy distinction, strength ceiling max 8, normal ceiling max 20, and six-exposure median overlay/exclusions. Assert same ID/content no-op before date rejection; changed duplicate → `event_id_conflict`; malformed/missing/duplicate rows and stale IDs leave state unchanged.

Add `VariantProgressionTests.swift`: two qualifying rep-ceiling exposures for the same modified pull-up extend reps while numeric load stays null; exposures from default/modified variants never pool streaks or windows. Numeric-looking text cannot enable R13. A shared base pause blocks every existing/new variant and preserves original observations; switching variants cannot clear it. Compare full state/prescription/trace, not only the rep ceiling.

```swift
@Test(arguments: FixtureCompiler.advanceCaseIDs)
func completeWorkedTransition(caseID: String) throws {
    let input = try FixtureCompiler.advanceInput(caseID: caseID)
    let expected = try FixtureCompiler.expectedAdvanceResult(caseID: caseID)
    #expect(advanceProgram(input) == expected) // state + prescription + trace/error
    #expect(advanceProgram(input) == expected) // determinism, no mutation of input
}
```
- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter 'ProgressionFixtureTests|SafetyTests|RecoveryTests'`; expect transition failures before implementation.
- [ ] **Step 3:** Implement validation/replay → R01/paused preservation → R02–R04 → R05/R06 → R07–R15 → R16 overlay. Preserve every raw observation, qualify only comparable contexts, update completed dates even on easier/ineligible work, enforce separate progression permissions, and apply checked exact 10% arithmetic. Apply the reviewed R05 resolution only under the explicit combined contract; retain source fixture provenance. Successful changes restore original preset range, reset comparisons and require baseline; no automatic extra sets or catch-up progression.
- [ ] **Step 4:** Run all core tests: `swift test --package-path Packages/TrainingCore`; expect 47 C and 14 F IDs represented, no skipped fixture, complete-result assertions passing. Human review of the complete goldens must include before/after counters, traces and ineligible-return behavior.
- [ ] **Step 5:** Stage the listed progression/test files; `git commit -m "feat: apply audited deterministic training progression"`.

### Task 5: Add explicit configuration, setup reset and calendar adaptation

**Files:** Create `Configuration/{ProgramReconfigurer,MovementVariantManager,WorkoutScheduler}.swift`; `Tests/TrainingCoreTests/{ConfigurationTests,VariantConfigurationTests,CalendarTests}.swift`; modify `Contracts/Journal.swift` for typed payloads.

**Interfaces:** `reconfigureProgram(state: ProgramState, change: ConfigurationChange, rules: Ruleset, nextWorkout: WorkoutSlot) throws -> ConfigurationResult` (state/workout/decisions). App `ConfigurationChange` cases are `goal(Goal)`, `minimumRir(baseMovementID: String, value: Int)`, `resetSetup(variantID: String)` and `safeResume(baseMovementID: String, externalClearanceConfirmed: Bool)`. Reset increments that variant's setupRevision and rebaselines/clears comparisons without clearing shared safety. Safe resume clears the authorized shared pause and rebaselines every affected variant, preserving all history; it cannot relax a separate external restriction without its own clearance. Unknown/new equipment changes are rejected in this profile. `WorkoutScheduler.nextSlot(onOrAfter: LocalDate, config: ProgramConfig) throws -> WorkoutSlot`; `reschedulePendingWorkout(state: ProgramState, slot: WorkoutSlot, rules: Ruleset) throws -> ConfigurationResult`; `prepareInterruptedReturn(state: ProgramState, asOf: LocalDate, rules: Ruleset) throws -> ConfigurationResult`. The last method is an explicit `JournalCommand.interruption` using the reviewed R05 resolution: only when the supplied date reaches the gap boundary, clear comparisons and prepare a reduced pending return; repeated detection while already pending is no-op. Date/timestamp conversion uses a supplied `CalendarContext(timeZoneID: String)`; historical local date/timezone records never change.

`changeMovementVariant(state: ProgramState, change: VariantChange, rules: Ruleset, nextWorkout: WorkoutSlot) throws -> ConfigurationResult` is pure. `VariantChange` cases: `create(baseMovementID: String, variantID: String, modifications: String)` (create and select), `select(baseMovementID: String, variantID: String)`, `correctDescription(variantID: String, modifications: String)`. Create/select preserves other variants and enforces shared base safety; description correction preserves progression and historical snapshots. Base equipment/permissions cannot be edited through this API. Repository extension `applyVariantChange(programID: UUID, expectedRevision: Int, change: VariantChange, next: WorkoutSlot) async throws -> StoreSnapshot` rejects a changed setup once a draft has started working sets, contains any actual set or contains a problem flag. An empty pre-set draft can be invalidated/reprepared explicitly; never rebind performed observations. Commit command/state/outbox together.

- [ ] **Step 1:** Add failing F09 and calendar/config tests: setup 1→2 resets only that movement to baseline; unchanged movements/history survive; stricter restriction applies; ordinary/easier work cannot resume a pause; resume without external-clearance confirmation rejects. A missed Sunday routes to next future Tue/Thu/Sun; exact scheduled-day start allowed; next workout after completion is future; no event/history is invented. Test DST transitions, Honolulu↔New York travel, leap day, backward device date, one-workout/day, and a draft crossing midnight; rescheduling invalidates old pending IDs explicitly.

Add variant tests: new “+25 lb” setup starts at baseline with zero counters, old default state remains byte-identical; selecting it across all repeated base slots is consistent; returning to the old setup restores its counters and evaluates its own interruption gap. Correcting wording leaves identity/counters unchanged and preserves old event labels. Same label/different ID remains distinct; changing meaning uses create/select, not inferred text parsing. Paused-base new variants stay paused until the explicit safe-resume path. Unknown base, wrong-base selection and reused conflicting variant ID reject without mutation.

```swift
@Test func modifiedBodyweightSetupGetsIndependentBaseline() throws {
    let config = try selectFixedProgram(goal: .size,
        programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let rules = try RulesetCatalog.fixedV1()
    let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
    let initial = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
    let baseID = "banded_pullups" // archived internal ID; user-facing name is Pull-up
    let oldID = config.activeVariantIDs[baseID]!
    let changed = try changeMovementVariant(state: initial.state,
        change: .create(baseMovementID: baseID, variantID: "test-pullup-25", modifications: "+25 lb"),
        rules: rules, nextWorkout: slot)
    #expect(changed.state.config.activeVariantIDs[baseID] == "test-pullup-25")
    #expect(changed.state.exercises["test-pullup-25"]!.mode == .baseline)
    #expect(changed.state.exercises["test-pullup-25"]!.load == nil)
    #expect(changed.state.exercises["test-pullup-25"]!.ceilingStreak == 0)
    #expect(changed.state.exercises[oldID] == initial.state.exercises[oldID])
}
```

```swift
@Test func missedSundaySchedulesTuesdayWithoutCatchUp() throws {
    let config = try selectFixedProgram(goal: .size,
        programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let next = try WorkoutScheduler.nextSlot(
        onOrAfter: LocalDate(iso8601: "2026-10-05"), config: config)
    #expect(next == WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: "TUE"))
}
```
- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter 'ConfigurationTests|CalendarTests'`; expect missing adapter failures.
- [ ] **Step 3:** Implement the reviewed typed commands and calendar boundaries. Reschedule only before draft working sets; don't use locale week start to alter the fixed weekdays. Calendar-driven suspension detection must surface a pending return before the next workout starts, by an explicit journaled adapter command using R05, never a hidden clock inside prepare/advance. Configuration changes preserve original history and reset only affected comparisons.
- [ ] **Step 4:** Run all core tests; expect all earlier fixtures plus these boundary tests pass. Verify scheduled/actual date handling and interruption preparation agree with the reviewed contract.
- [ ] **Step 5:** Stage the configuration files/tests; `git commit -m "feat: journal setup and schedule changes explicitly"`.

### Task 6: Persist a crash-safe local journal, drafts, projections and portable backup

**Files:** Create `PlentyStrong/Persistence/{TrainingSchemaV1,TrainingMigrationPlan,TrainingRepository}.swift`; `Backup/{BackupDocument,BackupService}.swift`; `PlentyStrongTests/{RepositoryTests,BackupTests,MigrationTests}.swift`; fixture stores/backups under `PlentyStrongTests/Fixtures/`. Create the Xcode app/unit/UI-test targets and shared `PlentyStrong` scheme here so persistence tests can run; a minimal app shell only, actual flows in Task 7.

**Interfaces:** `@ModelActor TrainingRepository`: `initialize(config:rules:firstWorkout:) async throws -> StoreSnapshot`, `snapshot(programID:) async throws -> StoreSnapshot`, `finalize(programID: UUID, expectedRevision: Int, event: CompletedWorkout, next: WorkoutSlot) async throws -> FinalizationReceipt`, `applyConfiguration(programID:expectedRevision:change:next:) async throws -> StoreSnapshot`, `reschedule(programID:expectedRevision:slot:) async throws -> StoreSnapshot`, `prepareReturn(programID:expectedRevision:asOf:) async throws -> StoreSnapshot`, `saveDraft(_ draft: WorkoutDraft) async throws`, `discardDraft(id: UUID) async throws`, `exportBackup() async throws -> BackupDocument`, `importBackup(_ document: BackupDocument) async throws -> ImportReceipt`.

`StoreSnapshot` holds `state: ProgramState`, draft, `history: [JournalEnvelope]`, decisions, and `StoreHealth` (ready/integrityConflict/unsupportedVersion). `FinalizationReceipt` has `result: AdvanceResult` and `snapshot: StoreSnapshot`. `WorkoutDraft` retains stable ID, original planned/displayed prescriptions, date/timezone, actual logs and workingSetsStarted; never counts as completed history. `BackupDocument` includes formatVersion=1, dataset ID, all journal/config/rule/profile archives, drafts and per-object checksums; excludes Apple account identity, credentials, CloudKit tokens/system fields and device commerce data. `ImportReceipt` reports accepted/identical/conflicted counts; never overwrites originals.

Test-only `PlentyStrongTests/Support/RepositoryTestHarness.swift` provides `static func make(goal: Goal) async throws -> RepositoryScenario`; `RepositoryScenario` contains a temporary on-disk `repository`, `programID`, initialized `initialRevision`, valid `firstEvent` (explicit actuals, known load, normal mode), and `next: WorkoutSlot`. Use actual core/persistence code, not a mocked successful finalize.

Local schema models: `JournalRecord` unique event ID plus canonical envelope bytes/hash; `ProgramHeadRecord` unique program ID plus revision/state bytes/head envelope hash; `RuleArchiveRecord`/`ProfileArchiveRecord` content hashes and original bytes; `DraftRecord` unique draft ID; `OutboxRecord` unique record key, dataset/account association, payload reference and ack state; `CloudCursorRecord` serialized engine state/account scope; `QuarantineRecord` raw conflicting/invalid remote bytes. Store independent objects with explicit indices/IDs, not relationship arrival/order assumptions. Include initialization/config/schedule envelopes in the same journal/outbox as workouts.

- [ ] **Step 1:** Bootstrap the app/unit/UI-test targets and shared scheme, then add failing on-disk tests: finalize twice → one event/revision/outbox entry; same event ID changed payload rejects; stale revision reads current state and never overwrites it; race two actor submissions yields one accepted transition; injected save failure rolls back event/head/draft removal/outbox together. Kill/reopen around the commit boundary and assert all-or-none. Draft reps/effort/problems survive restart. Corrupt/newer/duplicate/conflicting/truncated backups reject or quarantine without deleting existing history; export/import into empty store reproduces all accepted state/traces and source hashes. Test a failing migration preserves the old store file.

Variant create/select/correction commands use the same expected-revision, atomic journal/head/outbox path. Test crash/reopen and export/import with active/inactive variants, independent streaks, shared safety and historical description snapshots; restored selection must match the accepted state. A draft cannot be rebound to a different variant during finalization.

```swift
@Test func repeatedFinishDoesNotCommitTwice() async throws {
    let s = try await RepositoryTestHarness.make(goal: .size)
    let first = try await s.repository.finalize(programID: s.programID,
        expectedRevision: s.initialRevision, event: s.firstEvent, next: s.next)
    let repeated = try await s.repository.finalize(programID: s.programID,
        expectedRevision: s.initialRevision, event: s.firstEvent, next: s.next)
    #expect(first.snapshot.state.revision == s.initialRevision + 1)
    #expect(repeated.snapshot.state == first.snapshot.state)
    #expect(repeated.snapshot.history.filter { $0.eventID == s.firstEvent.eventID }.count == 1)
}
```

Repository replay lookup precedes expected-revision rejection for an already accepted identical event; an unaccepted event with a stale revision still rejects.
- [ ] **Step 2:** Run `xcodebuild test -project PlentyStrong.xcodeproj -scheme PlentyStrong -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -only-testing:PlentyStrongTests/RepositoryTests -only-testing:PlentyStrongTests/BackupTests -only-testing:PlentyStrongTests/MigrationTests`; expect initial failures. Validate that exact destination exists first; install its runtime or record the compatible available destination in the repo's Makefile.
- [ ] **Step 3:** Implement local `ModelConfiguration(cloudKitDatabase: .none)`, autosave disabled, one writer actor and no direct view writes. Inside one synchronous no-await `ModelContext.transaction` validate expected revision and event/hash, run the pure transition, save original envelope/result/head/outbox and remove finalized draft. Roll back on any error. SwiftData uniqueness is upsert: validate conflicts before insertion and prohibit other writers. Retry stale submissions only from fresh state; never rebind an event to a changed prescription automatically. Backup importer uses the same serialized transaction/validation path. Do not silently discard/recreate an unreadable database.
- [ ] **Step 4:** Run the same tests, plus replay each accepted envelope with its archived rules/input and compare full outputs. If SwiftData cannot pass all-or-none/crash tests, stop this task and replace the repository internals with native SQLite transactions behind the same API after documenting the measured failure; do not ship a weaker acceptance invariant or add a second authoritative store casually.
- [ ] **Step 5:** Stage only persistence/backup/project/test files; `git commit -m "feat: persist atomic offline workout history and backups"`.

### Task 7: Build onboarding, Today and a recoverable workout flow

**Files:** Create `PlentyStrong/{PlentyStrongApp,AppComposition}.swift`; `Features/Onboarding/OnboardingView.swift`; `Features/Today/TodayView.swift`; `Features/Workout/{WorkoutView,WorkoutViewModel,MovementSetupView,SetEntryView,EffortPicker,RestTimer}.swift`; `PlentyStrongUITests/WorkoutFlowTests.swift`, `MovementSetupTests.swift`; `PlentyStrongTests/WorkoutViewModelTests.swift`.

**Interfaces:** `@MainActor @Observable WorkoutViewModel` consumes repository snapshots only; `start(easierToday: Bool) async throws`, `recordSet(movementID: String, index: Int, actual: ActualSet) async throws`, `recordEffort(movementID:effort:) async throws`, `recordProblem(movementID:problem:) async throws`, `changeSetup(_ change: VariantChange) async throws`, `finish() async throws -> FinalizationReceipt`. `RestTimer` stores deadline and remaining duration; injectable clock is UI-only, never a progression input. Onboarding selects one `Goal`, shows required core equipment and load conventions, creates no workout until confirmed, and never guesses a starting weight. `MovementSetupView` shows optional **Modifications**, “New setup,” saved setup selection and “Correct description.” Descriptions are user-authored; no accessory presets or force/weight interpretation. Setup changes are allowed only before working sets; first use of a new setup clearly shows baseline.

- [ ] **Step 1:** Add failing flow/view-model tests: first launch selects any of four goals and displays correct fixed day/dose; unknown external-load movements use a user-confirmed catalog choice; bodyweight setups never show an inferred numeric load. Onboarding and standard movement names have no accessory-specific requirements/prompts. Optional Modifications accepts “+25 lb” as text with no body-mass/numeric-load question; saving a new setup shows baseline, returning to a saved setup restores its history, and a spelling correction preserves counters. A new setup cannot bypass a pause, rewrite old history or be selected mid-working-set draft. Resting timer survives backgrounding. Easier toggle before first set immediately changes dose and instruction, then becomes unavailable. Pain/control stop is available throughout, preserves draft actuals and cannot finalize as clean. Unequal sides produce partial; missing rep/log rows cannot finalize; edited external load mid-exercise demands correction/restart and retains draft observations. Force quit after set entry and resume the same draft. Double Finish submits the same event ID.

```swift
func testEasierModeIsAvailableBeforeWorkingSets() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-reset-local-store", "-cloud-disabled"]
    app.launch()
    app.buttons["onboarding.goal.size"].tap()
    app.buttons["onboarding.confirm"].tap()
    app.buttons["today.start"].tap()
    app.buttons["workout.easier"].tap()
    XCTAssertEqual(app.staticTexts["workout.session-mode"].label, "Easier workout")
}
```

Define these stable accessibility IDs in the corresponding views. Test reset/service overrides are available only to DEBUG UI-test builds and use synthetic data; production launches cannot erase data through these arguments.
- [ ] **Step 2:** Run `xcodebuild test ... -only-testing:PlentyStrongTests/WorkoutViewModelTests -only-testing:PlentyStrongUITests/WorkoutFlowTests` with the project/scheme/destination from Task 6; expect initial failing flows.
- [ ] **Step 3:** Implement goal/equipment onboarding and Today→Workout→next prescription. Show “Up to N good reps” and the stopping instruction together; record actual reps, confirm/edit actual load once per exercise, ask “How hard was that?” after its last working set, plus independent problem flags. Never prefill performed reps, auto-finish on time passing, or require readiness/nutrition/wearable data. Provide explicit partial/skipped/stopped paths for every row, including paused movements. A live problem halts that movement immediately in UI; its accepted observation is finalized through the engine, not erased if a draft is resumed.
- [ ] **Step 4:** Run these tests in airplane-mode conditions with no Apple account and products unavailable; expect complete normal/easier/partial flows, persisted restart recovery, correct finalization and next prescription. Verify VoiceOver labels announce per-hand/per-side/total and minimum effort clearly.
- [ ] **Step 5:** Stage feature files/tests; `git commit -m "feat: guide and record offline strength workouts"`.

### Task 8: Add useful history, explanations, privacy/settings and offline acceptance

**Files:** Create `Features/History/{HistoryView,WorkoutDetailView,DecisionExplanationView}.swift`; `Features/Settings/{SettingsView,ProgramSettingsView,BackupSettingsView,AboutView}.swift`; `Resources/Localizable.xcstrings`; `PlentyStrongUITests/{HistorySettingsTests,OfflineAcceptanceTests}.swift`; `docs/release/offline-acceptance.md`.

**Interfaces:** Views read `StoreSnapshot`; history detail reads original actuals and stored `Decision`s. Explanations map `explanationKey` to short copy and optional source/adaptation detail; never call an LLM or recompute old decisions with current rules. Settings uses Task 5 reconfiguration and Task 6 backup methods. Define Settings extension points for cloud status and tips without placeholder network requirements.

History groups by base movement with distinct saved-setup histories; detail uses the original description snapshot even after a wording correction. Never pool rep records across variant IDs or label an assisted/modified performance equivalent to another setup.

- [ ] **Step 1:** Add failing tests: historical 10/10/9 remains actuals while next prescription is up to 12; pain/partial/above-ceiling actuals stay visible; maintenance stable reps are success, not failure. Goal/setup reset retains history and only resets affected state. Share lossless JSON and reimport duplicate data idempotently; unknown backup schema preserves store and offers readable error. No cloud/network/account/tip feature is necessary for a workout. Tests cover VoiceOver, accessibility text sizes, keyboard errors, Reduce Motion and dark mode.

```swift
func testHistoryKeepsActualRepsSeparateFromNextPrescription() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-fixture", "history-10-10-9", "-cloud-disabled"]
    app.launch()
    app.buttons["tab.history"].tap()
    app.buttons["history.first-workout"].tap()
    XCTAssertEqual(app.staticTexts["history.actual-reps"].label, "10, 10, 9")
    XCTAssertEqual(app.staticTexts["history.next-rep-ceiling"].label, "Up to 12 good reps")
}
```

The DEBUG-only `history-10-10-9` seed is a valid synthetic journal produced through the repository, with a next ceiling of 12; it never references Trainer personal history. Add the named accessibility IDs to history views and the seed handler to AppComposition.
- [ ] **Step 2:** Run `xcodebuild test ... -only-testing:PlentyStrongUITests/HistorySettingsTests -only-testing:PlentyStrongUITests/OfflineAcceptanceTests`; expect missing history/settings failures.
- [ ] **Step 3:** Implement Today/History/Settings navigation, plain-language decision details, actual coverage counts, explicit setup-change reset, and paused review flow requiring the approved safe-resume confirmation. Explain fixed equipment/split limitations without adding a programming control panel. About links to source, MIT/attributions and fresh privacy information. JSON is the v1 lossless backup format; CSV/Charts can follow later without blocking v1.
- [ ] **Step 4:** Run core tests, all app unit/UI tests, and `xcodebuild build` on both iOS 18 and current iOS simulator destinations. Record evidence, including a normal user comprehension session for stopping/effort/per-side terms; training-policy human review is required before external beta. Do not say policy efficacy or usability is proven by these tests.
- [ ] **Step 5:** Commit the offline milestone: `git commit -m "feat: ship reviewable offline training app milestone"` after staging the listed files. Continue cloud and tips/release plans only after their interfaces and this milestone are reviewed.

## Self-review and coverage audit

- Selector/profile/equipment/loading/setup/fixed coverage: Tasks 1–3/5, F01–F14.
- Initializer, Exposure/Ruleset runtime contracts, preparation IDs/errors and decimal/date hashes: Tasks 1–3.
- Every R01–R16, every C01–C47, complete expected state/prescription/trace and rejected invariants: Task 4, with preparation cases owned by Task 3.
- Explicit configuration/interruption-before-start/missed-day routing: Task 5. Calendar adapter commands are recorded separately, never hidden workout completions.
- Opaque Modifications/variant identity, independent progression, safe switching and shared base pauses: Tasks 2/4/5/7; persistence and full replay/restore: Task 6 and cloud Task 2. Numeric text never becomes a load.
- Atomic event uniqueness/expected revision/raw observations/replay/cloud outbox/drafts/export: Task 6; no multi-process SQL isolation guarantee is inferred from SwiftData alone.
- User-facing logging, baseline, easier control, safety, explanations and comprehension: Tasks 7–8.
- Cloud account recovery/concurrency and StoreKit/privacy/release are fully assigned to the companion plans; these are not optional exclusions from the promised v1.
- The five Review Focus conditions have named tests above or in the cloud plan. Interfaces use the same types and method names in all three plans. No app implementation or execution test is claimed complete by this document.
