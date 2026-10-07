---
date: 2026-10-05
status: proposed-for-review
scope: general-fitness-app-program-progression
ruleset: general-fitness-v0.2
---

# General Fitness Progression Algorithm Specification

This specification defines a simple resistance-training progression engine for
ordinary adults pursuing muscle preservation during weight loss, muscle growth,
strength, or maintenance. The app supplies the programming decisions. Users
select a goal, follow a prescription, and log a small amount of feedback. The
initial fixed profile supplies three training days. The core returns reproducible decisions with evidence
references.

The initial selection boundary is the [fixed exercise-selection stub](2026-10-05-fixed-exercise-selection-design.md),
with [hardcoded program data](2026-10-05-fixed-exercise-profile.json). Its loading-mode
and fixed-coverage extensions are normative for that profile. Numeric-only core
fixtures retain their v0.2 contract; implementing the combined profile requires
an explicit ruleset version/hash as described in the addendum.

This is a proposed design, not a deployed algorithm or a change to Bob's personal
plan. It specifies progression, goal presets, input/output contracts, decision
precedence, and worked examples. General exercise selection, nutrition prescriptions,
rehabilitation, competition preparation, and the app interface are separate work.
The intended population is adults cleared for ordinary resistance exercise;
children, medically restricted programs, and athletic peaking need other policies.

## Revision approved October 5

This revision replaces the October 4 readiness question and automatic recovery
week with an optional **I need an easier workout today** control. It acts before
training and changes that session only. Automatic adjustments use actual reps,
exercise effort, and problems. The [dated decision](../../../consultations/2026-10-05-app-readiness-question-removal.md)
records Bob's approval.

## Product decisions

- One deterministic engine serves all four goals through versioned presets.
- The common effort instruction is: **Stop when you think you could do two more
  good reps. Stop earlier for pain or loss of control.** No mandatory failure sets.
- Each set has a rep ceiling, not a compulsory rep count. The app says, for
  example, **Up to 12 good reps**, with the effort instruction beside it.
- Repetitions may increase naturally by several between sessions. There is no
  one-rep-per-week limit and no obligation to improve every workout.
- The engine increases load after confirmed performance at the ceiling. It does
  not manufacture rep increases when the current effort already matches the goal.
- Users do not choose progression percentages, RIR ramps, or set counts. An
  optional easier-workout control lets them request less work without diagnosing
  their recovery. No readiness question or automatic timed deload is required.
- Session execution is local and independent of an LLM. An optional LLM can
  explain recorded decisions or suggest structured interpretations of notes.
  Ambiguous interpretations require confirmation before becoming observations.

The rep-ceiling approach replaces the existing notebook engine's forecasted
three-number rep vector for this proposed app. A result such as 10/10/9 remains
actual performance; the next prescription can still be three sets of up to 12,
with two good reps left. Users follow one instruction rather than deciding
whether to exceed a predicted target.

## Evidence and exact policy

No study validates this entire algorithm. Every rule carries one of these labels:

| Label | Meaning |
| --- | --- |
| Research finding | An outcome supported by a study or evidence synthesis. It does not automatically supply executable thresholds. |
| Published prescription | A specified recommendation or protocol in a professional or research publication. It is not necessarily proven superior to alternatives. |
| App adaptation | An exact product rule derived from those sources. Its particular threshold remains a proposed design choice. |
| Software requirement | Validation, reproducibility, persistence, and conflict handling; these are engineering requirements rather than physiological claims. |

The rule catalog must retain the source population, limitations, relevant passage,
and adaptation rationale. A citation attached to a general principle must not be
used to imply that a particular integer, percentage, or combination was tested.

### Source register

