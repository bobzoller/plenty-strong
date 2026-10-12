# Guided workout sheet design

Status: proposed architecture for Bob's review; implementation is not authorized by this document. Baseline: remote `main`, `8982a84d84a4e72bf55e89017a9b789b71d27678`, verified 2026-10-10.

## Experience and scope

Start opens a tall native SwiftUI sheet above the tabs, one task at a time, with horizontal forward transitions, native backward navigation and accessible Back. Reduce Motion suppresses sliding/pulsing. Bottom action and editable-workout safety controls remain usable with keyboard/Dynamic Type. Frozen Finish offers save retry/recovery, with no further working attempt. Dismissal parks the workout; bottom-right Resume across tabs opens the active composition's draft, optionally pulsing briefly when first available.

Movement introduction shows current equipment/setup, confirmed versus issued load, useful Last time context, and collapsed technique cues. Start requires the existing working admission, handling review and actual-load confirmation. Bodyweight retains null numeric load. Setup/program/easier changes retain their existing whole-workout observation lock; later movements may still confirm a catalog load before their first set. No screen bypasses a pause or stricter shared reserve.

Set shows the immutable issued goal and independently entered, initially blank actuals, including separate left/right fields where required. Valid entered values below the goal immediately disclose the existing missed-goal reason picker. Next remains disabled until actual input and every required explicit reason are valid. Raising actuals to the goal hides the prompt and removes the stale effective reason. Goals, Last time, effort and reasons never prefill performed reps. Missing, unequal and zero observations retain their exact meaning; they cannot qualify completed work. Explicit Partial/Stop can retain supported pending raw observations without demanding invented information.

Movement summary lists every intended index with goal versus actual, separate sides, explicit skipped versus unrecorded values, and the truthful outcome. It supports corrections within this unfinished workout and collects the existing whole-movement effort: Too easy, About right, Too hard, or I'm not sure. No performed sets means no required effort. Skip set and Skip movement remain distinct. Optional skip/early-stop notes are excluded from this increment; there is no existing authoritative skip-reason policy.

Non-goals: historical workout editing, per-set effort, new prescribed rest durations, progression/program/variant policy changes, live cloud/accounts, personal records, device installation, purchases and publication. Use native Apple frameworks, no third-party runtime dependencies, and synthetic fixtures only.

## Flow and durable boundaries

| Forward state | Primary action and durable result |
|---|---|
| Introduction | Start confirms required setup/load and persists Set for the first available index. |
| Set | Next atomically appends that actual, records an app-flow 120s within-movement or 180s between-movement deadline anchored to the performed set, and persists Rest or Summary. Duplicate invocation cannot append twice. |
| Rest between sets | Next persists the next Set, including early or at zero. Skipping a set occupies its index without an actual or a new timer. |
| Movement summary | Confirm effort and truthful outcome atomically; persist summary acknowledgement and Rest toward the next movement, or Workout review for the final movement. |
| Rest between movements | Show unchanged remaining deadline and next equipment/movement/cues. Next persists the next Introduction. |
| Workout review | Review original goals, effective actuals, outcomes and corrections; Finish freezes the exact event. |
| Accepted Finish | After the accepted exact receipt, dismiss and select Today immediately; History retains original-issued goals, actuals and audit. |

The last occupied set opens Summary immediately. Its timer continues during review/effort entry. Entering/exiting summary, correcting results or navigating backward never restarts rest. Both rest screens use the same existing prescription duration. Next is always available while no save is running; zero never automatically advances.

Early Partial/Stop/Pain/Control-loss saves the explicit outcome and supported pending raw data immediately, then routes to Summary. An existing deadline continues; these commands do not create rest. All-skipped work shows a truthful skipped summary. Empty paused/setup-review movements issue no sets and require their explicit outcome. Safety stops cannot reopen or promote; review does not create a new working attempt.

## Persisted navigation and scratch input

Add optional `WorkoutDraft.flow`, version 1: a typed forward step, stable movement/set bindings, rest source/destination, and `reviewedSummaryMovementIDs`. Steps are Introduction, Set, Rest, Summary and Workout review. Summary review acknowledgement is separate from the existing outcome acknowledgement: a saved early stop must reopen its still-pending Summary. No serialized view stack is required. Back/review position is transient and never changes the forward cursor.

