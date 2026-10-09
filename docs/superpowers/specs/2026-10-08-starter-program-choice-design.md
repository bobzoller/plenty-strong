# Plenty Strong starter program choice: integration design

Status: approved by Bob on October 8, 2026 for implementation through the accompanying six-task plan.

Authority: [verbatim Trainer consultation](2026-10-08-second-starter-program-trainer-consult.md), supplied October 8, 2026. Its exact exercise/dose choices are coaching and product defaults; research links do not validate the complete routine. This integration document supplies explicit engineering interpretations for review. Reviewed source is `6a1860f68214de1cca6f04290f2b6484500c03f7`; it was merged and pushed to remote main on October 8, 2026 before this execution worktree was created.

## Product scope and copy

Offer exactly **Upper-body emphasis** and **Whole-body, glute emphasis**. Both are available to anyone; do not collect sex or infer goals/loads from appearance. Keep the four existing goals (`fat_loss`, `size`, `strength`, `maintenance`) separate from emphasis.

Use the Trainer's descriptions verbatim:
- Upper-body emphasis: “Whole-body training with extra attention to your chest, back, shoulders, and arms.”
- Whole-body, glute emphasis: “Whole-body training with extra attention to your glutes, while building your legs and upper body.”
- Choice help: “Choose the emphasis you want. Either program is for anyone.”

Preserve Bob's original upper-body schedule, movement definitions, dose presets and legacy interpretation. The Trainer's section 9 redistribution is a proposed follow-up, outside this implementation. Do not advertise equal muscle doses or twice-weekly coverage of every muscle for that original routine. Its preview must disclose the pull-up/chin-up setup requirement.

The new profile uses Sunday/Tuesday/Thursday, six exercises in each slot, no required supersets, and the equipment already supported: adjustable dumbbells 5–80 lb in 5 lb steps plus an adjustable bench. A pull-up bar is required only by the upper-body profile. Present the new duration as “Allow about 45–65 minutes; your time may vary.” Do not promise physique shape, regional fat loss, growth rate or universal superiority. No equipment/sex/experience recommendation matrix, accessories tracking, personal Trainer records or new subscription/account/telemetry work.

## Frozen whole-body profile

All new dumbbell catalog values remain exact decimal pounds. Paired loads use `per_implement` and implement count 2; single-dumbbell loads use `total` and count 1. A unilateral set includes both sides, with raw left/right actuals retained.

| ID | Name | Normal reps | Rest | Established size/strength sets | Loading/counting |
| --- | --- | --- | --- | --- | --- |
| db_romanian_deadlift | DB Romanian Deadlift | 8–12 | 120 s | 3 | paired; total reps |
| incline_db_press_30 | Incline DB Press | 8–12 | 120 s | 3 | paired; total reps; about 30° |
| chest_supported_db_row_30_neutral | Chest-Supported DB Row | 8–12 | 120 s | 3 | paired; total reps; about 30° |
| db_floor_glute_bridge | DB Floor Glute Bridge | 10–15 | 120 s | 2 | single; total reps; typed bodyweight alternative |
| supported_static_split_squat | Supported Static Split Squat | 8–12 | 120 s | 2 | single; per side; both feet on floor |
| suitcase_db_squat | Suitcase DB Squat | 8–12 | 120 s | 3 | paired; total reps |
| db_lateral_raise | DB Lateral Raise | 10–15 | 90 s | 2 | paired; total reps |
| supported_single_leg_calf_raise | Supported Single-Leg Calf Raise | 10–15 | 90 s | 2 | single; per side; level floor |
| standing_db_curl | Standing DB Curl | 8–12 | 90 s | 2 | paired; total reps |
| dead_bug_heel_tap | Dead Bug Heel Tap | 6–10 | 60 s | 2 | bodyweight; null load; per side |

