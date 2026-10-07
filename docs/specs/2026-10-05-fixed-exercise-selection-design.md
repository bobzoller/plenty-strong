---
date: 2026-10-05
status: fixed-profile-requested; contract-extension-proposed
profile: fixed-home-gym-v0.1
base_ruleset: general-fitness-v0.2
---

# Fixed Exercise Selection Stub

The starter app always selects the same home-gym equipment, movements, and
Sunday/Tuesday/Thursday split. The user selects a goal; the goal preset supplies
working sets, rep ranges, effort, and rest. Equipment and exercise customization
are deferred. This addendum extends the [progression specification](2026-10-05-general-fitness-progression-design.md)
so the fixed profile can represent its actual movements.

The [hardcoded profile](2026-10-05-fixed-exercise-profile.json) is machine-readable
design data for the eventual program-builder stub. Its requested values come
from Bob's equipment message and the routine verified in his workout log on
October 5. Metadata and contract rules below are explicit app design choices.
This profile is a chosen starter routine, not a research-established optimal split.

## Equipment

- A pair of adjustable dumbbells: **5, 10, 15, …, 80 lb per dumbbell**.
- A pull-up bar.
- An adjustable bench.

The existing bent-knee hanging leg raise uses ab straps. Preserve that setup as
a movement requirement; the equipment message did not independently confirm
the accessory. Assistance, bands, and changes to assistance remain user-managed
outside the app. There is no band selector, assistance measurement, or imported
`160` setting in the profile.

## Fixed weekly routine

| Order | Sunday | Tuesday | Thursday |
| --- | --- | --- | --- |
| 1 | Incline DB Press 24° | Suitcase DB Squat | Incline DB Press 24° |
| 2 | Pull-ups, user-managed assistance | DB Romanian Deadlift | Chin-ups, user-managed assistance |
| 3 | Chest-Supported DB Row 38° neutral | Bulgarian Split Squat | Chest-Supported DB Row 38° neutral |
| 4 | DB Lateral Raise | Bent-Knee Hanging Leg Raise, ab straps | DB Lateral Raise |
| 5 | Lying DB Curls | Cross-Body Hammer Curl | DB Triceps Extension |

There are 12 unique movement IDs and 15 scheduled appearances. Press, row, and
lateral-raise state is shared across Sunday and Thursday. Pull-ups and chin-ups
remain separate movements. A working set for split squats and alternating curls
includes both sides; the logged rep count is per side, not the sum of both sides.
Unequal or unfinished side work is partial, and cannot qualify for progression.

All goals use this three-day schedule, including maintenance. The maintenance
preset still supplies two sets; its general two-day default is overridden by
this explicitly selected profile. Two-day selection is deferred. A missed day
does not become a completed session or silently move the exercise to another day.
Use the next future Sunday, Tuesday, or Thursday slot on the calendar supplied
by the adapter; do not run missed sessions back to back automatically.

## Program builder boundary

```ts
selectFixedProgram(goal: Goal): FixedProgramConfig

type LoadingMode = "external_load" | "bodyweight" | "user_managed_assistance";
type FixedMovement = Movement & {
  loadingMode: LoadingMode;
  implementCount: 0 | 1 | 2;
  repCounting: "total" | "per_side";
  setupRevision: number; // positive integer; explicit setup changes reset comparisons
};
type FixedProgramConfig = Omit<ProgramConfig, "movements" | "weeklySlots"> & {
  profileId: "fixed-home-gym-v0.1";
  daysPerWeek: 3;
  coveragePolicy: "fixed_profile";
  movements: FixedMovement[];
  weeklySlots: { id: "SUN" | "TUE" | "THU";
    weekday: 0 | 2 | 4; movementIds: string[] }[];
};
```

The stub resolves the JSON profile into these fields, validates the supplied
goal, and returns fresh data with the exact movement order. It expands the
dumbbell catalog into each loaded movement's `availableLoads`, preserving that
movement's load basis. It does not inspect history or infer starting weights.
Every `initialLoads` entry is null; initialization obtains a verified baseline.
Performances and equipment definitions remain separate.

`profileId` identifies the fixed definition; its content hash must be retained
with the program and ruleset. Exercise muscle roles are coarse bookkeeping
metadata, not measured stimulus. Numeric-only prior fixtures use
`loadingMode: external_load` by default; the new profile supplies it explicitly.
The implementation must version this extension and its hash together with the
base rules, rather than silently changing an existing program's interpretation.

## Load representation and rule extensions