Validate cursor indices against the issued rows and occupied performed/skipped slots, rest source against an actual observation, summary acknowledgements against explicit outcomes, and review readiness against every movement outcome. Persist actual/outcome plus its resulting cursor in the same repository transaction. Cursor-only changes use exact-draft compare-and-swap; navigation failure leaves the current page and input visible. Explicit review of a saved set invokes correction, never ordinary append.

For legacy drafts with nil flow, derive a conservative cursor: all acknowledged movements lead to Workout review; otherwise use the first unhandled movement, Introduction before observations, Summary when no intended slots remain, and Set for the next unoccupied slot. Reuse an existing deadline as Rest only when its source can be unambiguously associated with that movement's last performed slot; otherwise do not infer rest ownership. Persist reconciled flow without inventing completion, effort or actuals. Exact former screen restoration is guaranteed for new flow-bearing drafts, not unknowable legacy navigation. Invalid present metadata rejects admission rather than silently advancing.

Retain unsaved strings/reason selection in a draft-scoped flow object across dismissal and a small local UI sidecar across relaunch. Key it by store/dataset/program/draft/prescription identity and target step. This is raw text, not `ActualSet`, excluded from backup/cloud/history. Write atomically off-main on changes, flush on navigation/dismissal, and delete after Finish/discard. Restore only matching targets and expected observations; stale scratch cannot overwrite saved results. Force quit before a write completes can lose last unsaved keystrokes. Never write the repository on each keystroke.

## Explicit saved-set corrections

Ordinary `saveDraft` retains its immutable performed/skipped prefixes and acknowledged-outcome restrictions. Add a separate `correctDraftSet` command with expected canonical draft hash, stable operation UUID, movement/set index and replacement actual. Under the existing operation gate, the repository atomically rechecks current ready state, draft/prescription/revision identity, no accepted event and no frozen Finish, validates the replacement, appends its audit record, applies any mandatory outcome demotion and returns the authoritative snapshot.

Add optional `observationAudit` to both `WorkoutDraft` and `CompletedWorkout`: version 1 with ordered `SetCorrection` records. Each record contains operation UUID, movement ID, set index, full before/after `ActualSet`, before/after status, and whether the movement was already outcome-acknowledged. Index and set identity cannot change; only reps, original side values and missed-goal reason may change. Load, variant, issued goal, skips, dates and safety flags remain unchanged. A repeated UUID with identical request returns the committed snapshot; different content rejects. An unchanged replacement is a no-op.

Apply existing raw-value/counting/reason rules, including nonqualifying stop exemptions. No summing, missing-side invention or target substitution. Invalid corrected completed work is atomically demoted to partial. Explicit partial/stopped outcomes remain such; corrections never remove outcome acknowledgement or permit working-set append. Unacknowledged default partial work can receive its first truthful outcome normally. Every correction invalidates that summary's review acknowledgement without rewinding forward work. Reviewed-summary confirmation returns to the forward cursor; Workout review requires all pending summaries confirmed before Finish. Aggregate effort retains its scope and stays editable until Finish.

Audit validation checks supported version, unique operation IDs, stable bindings, allowed field/status changes, same-key before/after chaining and equality between each key's final replacement and its effective logged set. Reverse the ordered corrections from effective logs to reconstruct initial entered observations, then replay forward to prove the same effective values. Validate each retained original structurally and its recorded outcome context; it may truthfully contain missing/zero/asymmetric data. Acknowledged partial/stopped records prohibit later final promotion; acknowledged completed demotion stays partial. This validates declared history, not independent proof of what the user physically performed.

Add optional `WorkoutDraft.pendingFinish`, version 1, containing exact `CompletedWorkout`, next slot and expected revision. Freeze it atomically before submission; subsequent ordinary saves, corrections and feedback reject. Reopen retries this same payload/timing, avoiding an in-memory-only lock. Admission/finalization validate its identity, revision, logs/audit and submitted-event equality. Only explicit rejected-completion repair may clear it, after the existing exact-draft/unchanged-revision/absent-event proof, retaining observations and audit. All optional fields omit nil; unknown metadata versions reject.