| Slot | Movement IDs in exact order |
| --- | --- |
| SUN | db_romanian_deadlift, incline_db_press_30, chest_supported_db_row_30_neutral, db_floor_glute_bridge, supported_single_leg_calf_raise, dead_bug_heel_tap |
| TUE | supported_static_split_squat, db_floor_glute_bridge, chest_supported_db_row_30_neutral, db_lateral_raise, supported_single_leg_calf_raise, standing_db_curl |
| THU | suitcase_db_squat, db_romanian_deadlift, incline_db_press_30, chest_supported_db_row_30_neutral, db_lateral_raise, dead_bug_heel_tap |

For established size/strength there are 44 sets, 15/13/16 by slot. Initial, fat-loss and maintenance doses are two sets per movement: 36 weekly, 12/12/12. Copy the Trainer's complete muscle-exposure table and caveats into the program preview, keeping direct contributions separate from compounds/indirect work. Count a unilateral both-side set once; do not sum overlapping muscle rows into workout totals.

Strength: press, row and suitcase squat use 4–6 only after explicit safe-handling review for the selected load. RDL uses 6–10; all four rest 180 seconds. Other movements retain their listed ranges/rest. Unreviewed press/row/squat emits setup review without working sets; the user can choose the standard 8–12 range or confirm safe handling for 4–6. A new load or setup invalidates the confirmation and requires another review before working sets. Record that choice, not inferred competence. Maintenance uses the existing hold policy; fat loss makes preservation of performance a valid outcome.

Maximum ceilings remain 8 for the explicit strength 4–6 group and 20 for all other ranges, including strength RDL 6–10. Extension remains +2, within the applicable cap, under the existing equipment-limit policy. This resolves the old maximum-8 conflict as an app interpretation; do not change the original exact-v1 rules. Never allow a 20→25 lb automatic increase or silently select a harder bridge/RDL variant at the equipment limit.

## Introductory dose: explicit app interpretation

Every newly selected whole-body program begins with two sets, including experienced users; no experience questionnaire. Only RDL, press, row and suitcase squat can graduate to three sets for size/strength. All other movements and fat-loss/maintenance stay at two. The upper-body profile retains its existing dose presets without this new ramp.

A qualifying introductory exposure is normal-phase, normal-session, complete, controlled, pain-free, positive/equal-side, known non-hard effort, goals met without overshoot, unchanged confirmed load/setup/dose/rest/range, and no skips/mixed loads. Baseline, easier, return, partial, unknown, conflicting or hard work cannot supply credit. Require two consecutive qualifying exposures in one matching session-position context; another context neither joins nor erases that streak. Ineligible normal work resets that context's intro streak; skipped/easier work freezes it; setup/load/goal changes and a long-gap return clear all contexts.

On the second eligible exposure, retain achieved targets without a bonus, call the existing `resizeExactExerciseState(_:to:)` to grow to three, retain load, enter baseline and clear all comparison windows. Thus [10,9] becomes [10,9,8]. Set growth takes precedence over simultaneous load/rep-ceiling/rep growth. The saved completed workout still has its original two sets; the new three-set baseline belongs to the saved next prescription. Promotion happens once per variant, not once per weekday. Goal changes re-enter the destination goal's initial dose; setup variants start independently.

## Shared targets, context-specific evidence

Schema-4 variants share load and normal targets across scheduled appearances, matching the Trainer's examples. Store confirmations, strain/shortfall/plateau windows and introductory credit separately by session-position context. Define the context key as canonical SHA256 of profile hash, slot ID, movement position, ordered preceding movement IDs, preceding normal set counts, and the existing setup/load/dose/rest/reserve/range/rules identity. Compute it from the frozen input/issued workout, never a partially advanced state. Exact numerical goals are excluded. Retain at most one current window per slot (three total); replace that slot's obsolete context without erasing other slots.

A context switch loads that window rather than erasing another window. Qualification and setback/load decisions use only its comparable evidence. A safety event pauses the shared movement family immediately. Any actual/shared load change, setup change, set/range/goal change or interrupted return clears every window. Context-specific repeated strain can reduce the shared load, then restart every context in baseline. Do not automatically fork variants based on performance; users can deliberately save different setup variants.