| ID | Source and locator | What it contributes |
| --- | --- | --- |
| E01 | [ACSM 2026 position stand](https://pmc.ncbi.nlm.nih.gov/articles/PMC12965823/), Results and Practical Applications; [official summary](https://acsm.org/resistance-training-guidelines-update-2026/) | Foundation for healthy adults: regular training, goal-dependent load/volume, sufficient effort, and optional failure/complex periodization. Exact individual RIR optima remain uncertain. |
| E02 | [ACSM 2009 progression position stand](https://pubmed.ncbi.nlm.nih.gov/19204579/), progression and loading recommendations | Published 2–10% load-increase guidance after exceeding the intended repetitions by one or two. Older guidance, supplemented by E01. |
| E03 | [NASM progressive overload guidance](https://www.nasm.org/resource-center/blog/training/progressive-overload-explained-programming-progress-for-every-client), “Use the 2-for-2 Rule” | Professional heuristic: two extra final-set reps on two consecutive workouts; suggested upper/lower-body increment ranges. Professional guidance rather than a head-to-head validation of exact thresholds. |
| E04 | [Currier et al. 2023](https://pubmed.ncbi.nlm.nih.gov/37414459/), Abstract and Discussion | Many prescriptions improve strength and size; higher loads favor strength and multiple sets favor hypertrophy. Network rankings do not prescribe an individual optimum. |
| E05 | [Plotkin et al. 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC9528903/), Training Procedures and Conclusion | Repetition and load progression were both viable in an eight-week trial of trained adults. The study used supervised failure training; this app does not copy that effort protocol. |
| E06 | [Refalo et al. 2024](https://pubmed.ncbi.nlm.nih.gov/38393985/), Methods and Results | Similar quadriceps growth with failure versus 1–2 RIR, with greater acute fatigue from failure, in a small trial of trained adults. Does not prove the proposed default across every movement or population. |
| E07 | [Halperin et al. 2022](https://pubmed.ncbi.nlm.nih.gov/34542869/), Results and Conclusions | Effort estimates contain error. Feedback categories are observations, not exact measurements of remaining repetitions. |
| E08 | [Pelland et al. 2025, 2026 issue](https://link.springer.com/article/10.1007/s40279-025-02344-w), Methods and Conclusions | Volume has diminishing returns; distinguishing direct/indirect sets improves dose accounting. The sample was predominantly young men. No personalized recoverable-volume threshold is established. |
| E09 | [Murphy and Koehler 2022](https://onlinelibrary.wiley.com/doi/full/10.1111/sms.14075), Abstract and Discussion | Energy deficits constrain lean-mass gains more consistently than strength gains. Supports different success expectations during a cut, not a universal volume reduction. |
| E10 | [Bickel et al. 2011](https://pubmed.ncbi.nlm.nih.gov/21131862/), Methods and Conclusions | Maintenance can require less training, with age-dependent results. Does not justify one set weekly for every user or applying maintenance doses to a cut. |
| E11 | [IUSCA 2021 position stand](https://journal.iusca.org/index.php/Journal/article/view/81), Load, Volume, Rest Interval, and Proximity to Failure sections | Detailed hypertrophy guidance, including loading flexibility and rest. Athletic-population scope limits direct transfer of aggressive prescriptions. |
| E12 | [Bell et al. 2023 deload consensus](https://link.springer.com/article/10.1186/s40798-023-00633-0), Design Principles | Expert consensus on reducing stress to manage fatigue. The optional easier session adapts that principle; its exact dose and single-session scope are app policy. |
| E13 | [Coleman et al. 2024 deload trial](https://pmc.ncbi.nlm.nih.gov/articles/PMC10809978/), Methods and Conclusion | A scheduled week of complete cessation did not improve hypertrophy and reduced strength gains in that trial. Complete cessation differs from a single optional easier session; this trial does not validate that feature. |

## Four opinionated presets

These are reviewable **app adaptations** of E01–E04, E06, and E09–E11. The numbers
are proposed operational defaults, not four protocols independently validated in
trials. The app supplies them without exposing a programming settings panel.

| Goal ID | Default days | Working sets per movement exposure | Rep floor and ceiling | Rest between working sets | Objective |
| --- | --- | --- | --- | --- | --- |
| `fat_loss` | 3 | 2 | 8–12 | 120 seconds | Preserve useful loading, performance, and adherence while losing weight. |
| `size` | 3 | 3; use 4 if only 2 days are available | 8–12 | 120 seconds | Build reps/load with more weekly work than maintenance. |
| `strength` | 3 | 3 | 4–6; use 8–12 where low-rep loading is unsuitable | 180 seconds | Increase capability with heavier loading and adequate rest. |
| `maintenance` | 2 | 2 | 8–12 | 120 seconds | Maintain capability at a manageable dose without compulsory escalation. |

All goals use approximately two clean reps left. “About right” is intentionally
broad; it does not certify exactly 2 RIR. The strength rep range cannot be assumed
to equal a particular percentage of 1RM. The engine does not require 1RM testing.

The general plan builder may support two or three days based on availability.
The initial fixed profile always supplies Sunday, Tuesday, and Thursday for all
goals. Its split overrides the generic day-count default, including maintenance.
For example, a primary movement
trained three times with three sets provides nine direct weekly sets; this is a
practical approximation to higher-volume guidance, not a universal minimum for
growth. Changing the number of days changes the plan configuration and resets
comparison counters; it is not interpreted as a sudden performance decline.

Normal set counts stay fixed. Version 0.2 does not estimate MEV/MRV, add sets from
pump/soreness, or escalate volume automatically during a plateau. Sets change
through preset changes, temporary recovery sessions, or configuration changes.
A cut is not automatically assigned the smallest maintenance dose.

### Parameters whose exact values are app choices

| Parameter | Value | Basis and limitation |
| --- | --- | --- |
| Normal effort target | Approximately 2 clean reps left | E01/E06/E07; a simple common instruction, not a proven universal optimum. |
| Load confirmation | 2 comparable ceiling exposures | Adaptation of E03 using capped reps and effort feedback rather than performing bonus reps. |
| Maximum automatic upward load step | 10% | E02; proposed common upper bound. Equipment rounding never permits a larger step. |
| Effort or rep-floor setbacks before retreat | 2 comparable exposures | Trend safeguard; E07 supports uncertainty handling, but this exact count is an app choice. |
| Easier-session set count | `max(1, ceil(normalSets / 2))`, capped by an existing smaller temporary dose | E12-informed reduced-stress adaptation; applies to one session, not a week. |
| Easier-session effort | At least 4 clean reps left; stricter restrictions still apply | App choice to make the requested session visibly easier. |
| Equipment-driven rep-ceiling extension | +2, to at most 20; strength low-rep slots at most 8 | E05/E11 support wider loading options; these steps and limits are app choices. |
| Return after a long interruption | 28 days; baseline mode and one fewer set, minimum 1, for the next exposure | Conservative app choice, not a scientifically established interruption boundary. |
| Building-goal plateau notice | 6 comparable exposures; latest-three median total reps no greater than first-three median | App choice for a visible trend; not proof that muscle growth has stopped. |

## Minimal user observations

The app knows the prescription and offers its load as the logging default; the
user confirms or edits it. Planned values never become performed values merely
because time passed. Each performed set needs an actual rep count.

After the final working set, ask **How hard was that?**

| Answer | Explanation | Stored observation |
| --- | --- | --- |
| Too easy | “I could have done several more good reps.” Approximately 4 or more is the teaching example. | `too_easy` |
| About right | “Challenging, but I had roughly two good reps left.” Approximately 1–3 is the teaching example. | `on_target` |
| Too hard | “I reached my limit or could not leave a couple of good reps.” | `too_hard` |

Pain and loss of control are separate problem flags, never just “too hard.” A
stop/problem flag is available throughout the exercise. There is no mandatory
readiness question. Before the first working set, users may select **I need an
easier workout today**. The app supplies the lighter prescription immediately;
users need not supply a reason. The app records the resulting session mode.
No wearable, sleep, food, pump, or soreness score is required by the core.

The control is available before working sets start. Changing a prescription
mid-session is outside this version. Selecting it does not mark a normal workout
as completed or change the long-term goal, baseline dose, or next planned session.

## Input and output contracts

The public API has an initializer, a pure session-preparation function, and one
pure completed-workout transition:

```ts
initializeProgram(config: ProgramConfig, rules: Ruleset,
  firstWorkout: { date: string; slotId: string }
): { state: ProgramState; workout: WorkoutPrescription }
prepareWorkout(input: { state: ProgramState; rules: Ruleset;
  easierToday?: boolean }): WorkoutPrescription
advanceProgram(input: AdvanceInput): AdvanceResult

type Goal = "fat_loss" | "size" | "strength" | "maintenance";
type Effort = "too_easy" | "on_target" | "too_hard" | "unknown";
type Load = {
  amount: string;                    // positive canonical decimal, e.g. "40"
  unit: "kg" | "lb";
  basis: "per_implement" | "total"; // no silent conversion or doubling
};
type Movement = {
  id: string;
  primaryMuscles: string[];
  secondaryMuscles: string[];         // disjoint from primary
  lowRepLoadingAllowed: boolean;
  automaticLoadProgressionAllowed: boolean;
  automaticRepRangeExtensionAllowed: boolean;
  minimumRir: number;                // >= 2; supplied restriction overrides preset
  availableLoads: Load[];            // unique ascending values, same unit/basis
};
type ProgramConfig = {
  programId: string;
  goal: Goal;
  daysPerWeek: 2 | 3;
  movements: Movement[];
  weeklySlots: { id: string; movementIds: string[] }[];
  requiredMuscleGroups: string[];    // supplied by the deferred plan builder
  initialLoads: Record<string, Load | null>;
};
type ExerciseState = {
  load: Load | null;
  mode: "baseline" | "normal" | "paused";
  normalSets: number;
  repFloor: number;
  repCeiling: number;
  ceilingStreak: number;
  strainStreak: number;
  lastCompletedDate: string | null;
  nextSetOverride: number | null;     // temporary dose; normalSets is unchanged
  interruptedReturn: boolean;
  recentComparable: Exposure[];     // at most 6, retains raw feedback
};
type ProgramState = {
  schemaVersion: 1;
  rulesetVersion: string;
  rulesetHash: string;
  config: ProgramConfig;
  revision: number;
  exercises: Record<string, ExerciseState>;
  lastSessionDate: string | null;    // ISO local calendar date
  activePrescription: WorkoutPrescription;
  processedEvents: Record<string, string>; // event ID -> canonical event hash
};
type ExerciseLog = {
  movementId: string;
  prescriptionId: string;
  status: "completed" | "partial" | "skipped" | "stopped";
  actualLoad: Load | null;
  actualSets: { reps: number }[];
  finalEffort: Effort;
  problem: "none" | "pain" | "control_lost";
};
type CompletedWorkout = {
  eventId: string;
  date: string;
  slotId: string;
  prescriptionId: string;
  plannedPrescriptionId: string;   // unmodified state.activePrescription.id
  sessionMode: "normal" | "easier"; // recorded by the app, not a daily question
  exercises: ExerciseLog[];
};
type AdvanceInput = {
  state: ProgramState;
  event: CompletedWorkout;
  rules: Ruleset;                    // immutable, versioned rules + source catalog
  nextSlotId: string;
  nextWorkoutDate: string;           // caller supplies it; no hidden clock
};
type SetPrescription = {
  repFloor: number;                  // monitoring threshold, not forced reps
  repCeiling: number;                // stop at or before this number
  effortInstruction: string;
};
type ExercisePrescription = {
  movementId: string;
  kind: "working" | "baseline_setup" | "paused";
  phase: "baseline" | "normal" | "easier" | "return";
  load: Load | null;
  sets: SetPrescription[];
  restSeconds: number;
  stopInstruction: string;
};
type WorkoutPrescription = {
  id: string;
  date: string;
  slotId: string;
  exercises: ExercisePrescription[];
};
type Decision = {
  movementId: string | null;          // null for a program-level decision
  action: "hold" | "increase_load" | "reduce_load" | "extend_rep_ceiling"
    | "recover" | "pause" | "baseline" | "notice";
  ruleIds: string[];
  sourceIds: string[];
  evidenceClass: "app_adaptation" | "software_requirement";
  explanationKey: string;           // localized copy outside the engine
  before: object;
  after: object;
};
type AdvanceResult =
  | { kind: "applied"; nextState: ProgramState;
      nextWorkout: WorkoutPrescription; decisions: Decision[] }
  | { kind: "no_op"; nextState: ProgramState; reason: "event_replayed" }
  | { kind: "rejected"; nextState: ProgramState; errors: string[] };
```

`Exposure` contains event/date, load, planned set count, rep floor/ceiling,
actual sets, effort, session mode, and problem. It also retains whether the
exposure was baseline, easier, or a return after interruption. `Ruleset` contains the
preset table, parameter table, rule/source records, and a canonical hash. These
are plain data, with no runtime-supplied arbitrary executable functions.

`activePrescription` is the next planned workout. Initialization emits the supplied
first workout; every applied transition sets `nextState.activePrescription` to
`nextWorkout`. `prepareWorkout` returns that prescription unchanged by default,
or derives an easier prescription without mutating persistent state. The event
retains both its planned ID and the ID of the prescription actually displayed.
Each exercise log references the latter. Temporary doses never rewrite the preset.

Unknown starting loads produce `baseline_setup`: choose a comfortable available
weight, use a normal effort-limited set, and confirm the actual load. No maximum
test or invented starting weight is required. A completed, clean exposure with
known load, every set at or above the floor, and known non-hard effort establishes
the baseline, provided no set exceeded the prescribed ceiling. All newly initialized movements begin in baseline mode, including
those with a supplied starting load. A clean baseline that is too hard keeps baseline mode and selects
the nearest lower available load if one exists. Unknown feedback requests the
missing observation. Baseline exposures do not count toward load progression.

The app supplies `Exposure` and `Ruleset` schemas during implementation from
these definitions. The initializer validates goal, slot coverage, load catalogs,
and restrictions, seeds counters at zero, and emits no performed history. Slots
must be unique, match the selected day count, and supply every required muscle
group in at least two distinct slots through a primary or secondary contribution,
except when an explicit fixed-profile coverage policy applies as described in
the selection addendum.
This coverage check does not claim that all contributing sets have equal stimulus.

## Validation and invariants

- The supplied ruleset version/hash must match the state. Configurations do not
  change silently inside workout processing.
- An event references the exact planned prescription and slot. Recompute the
  displayed prescription with `prepareWorkout` using the recorded session mode;
  the event and its exercise logs must match that derived prescription ID. A
  stale or unrecognized prescription, unknown movement, duplicate movement log,
  or mismatched load unit/basis rejects without changing state.
- Event dates strictly follow the last applied workout date. This version permits
  one workout daily. Validate replay before the date check: same ID/content is a
  no-op; same ID with different content is `event_id_conflict`.
- Actual reps are nonnegative integers. A completed exercise needs the expected
  number of sets and positive reps in each. Partial/stopped work may have fewer
  sets, but cannot have more; extra sets require a separate future contract.
- Reps above a ceiling remain recorded actuals, but are ineligible for upward
  progression. Hold and emit `rep_ceiling_exceeded`; never erase valid history.
- Every prescribed movement has a log, including an explicit skip. Missing rows
  reject finalization rather than assuming completion.
- Pain and control-loss reports must be processed even on skipped/partial rows.
- Only a confirmed available load can become current load. Changing load partway
  through an exercise is outside this contract and requires correction/splitting
  the log before finalization; it is not averaged or silently discarded.
- Counter comparisons require identical movement, load, normal set count,
  rep range, and effort instruction. Unknown/partial results reset confirmation
  counters in normal sessions; skips and easier sessions preserve counters
  without adding a comparable exposure, unless a problem or changed load resets them.
- No forced reps, failed repetitions, negative repetitions, or ROM reductions
  are prescribed to satisfy a rep target.
- Automatic upward steps use exact decimal arithmetic and never exceed 10%.
  Changing from per-implement to total load requires configuration, not arithmetic
  inference. An absence of progression permission is treated as permission denied.
- Safety, recovery, and missing evidence outrank load progression. Load and
  normal set count cannot both increase in one transition.
- Failed validation leaves all state and performed history unchanged. Applied
  events preserve original observations and increment revision once.

The transition performs no I/O, random sampling, external inference, or clock
reads. Canonical JSON serialization, deterministic ordering, and SHA-256 of the
prescription content provide stable IDs. The caller handles timezone conversion
before supplying ISO dates. Decimal load arithmetic and ordering are specified;
floating-point rounding must not turn a blocked step into an allowed one.

## Rule precedence and decision table

An exposure is **eligible** when completed, clean, normal-mode, and comparable,
with known effort and session mode `normal`. Eligibility does not certify the effort
estimate as a measurement. A rep-floor miss can still count toward strain.

After structural validation/replay handling, classify problems first. Recovery
cannot clear a paused movement. Then exclude easier-session work, evaluate
baseline and interruption rules, and finally movement progression. The first matching
movement rule wins. State updates are proposed in isolation and validated together
before returning an applied result.

| Rule | Condition | Exact action | Basis |
| --- | --- | --- | --- |
| R01 | Pain or loss of control on any row | Preserve actuals; pause that movement; reset both counters; prescribe no working sets for it. Resume requires an explicit safe configuration change. | Safety app policy; medical/rehabilitation management is outside this engine. |
| R02 | User selects the optional easier-workout control before working sets | `prepareWorkout` derives an easier prescription for the current session, leaves persistent state unchanged, and requires no readiness answer. | Explicit user preference; software behavior. |
| R03 | Preparing or recording an easier session | Use half preset sets rounded up (minimum 1), capped by any smaller current dose; same load; original preset rep floor as ceiling; monitoring floor 0; at least 4 clean reps left subject to stricter restrictions. No progression, strain, or plateau qualification. Preserve counters/window unless R01 or a confirmed changed load requires resetting them. | E12-informed app adaptation; exact single-session dose is an app choice. |
| R04 | Next planned workout after an easier session | Return to the existing planned prescription, preserving load, baseline/paused mode, and unresolved temporary-dose flags. No timer, readiness check, or mandatory extra return exposure. | Single-session scope; software requirement. |
| R05 | At least 28 days since that movement's last completed exposure, or interruption-return pending | On detecting the gap, reset counters/history window and mark interruption-return pending; prescribe one fewer working set (minimum 1), same load, and normal effort instruction next time. The resumed event is recorded but ineligible. After a clean complete known non-hard reduced-dose result, clear the flag/override and restore preset sets. Neither return exposure qualifies for progression. | Conservative interruption policy, exact timing is an app choice. |
| R06 | Unknown load or baseline mode | Apply the baseline procedure above; baseline completion sets mode `normal` and counters zero. No same-transition increase. | E01/E07-informed app calibration policy. |
| R07 | Normal-session skip, partial work, changed actual load, unknown effort, or ceiling exceeded | Hold load/range. Skip preserves counters; other cases reset counters. A confirmed changed actual load becomes a new baseline, with counters/window zero. Do not treat it as an approved increase. Ceiling excess emits its notice. | Data/uncertainty policy informed by E07. |
| R08 | Eligible result has `too_hard` effort or any set below rep floor | Clear ceiling streak; add 1 to strain streak. First strain holds. Second strain selects the nearest lower available load, returns to baseline, and resets counters. If none exists, prescribe one fewer set (minimum 1) for the next exposure as a temporary recovery dose. | App adaptation informed by effort/recovery principles, not a published exact two-miss formula. |
| R09 | Temporary one-set reduction from R08 | At a clean complete result with known non-hard effort, restore preset sets and baseline mode, resetting comparisons. A further strain while already at one set pauses the movement for review. | Bounded app adaptation; reductions never stack indefinitely. |
| R10 | Eligible non-strained result below ceiling on any set | Hold load and rep range; clear both streaks. Reps are governed by capacity and the stopping instruction, not a required weekly increment. | E01/E05 adaptation. |
| R11 | Every set reaches ceiling, final effort `on_target` or `too_easy`, eligible result | Clear strain streak; increment ceiling streak. First confirmation holds. At two confirmations, apply R12–R15 by goal and equipment. | Adaptation of E03, **not the literal 2-for-2 test**: no bonus/failure reps are performed. |
| R12 | Two confirmations; maintenance; final effort `on_target` | Hold load; reset ceiling streak. Stable capability is success. | E10-informed maintenance policy. |
| R13 | Two confirmations; building/cut goal, or maintenance with final `too_easy` | If automatic progression is allowed, choose the smallest available higher load. Increase only if its rise is <=10%. Restore original preset rep range, return to baseline, reset counters. | E02/E03 adaptation. Maintenance increases restore challenge rather than chase growth. |
| R14 | R13 finds no higher load, its smallest step exceeds 10%, or load progression is prohibited; rep-range extension is explicitly allowed | For size/cut/maintenance and strength's 8–12 fallback extend ceiling by 2, maximum 20; for low-rep strength extend by 2, maximum 8. Hold load, reset comparisons. Floor remains unchanged. | E05/E11 adaptation; exact +2/maxima are product choices. |
| R15 | R13 cannot progress and R14 is at maximum or prohibited | Hold load/range and emit `equipment_limit` or `progression_restricted`. Reset ceiling streak. Request a compatible equipment/movement solution from the deferred plan builder; never silently make a prohibited jump. | Software/safety boundary and app policy. |
| R16 | Six comparable clean normal on-target exposures in size/strength, no increase in latest-three versus first-three median total reps, and no recovery/problem/equipment notice already explains it | Add `plateau_check` notice while keeping the normal prescription. Do not diagnose absence of growth or add sets automatically. Cut/maintenance do not emit this notice merely for stable reps. | Trend heuristic; six exposures and median comparison are app choices. |

R16 is an informational overlay after the primary movement action, and cannot
override it. A successful load change clears its comparison window. A restriction
can permit R14 rep extensions but never R13 load increases; an explicit restriction
against any progression goes directly to R15. At baseline completion retain only
the verified current load and preset prescription; don't infer past adherence.

A completed log updates `lastCompletedDate` even if it is ineligible; partial and
skipped logs do not. Already-paused movements stay paused until explicit safe
reconfiguration. Their logs cannot silently restore work.

Normal effort instructions use at least `max(2, minimumRir)` clean reps left;
easier sessions use at least `max(4, minimumRir)`. Effort-category teaching copy follows
the active instruction when a restriction makes it easier than the default.
R08 sets `nextSetOverride`; R09 clears it. A reduced dose that remains strained
holds that dose for review rather than repeatedly subtracting sets. R05 uses the
same override with its interruption flag. Easier sessions retain these flags,
never satisfy their return conditions, and use the smaller current dose.

### Easier session preparation and completion

`prepareWorkout` checks the ruleset version/hash and derives from the exact
`activePrescription`. The normal path returns it unchanged. The easier path
applies R02/R03 only to unpaused working or baseline-setup movements. Paused
movements retain zero sets. Unknown loads remain unknown; the app can record a
comfortable available actual load, but an easier exposure cannot establish the
normal-effort baseline. Never increase a current rep ceiling or set count to
make an easier prescription. The easier ceiling is the smaller of the displayed
ceiling and original preset rep floor. Its phase is `easier`.

Generate the derived ID as SHA-256 of canonical JSON with keys
`plannedPrescriptionId`, `sessionMode`, `rulesetVersion`, `rulesetHash`, and
`prescription`. The last value is the resulting prescription excluding its own
ID. Repeated
preparation from identical inputs returns identical content/ID. The adapter saves
which prescription was displayed; preparation does not increment state revision,
consume an event ID, or create performed history.

On completion, R01 still wins over the easier-session rules. Easier work is
recorded as performed, but does not confirm a load increase, count a strain,
establish a baseline, resolve a temporary-dose return, or enter the plateau
window. A confirmed different actual load is retained as baseline mode with
counters/window reset; unknown actual loads never become inferred loads.
Completed easier work updates `lastCompletedDate`, because it was performed.

The next prescription restores the planned dose and effort subject to existing
movement restrictions and unresolved overrides. Its phase is `baseline`, `return`,
or `normal` as persistent state requires. Repeated easier requests each affect
one session; they do not create a hidden week or diagnose fatigue. Automatic
movement adjustments continue to use R08/R09's comparable normal-session reps
and effort. Version 0.2 has no automatic session-wide deload trigger.

### Configuration changes

Goal, schedule, movement, load-catalog, or safety-restriction changes are explicit
configuration events handled by a separate initialization/reconfiguration
boundary. Preserve performed history, rebuild affected presets, and reset affected
comparison counters and baseline status. Unaffected movements retain state.
Constraints may become stricter automatically; relaxing a medical/safety
restriction needs the appropriate external authorization. The workout transition
rejects unannounced configuration changes. Version migrations are explicit and
never reprocess historical events under new rules silently.

## Worked examples and expected outputs

The [companion examples](2026-10-05-general-fitness-progression-examples.json)
contain a complete shared input plus per-case overrides and expected projections
of state/prescription changes. Expand overrides by recursively merging objects;
arrays and scalars replace the shared value. Expected projections assert only
their supplied fields. They are design fixtures, not executed engine tests.
The following shorthand uses `40` as a consistent per-implement lb load and an
available `42` step unless specified. All unspecified feedback is complete,
clean, known, and in a normal session. The JSON explicitly supplies those defaults.

| Case | Input situation | Expected output |
| --- | --- | --- |
| C01 | Size, 3 sets, up to 12; actual 10/10/9, on target | Hold 40; continue 3 sets up to 12. No forced +1. |
| C02 | Same, actual 10/10/10, too easy | Hold 40; up to 12 remains allowed. User may perform more next time without waiting weeks. |
| C03 | 12/12/12, on target; ceiling streak 0 | Hold 40; ceiling streak 1. |
| C04 | Same at ceiling; ceiling streak 1 | Increase to 42 (+5%); baseline; 3 sets up to 12; counters reset. |
| C05 | 12/12/12, too hard; strain streak 0 | Hold; strain streak 1; no load increase. |
| C06 | Same with strain streak 1 | Reduce to available 38; baseline; counters reset. |
| C07 | 10/9/7, on target; strain streak 0 | The 7 misses the floor of 8; hold and count first strain. |
| C08 | Pain plus ceiling performance | Pause; no working sets. Ceiling performance cannot win. |
| C09 | Control lost plus too-easy feedback | Pause; conflicting effort feedback cannot clear the problem. |
| C10 | Partial 12/10 or unknown effort | Hold; reset confirmation counters; no inferred completion. |
| C11 | Explicit skip | Hold and preserve counters; add no performance exposure. |
| C12 | At second ceiling confirmation, only 40 and 50 available | Block +25%; extend ceiling 12 -> 14; reset counters. |
| C13 | Same equipment, already at ceiling 20 | Hold; equipment-limit notice; no prohibited load jump. |
| C14 | Maintenance, 2 sets 12/12, on target, streak 1 | Hold; reset ceiling streak; stable capability is success. |
| C15 | Maintenance, 12/12 too easy, streak 1 | Increase 40 -> 42 to restore challenge; baseline. |
| C16 | Strength, 6/6/6, streak 1 | Increase 40 -> 42; baseline; retain 4–6 range. |
| C17 | Optional easier control selected before training; size preset has 3 sets | Display 2 sets now, up to 8 reps with at least 4 left; same load 40; persistent state unchanged by preparation. |
| C18 | Easier session produces easy ceiling performance; prior confirmation streak 1 | Record the work; hold load and preserve streak 1; no increase or strain qualification. |
| C19 | Completed easier session, next workout planned | Restore 3 sets up to 12 with normal effort; no readiness check or extra return gate. |
| C20 | Same processed event ID and content | No-op; revision/history unchanged. |
| C21 | Same ID but changed reps | Reject event-ID conflict; state unchanged. |
| C22 | Wrong ruleset hash or stale prescription | Reject; state unchanged. |
| C23 | Starting load unknown; verified comfortable load 40 and clean 10/10/10 | Establish 40 baseline; normal mode; up to 12, counters zero. |
| C24 | Confirmed different actual load 38, clean complete work | Record actuals; rebaseline to 38; no claim of algorithm-approved increase. |
| C25 | Maintenance, 3 completed comparable sessions at stable 10/10 | Hold; no building-goal plateau notice. |
| C26 | Size, six on-target comparable totals 30/29/30/29/30/30 | Hold normal prescription; plateau-check notice because both medians are 30. |
| C27 | Size, same window with final total 33 and latest totals 31/32/33 | Hold normal prescription; no plateau notice because median increased. |
| C28 | Gap of 28 days since movement completion | Return dose 2 rather than 3 size sets, same load; counters/window reset. |
| C29 | Second strain at lowest available load 40 | Temporary reduction to 2 sets; no invented lighter load. |
| C30 | Size prescription generated for two available days | Four working sets per movement exposure, up to 12; 120-second rest. |

The JSON also supplies C31–C40 for unknown effort alone, stale prescriptions,
ceiling excess, exact 10% arithmetic boundaries, separate progression permissions,
easier-session pain, and restoration after temporary dose reductions. Additional
cases cover default normal behavior, easier-session strain exclusion, preserved
interruption flags, rejected mismatched derived IDs, and baseline exclusion.

C41–C47 contain those preparation and completion boundaries, including stricter
effort restrictions and paused movements. C17 and the preparation cases invoke
`prepareWorkout`; the remaining cases invoke `advanceProgram`. Preparation checks
assert that the input state is unchanged and the lighter prescription is returned
immediately, before a workout is recorded.

## Storage and integration

The adapter finalizes each workout once. It stores the original event, input
state/ruleset hashes, returned state, prescription, and decision trace in one
transaction with an event-ID uniqueness constraint and expected state revision.
Concurrent submissions retry from fresh state; they never overwrite later work.
Replaying the pure transition against the recorded inputs must reproduce the
prescription and decisions exactly.

Finalizing an ordinary valid workout authorizes the app's normal transition.
Users see the resulting next prescription, with a short explanation available on
demand. They do not approve every ordinary load increment. This proposed app
workflow is separate from Bob's existing Google Sheet's exact-approval workflow.

General exercise selection is deferred through a concrete interface. The initial
builder uses the frozen profile in the selection addendum. The plan builder
supplies movement identity, muscle roles, load catalog, safe progression
permissions, effort restrictions, and weekly slots. It consumes equipment-limit,
paused-movement, and plateau notices. The engine never selects a replacement by
inventing equipment or disregarding a restriction.

## Verification required before implementation completion

1. Convert the contracts into runtime schemas, including Exposure and Ruleset,
   and verify initialization, version changes, and all rejected input shapes.
2. Turn every worked example into a deterministic test using the frozen ruleset.
   Expected results must include the complete returned state, prescription, and
   trace, not only the projections supplied for human review here.
3. Test boundary values: 10% versus just above, 7 versus 8 reps, first versus
   second confirmation/strain, 27 versus 28 days, and easier-session set rounding.
4. Verify normal/default preparation, easier preparation and exact displayed-ID
   validation, problem precedence, preserved temporary-dose flags, and
   configuration changes. Easier work must not enter any comparison window.
5. Test identical-input replay, duplicate event no-op, altered duplicate rejection,
   canonical hashing, decimal arithmetic, and adapter transaction conflicts.
6. Check no missing/unknown input becomes a favorable observation; no problem
   can be overridden by a performance increase or an LLM explanation.
7. Audit all numerical policies against their stated sources/adaptation labels;
   require human review of the prescription policy before deploying to users.
8. Evaluate comprehension and burden with ordinary users: understanding of the
   stopping instruction, effort categories, and logging. Usability is not proven
   by physiological studies or passing software tests.

## Completion of this design artifact

The requested deliverable is the written contract, four presets, sourced rulebook,
and expected examples. Implementation and deployment need a separate approved
plan. This notebook is not a Git repository, so no commit is available here.
The evidence citations and precise app adaptations are present for review;
the proposed algorithm's efficacy and usability have not been experimentally
validated.