Finish carries the audit inside the immutable workout command; existing event/envelope hashes include originals after draft deletion. Admission validates the trail, then unchanged deterministic progression consumes effective `event.exercises` exactly once. History shows effective actuals, correction indicators and original/replacement detail. Both backups and fake-cloud recovery retain/validate that command, with no separate audit archive or sync subsystem.

Nil audit/flow fields are omitted, preserving old canonical bytes and every accepted historical envelope/policy hash. New audit-bearing event and envelope hashes include the trail. Unknown audit/flow versions fail closed. Current older clients require decoded canonical bytes to equal source bytes, so they reject/quarantine new fields rather than safely round-trip them; downgrade compatibility is not promised. Keep both portable backup formats and recovery validation consistent. No accepted journal is rewritten.

## Integration and acceptance

Move presentation/resume to the active composition's tab container; bind flow, scratch and model to that composition identity. Developer-demo-mode draft PR #2, verified head `bad6edac6450332334d7997a8ddfeb0545ef2a27`, parks whole compositions and resets root identity. Real/demo drafts and sidecars must remain isolated. Future implementation starts from refreshed remote main and integrates its verified remote head only if approved; this design does not merge it. Retain detached CPU work, captured admission, writer leases, busy feedback, date-choice, rejected-Finish repair and idempotent frozen Finish.

| Acceptance evidence | Required cases |
|---|---|
| Entry and truthful outcome | Blank/zero/missing/unequal sides; immediate below-goal reason gating and removal; internal/all skips; early partial/safety stop; unknown group effort. |
| Navigation and timing | Dismiss/relaunch at every step; summary pending after early stop; expired rest; skip rest; backward review without duplicate sets/reset; legacy reconciliation. |
| Atomicity and corrections | Duplicate Next/correction UUID; failed save/CAS; original retention; demotion without reopening; frozen Finish edit rejection. |
| Replay and compatibility | Exact legacy bytes; corrected event replay; History; both backup formats; fake-cloud recovery; unknown versions; older-client rejection. |
| UI and isolation | Keyboard/Dynamic Type/VoiceOver; explicit/native Back; Reduce Motion; accessible pinned safety/action; active real/demo resume isolation; no main-thread CPU regression. |

Source anchors: `WorkoutViewModel.swift:238-343,345-412,539-580`; `SetEntryView.swift:21-79`; `TrainingRepository.swift:403-419,459-509`; `BackupDocument.swift:36-55`; `BackupService.swift:117-173,218-256`; `Observation.swift:28-85,148-176`; `RecoveryVerifier.swift:99-105`; `MovementPrescriptionSummary.swift:26-79`. These establish existing load/reason/rest/outcome guards, immutable prefixes, canonical/replay checks and goal/actual separation. This document selects architecture; subsequent implementation planning and code require Bob's design approval.

## 2026-10-11 final build 12 feedback override

The authorized workout polish supersedes the original rest-presentation and saved-summary clauses above. App rest uses 120s within a movement and 180s between movements for every goal/easier mode, leaving immutable issued `restSeconds` and archived policy hashes unchanged. New optional UI `restStartedAt` pairs with integer-second deadlines; nil retains legacy canonical bytes. Forward early-end/last-remaining-slot skip extends a new 120s deadline to 180s from the same anchor in that authoritative save, before Summary appears. Confirmation retains the deadline. Review, correction, retry and background never restart it. Legacy/unproven nil-anchor deadlines remain exact without an archived-duration fallback. Fresh ordinary pending partial work creates its own anchor at its authoritative save; stopped/pain-only work cannot create Rest.

The shared review table uses Set/Goal/Actual/Edit, concise weight/rep values and native 44pt neutral pencils only for editable performed issued slots; accessibility sizes stack complete rows. Rep-entry reasons appear when focus leaves the whole editor or Next commits it; raw drafts and scratch writes remain immediate. Presentation metadata is cached per adopted state and invalidated when that state changes; write admission still resolves and validates independently. Accepted/replayed Finish navigation requires the frozen envelope, nil draft, enabled context, current composition and current model. It clears transient presentation only and makes no Home preparation/journal mutation.