## Versioned architecture and persistence

Keep all schemas 1–3, JSON bytes, hashes, golden outputs and policy-specific behavior unchanged. Add schema/contract 4 with `ProgramPolicy.starterExactV1`, accepting only registered tuples:
- `general-fitness-upper-exact-v2` + its canonical hash + `starter-upper-v1` profile pin.
- `general-fitness-glute-exact-v1` + its canonical hash + `starter-glute-v1` profile pin.

The new upper profile derives its movement/schedule/preset values exactly from the frozen existing profile; its policy allows later explicit program switching while preserving the routine. Existing installations remain on their current policy until an explicit program change. No automatic schema-4 activation.

Add one profile catalog and one movement-dose resolver. One path consumes that resolver for initialization, planning, variant creation, configuration, advancement and validation. Reuse the numerical ExactRepPlanner and resize primitive. Add focused new schema-4 planner/advancer/validator files rather than changing legacy branch semantics or creating a general recommendation engine.

New Codable state is optional and omitted for legacy values:
- `ExerciseState.starterState: StarterExerciseState?`: dose stage, handling choice and context windows.
- `ProgramState.retainedSafety: [String: MovementSafetyState]?`: stable family safety, including movements absent from the current program.
- `MovementVariant.loadingModeOverride: LoadingMode?`: only schema 4's bridge may explicitly select bodyweight instead of external load. No free-text inference or automatic load conversion.

Each bridge loading alternative is an independent variant, created with an explicit schema-4 loading-mode command. Further free-text modifications preserve the explicitly selected mode; correcting text never changes resistance semantics. Effective movement resolution gives the bodyweight alternative null load, implement count 0, empty catalog and no automatic load increase. A guided bridge check offers “Use a dumbbell” / “Use bodyweight”; it never assumes that every dumbbell fits comfortably. Other modifications stay opaque text, with independent histories.

Use immutable profile-specific source/runtime/rules archives. New upper source pin is the frozen fixed-home-gym-v0.2 runtime profile; new glute source ID is glute-starter-design-v0.1 (source schema1), frozen separately from starter-glute-v1. Calendar selection validates each registered profile projection without treating every fixed profile as the old one. Generate actual canonical hashes with their own hash field removed; never invent placeholder pins. Validate the typed metadata projection including dose/safety-family tables. Archive resolution uses the envelope's exact registered profile/rules tuple and source profile; no latest-profile substitution. Training wire version 4 does not itself require SwiftData migration or a backup-container format bump.

## Explicit program switching

Add a typed `JournalCommand.changeStarterProgram(choice:goal:next:)` and pure `changeStarterProgram(state:sourceRules:destinationRules:choice:goal:verifiedHistory:nextWorkout:) -> ConfigurationResult`. Permit supported schemas 2/3/4 to enter a registered schema-4 destination, after replay verification. Do not change the existing schema-2→3 activation path.

Switch within the same program ID and append-only journal. Preserve processed-event identity and last-session date. The adapter records a valid next slot on/after max(today, pending prescription date, lastSessionDate+1); switching cannot enable a second completed workout on the same local day. Preserve every original envelope/raw observation/archive/event ID/date. Replace active configuration with the chosen profile, retain compatible saved variants and verified loads, and restart comparison evidence and the destination's initial dose. RDL/suitcase squat have identical identity/load semantics and may retain usable load. About-30° press/row are distinct from the old 24°/38° setups; start them uncalibrated rather than inventing equivalence. Removed variants remain in immutable history; revisiting a profile may reconstitute a setup/load only from uniquely verified matching prior history. No extra reps or prior all-set credit are inferred.