| Movement type | Prescribed and actual load | Load progression |
| --- | --- | --- |
| Two-dumbbell movement | Pounds per hand, `basis: per_implement`; e.g. 40 means one 40 lb dumbbell in each hand | Select from 5–80 in 5 lb steps; retain the base 10% limit. |
| DB triceps extension | One dumbbell held with both hands, `basis: total`; e.g. 35 means one 35 lb implement | Same catalog and limit; do not double it. |
| Hanging leg raise | `load: null`, `actualLoad: null`, `loadingMode: bodyweight` | No automatic added load, longer lever, ROM change, or extra equipment. |
| Pull-up or chin-up | `load: null`, `actualLoad: null`, `loadingMode: user_managed_assistance` | Assistance changes are outside the app; do not estimate effective load. |

These extensions are normative when consuming this profile:

1. **Validate by loading mode.** An external-load movement requires a known
   available load for baseline completion. Bodyweight and assistance-managed
   movements require null numeric load and an empty load catalog. Null is valid
   for those modes; it must never mean zero resistance or fabricated kilograms.
2. **R06 baseline establishment.** All movements still start in baseline mode.
   Clean completed normal-effort work meeting the prescribed range can establish
   a bodyweight/manual baseline without numeric load. Easier work cannot establish
   any normal-effort baseline. Unknown effort and partial work do not qualify.
3. **R13/R14/R15 progression.** Automatic load progression is disabled for all
   three non-dumbbell movements. Rep-ceiling progression remains enabled using
   the base +2/max-20 rule. At the ceiling boundary emit `manual_setup_limit`
   for those modes; the user may change assistance outside the app. Never
   silently select weighted pull-ups or a harder leg-raise variation.
4. **R08/R09 setbacks.** There is no numeric lower-load candidate for these
   modes. Use the existing temporary-set reduction and review path. Do not
   invent a band change or call an assistance change a load reduction.
5. **Comparison context.** Movement identity, loading mode, setup revision,
   rep convention, dose, and effort instruction must match. Record a movement
   `setupRevision` integer, initially 1, in configuration and exposures. An
   explicit outside-app setup reset increments it, clears comparisons, and
   requires a new baseline. The app does not detect an unreported assistance
   change; such a change makes the old comparisons unreliable. No assistance
   quantity or new recurring question is introduced.
6. **Coverage.** This profile uses `coveragePolicy: fixed_profile`. Validate
   its three slots, movement identities, and muscle metadata against the frozen
   profile. Preserve its actual once-weekly lower-body/trunk schedule rather
   than reject it under the general twice-weekly coverage requirement. Report
   actual exposure counts; do not claim this split meets twice-weekly coverage
   for every muscle. Other profiles retain their own explicit coverage policy.

The triceps implement count is a setup assumption based on the logged single
dumbbell load convention; record an explicit setup reset if a different variation
is used. Rep counting metadata is also an app convention, not a copied measurement.

## Goal presets and fixed metadata

The base goal presets govern all movements. For the strength goal, low-rep loading
is enabled for press, supported row, suitcase squat, and Romanian deadlift.
The other movements use the preset's 8–12 fallback. This is conservative starter
metadata for the app, not a claim that curls or split squats cannot be trained
with fewer repetitions. No extra exercise-specific settings panel is required.

The equipment catalog does not authorize a jump larger than the base rule allows:
40 → 45 is 12.5%, so use the rep-ceiling fallback; 50 → 55 is 10%, so it can
qualify. A smaller movement such as a 15 lb lateral raise may reach the rep cap
without an allowed load increase. Retain the equipment-limit notice instead of
inventing microplates, assuming 2.5 lb steps, or overriding the cap. Revisiting
that progression policy is separate from hardcoding the requested equipment.

## Expected examples

The JSON includes acceptance examples for the selection boundary and these
loading extensions. They are specified expectations for future implementation
tests, not executed results from a training engine.

- Each goal returns three weekdays, five movements per slot, and shared state
  for repeated IDs. Maintenance uses two sets at each scheduled appearance.
- The dumbbell catalog contains exactly 16 weights with per-movement load basis.
- A clean normal bodyweight/manual exposure can establish baseline with null load;
  easier or partial work cannot.
- Two qualifying rep-ceiling exposures can extend an assistance-managed movement's
  ceiling without changing numeric load or assistance.
- Easier preparation preserves null loads and pauses; it never adds equipment.
- An explicit setup revision clears comparisons instead of inheriting a prior
  assistance-dependent qualification streak.
- Per-side movements qualify only after both sides complete the logged count.
- Lower-body/trunk once-weekly coverage is preserved and reported literally.

## Scope

This defines the fixed selector's data and its integration contract. A general
exercise library, equipment-driven substitution, band-force modeling, exercise
ranking, and app execution remain separate work. The [dated decision](../../../consultations/2026-10-05-fixed-exercise-selection-stub.md)
records the user instruction and live read provenance.