Stable safety families map incline press angles together, supported row angles together, squat together, RDL together, split squat variations together, all dumbbell curl variants together, pull-ups/chin-ups together, and each other base to itself. These aliases are conservative app safety-continuity choices, not claims that every variation is clinically equivalent. Merge pauses with OR, reserve restrictions with max and source IDs with union into `retainedSafety`, project applicable restrictions into active baseSafety, and preserve removed families for a later switch back. Bridge loading alternatives share one family. Program changes cannot remove pauses or loosen reserves; only the existing explicit clearance path can resume a paused family. Validate the ledger against verified ancestry so imports cannot drop a removed pause; replay explicit clearance events rather than OR-ing all historical pauses forever. Separate-account program creation permits a different registered profile only when all retained programs are healthy/draft-free/unpaused with no restrictions beyond defaults; never transfer records across accounts.

Repository switching requires ready health, expected revision/head, and **no draft at all** (including empty drafts or frozen Finish). Return to Today to finish or explicitly discard an eligible empty draft before switching. One transaction commits destination archives, typed event, state/head and outbox; failure leaves the old export byte-equivalent. Completion/history remain pinned to their original envelope's profile/dose, not current Settings. Schema-4 same-policy conflicts retain unioned family safety; mixed-policy/profile forks preserve every original and block training pending supported resolution. Live cross-policy resolution remains deferred and blocks live rollout.

## UI, cues and illustrations

Onboarding and Settings expose the two emphasis cards and independent goal selection. No default emphasis is preselected; confirmation requires both explicit choices. Restoring a backup bypasses new selection and preserves its stored program. Switching offers a preview/confirmation explaining baseline restart and preserved history/restrictions. Cancellation is a pure no-op. Disable switching under draft, Finish, busy, stale-head or unhealthy-store guards.

Use the Trainer's essential movement cues, setup/load-basis/per-side explanations, duration estimate and honest coverage limitations in a compact expandable preview and movement details. Do not add accessory selectors or an adjustable programming panel. Show introductory status and set growth: “Starting with 2 sets” and “Ready for 3 sets; keep the same weight and establish your baseline.” Exact-goal and raw-actual UI remains separate; missing sides stay missing.

[Icon concepts](2026-10-08-starter-program-choice-icons): one cheerful adult V-taper man in workout shorts and one slim, curvy adult woman in sports top/leggings. Matching monochrome line art, normalized 96×128 canvas, round strokes, no promises conveyed by body shape. These are visual motifs requested by Bob, not sex-selection inputs. Render app versions with native SwiftUI Shape paths, tint through foregroundStyle, hide decorative icons from accessibility, and label the whole button by program title/description/selection. Keep readable at 44 points, light/dark, largest Dynamic Type and Reduce Motion; icons must never be the sole distinguishing cue.

## Verification and release scope

Synthetic fixtures only. Cover 2 choices×4 goals, intro/established totals, ranges/rest/clearance, per-side/null bridge loading, context-specific qualification, frozen history, transitions with removed safety, transactional failure/restart/duplicate Finish, lossless ordinary/graph backups and fake-cloud recovery. Extend discovery to explicitly registered schema-3 and schema-4 policies; unknown future tuples remain retained/unsupported. Run current and actual minimum-runtime matrices with the repo's Makefile; missing runtime remains a failed/unavailable gate, never substituted.

Perform a focused UI capture/readback for both program cards, goals, per-side entry, bridge choice, handling review, introductory completion and saved history after switching. Human program comprehension, VoiceOver and real-device operation remain separately recorded. Executable changes require a new local build identity beyond signed phone build6. No merge/push, phone install, signing, real purchase, cloud provisioning/schema change or publication is authorized by this plan.

## Planning decision notes

The introductory eligibility, default-to-two policy, per-context persistence, strength handling review/cap interpretation, loading alternatives and safety-family mapping are explicit engineering/product adaptations to underspecified trainer details. Bob's plan review approves these interpretations; they are not new research findings. The future recommendation matrix and original-routine revision are separate projects, so this plan is one cohesive selectable-program feature.
