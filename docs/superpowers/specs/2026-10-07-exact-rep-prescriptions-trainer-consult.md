**To: Tech Lead / Bob**  
**Subject: Recommended exact-rep prescription policy for Plenty Strong**

I recommend **exact per-set goals with conditional double progression**, using the latest comparable performance to preserve the person’s set-by-set pattern and several exposures to confirm load changes or setbacks.

The app should prescribe an achievable attempt, not promise improvement. **Effort, pain, and control always override the number.**

Research supports broader progression principles. I did not find comparative validation establishing that latest-session vectors, rolling medians, or total-rep redistribution produce the best next-session forecasts. The precise rules below are **proposed product rules**, and the combined algorithm has not been validated.

**1. What the evidence supports**

| Evidence class | Finding or recommendation | Population and limitations |
|---|---|---|
| Research synthesis and professional guidance | Regular resistance training with sufficient effort improves strength and muscle size. Failure is not compulsory; ACSM discusses roughly 2–3 RIR as a practical way to achieve sufficient effort. | ACSM’s 2026 overview covers healthy adults, predominantly inexperienced trainees. Its defined-disease exclusions limit clinical generalization. It provides no exact rep-vector forecasting algorithm. [ACSM 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC12965823/) |
| Research finding | Increasing repetitions and increasing load were both viable progression strategies. | Eight weeks, 43 trained adults, lower-body exercises, supervised failure training. This does not validate our stopping instruction or integer increments. [Plotkin et al., 2022](https://pubmed.ncbi.nlm.nih.gov/36199287/) |
| Research finding | Failure and 1–2 RIR produced similar measured quadriceps growth, with greater acute fatigue from failure. | Eighteen trained adults, eight weeks, leg press and leg extension. It does not establish the optimum for every movement or novice. [Refalo et al., 2024](https://pubmed.ncbi.nlm.nih.gov/38393985/) |
| Research synthesis | Estimates of remaining repetitions contain error. | Exercise and assessment methods vary. Treat feedback as an estimate, not a precise capacity measurement. [Halperin et al.](https://pubmed.ncbi.nlm.nih.gov/34542869/) |
| Published programming recommendation | ACSM’s older guidance recommends increasing load approximately 2–10% after exceeding the desired repetitions by one or two. NASM describes two additional final-set reps on two consecutive workouts. | These are published recommendations, not validation of capped-rep confirmations or our combined policy. [ACSM 2009](https://pubmed.ncbi.nlm.nih.gov/19204579/), [NASM](https://www.nasm.org/resource-center/blog/training/progressive-overload-explained-programming-progress-for-every-client) |

Double progression is the **coaching framework**. The increments, confirmation counts, reset rules, and forecasting method are **exact product choices**.

**2. Define what an exact goal means**

Recommended user copy:

> **Aim for the listed reps. Stop at that number, or sooner when another good rep would leave fewer than about two reps in reserve. Stop earlier for pain or loss of control.**

A stricter movement restriction overrides the default reserve.

At the goal with substantial reserve, the user stops and reports “too easy.” The engine adjusts the next prescription. Do not also instruct users to continue until reaching the effort target: that would make the numerical goal ambiguous.

Stopping before the goal to preserve effort or control is correct execution. Record the actual result independently; do not label every shortfall a failed workout.

Keep exercise-level feedback, but change its scope from **the final set** to **all working sets**:

| Response | Meaning |
|---|---|
| Too easy | Every set left substantially more reserve than intended. |
| About right | Appropriately challenging; no set became too hard. |
| Too hard | At least one set reached the limit or could not preserve the intended reserve. |
| Unknown | The user cannot judge, or feedback is missing. |

This remains one question. Per-set RIR would improve information, but I would not require it for this audience.

When a goal is missed, one conditional reason is useful: **effort limit**, **time/interruption**, or **other/unknown**. Otherwise, the engine cannot distinguish a correctly stopped set from an unfinished one. Pain and control loss remain separate flags.

**3. Generate targets from per-set performance, with confirmation around uncertainty**

Persist both:

- `P`: the previous prescribed vector.
- `A`: the actual vector.

Actuals alone are insufficient. Actual **10/10/9** means something different after a goal of **10/10/9** versus **12/12/12**.

Use the latest comparable complete exposure for the observed set pattern. Use short histories for confirmation and trend detection. Do not average unlike loads or redistribute total reps equally across sets.

Comparable exposures require the same movement variant/setup, actual load and basis, normal set count, effort policy, rest prescription, movement position, and rep-range policy. **Changing the numerical goals alone does not break comparability.**

For normal, complete, controlled work without problems, apply these proposed rules:

| Condition | Next prescription at the same load |
|---|---|
| All goals met; about right; size/strength/fat loss | Add **one total rep** to `A`, choosing the set with the lowest reps below the ceiling. Break ties by earliest set. |
| All goals met; too easy | Add **two reps per set**, capped at the current ceiling. |
| First too-hard exposure | Reduce goals to `max(1, Aᵢ − 1)`, capped at the ceiling. |
| Second consecutive comparable strain | Reduce load to the nearest available lower load and re-establish a baseline. |
| Effort-limited shortfall; about right; first occurrence | Repeat `P`. |
| Second consecutive effort-limited shortfall | Rebase goals to `A`, without an additional rep increment. |
| Unknown effort | Repeat `P`; no upward change or confirmation. |
| Missed goal plus “too easy” | Repeat `P` and clarify the observation; do not infer capacity. |
| Maintenance; goals met; about right | Repeat `P` and load. |

Examples of the one-total-rep rule:

```text
10/10/9  → 10/10/10
10/10/10 → 11/10/10
11/10/10 → 11/11/10
```

These increments are **bounded attempts**, not forecasts that the user can definitely perform them. The stopping instruction remains active.

The larger “too easy” step addresses obvious underdosing without imposing a one-rep-per-week limit. Its exact size is a product choice.

For baseline fitting, use the achieved vector **without a progression bonus**. Establish capacity before advancing it.

**4. Load progression, setbacks, and plateaus**

I would retain **two ceiling confirmations** as a conservative product default, with revised qualification:

- Every working set reaches the ceiling.
- Feedback is known and non-hard.
- Work is complete, controlled, normal-mode, and comparable.
- Baseline, return, easier, partial, unknown, or above-goal work cannot supply confirmation.

For size, strength, and fat loss, the second confirmation permits a load increase. For maintenance, require **two too-easy ceiling exposures**; about-right performance holds.

This is an adaptation of published confirmation guidance, **not the literal 2-for-2 rule**. One confirmation would respond faster; two reduces sensitivity to noisy observations. Research does not determine which count is best for this app.

Choose the smallest available permitted higher load. Retaining the existing **10% maximum automatic increase** is defensible as a conservative product guardrail. It is not a biological threshold proving that larger jumps are unsafe.

After increasing load:

- Reset comparisons.
- Enter baseline fitting.
- Prescribe the preset’s starting reps: for example, **8/8/8**, or **4/4/4** for low-rep strength.
- Learn the new set pattern from actual performance. Do not infer exact repetitions from a generic rep-to-1RM equation.
- Do not increase working sets simultaneously.

Revise the current “any set below the rep floor counts as strain” rule. **Later-set fatigue is expected.** A result of 8/7/6 at appropriate effort does not automatically establish excessive loading.

Use repeated **first-set** floor misses as a load-suitability signal. Allow later-set targets below the nominal floor, with a minimum of one. The floor remains a fitting threshold, never an instruction to grind.

After two comparable strains, reduce load. If no manageable lower load exists, emit a setup-limit decision requiring a manageable load or variant; do not continue an indefinite rep-reduction loop. Reducing sets can address accumulated fatigue, but cannot fix excessive first-set resistance.

Retain the six-exposure plateau notice as a **nonblocking coaching heuristic** for size and strength. Total-rep trends can inform it, but do not prove absent muscle growth. A plateau notice should not automatically add sets, force failure, or increase targets despite misses.

**5. Different goals and equipment**

Retain the existing preset structure initially:

| Goal | Proposed progression behavior |
|---|---|
| Fat loss | Conditional progression remains available. Stable performance is also success. Do not add volume merely because progress slows. |
| Size | Conditional rep progression, then load progression; existing higher-volume preset. |
| Strength | Same transition logic, with lower rep targets where appropriate, heavier loading, and longer rest. |
| Maintenance | Hold appropriately challenging prescriptions. Advance only to restore challenge when work becomes too easy. |

Higher loads generally favor strength, while multiple sets support hypertrophy. These findings do not identify an exact individual preset. [Currier et al., 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10579494/)

Energy deficits constrain lean-mass gains more consistently than strength gains; they do not establish a universal cut-specific rep increment or justify automatically reducing everyone to minimum volume. [Murphy and Koehler, 2022](https://pubmed.ncbi.nlm.nih.gov/34623696/)

Reduced training doses can maintain adaptations, but age and prior training matter. Avoid claiming one maintenance dose works for everyone. [Bickel et al., 2011](https://pubmed.ncbi.nlm.nih.gov/21131862/)

Keep the approximately-two-reps-left instruction across goals. There is insufficient justification to require failure for the size preset.

For large dumbbell increments, retain the existing permitted rep-range extension:

- Extend the ceiling by two when a confirmed load increase is unavailable.
- Maximum 20 for ordinary hypertrophy/general-fitness work; maximum 8 for low-rep strength.
- Generate the new exact vector using the effort rule under the expanded ceiling.
- At the limit, hold and emit an equipment-limit notice.

These maxima are product choices. Higher-rep work can remain productive, but is not an equivalent substitute for heavier-load strength training.

For bodyweight movements:

- Numeric load remains absent.
- Progress reps within the same saved variant.
- Do not invent effective resistance or automatically alter assistance.
- A changed band, leverage, ROM, or added-weight setup must create a distinct variant/setup identity.
- At the rep limit, request a suitable variant through the selection boundary.

Same-variant comparisons are useful but imperfect: body mass and untracked assistance can change.

**6. Starting, restarting, and changing sets**

**No history:** prescribe the preset’s starting reps at a confirmed starting load, in baseline mode. With no confirmed starting load, output those reps with `baseline_setup` and load pending. One guided comfortable-load selection is unavoidable; an equipment catalog cannot reveal the person’s strength.

**After increasing load:** start at the preset floor, then retain the achieved fatigue pattern after a clean fitting exposure. For example, an appropriate **8/7/6** result becomes **8/7/6**, not an invented 8/8/8 capacity estimate.

**After a long interruption:** retain 28 days as a clearly labeled product threshold. My proposed return prescription is:

- One fewer set, minimum one.
- At least four reps left.
- Goals equal to the smaller of the retained targets and preset floor.
- For loaded work, the highest available load no greater than 90% of the previous load.
- At minimum equipment load, retain it and rely on earlier stopping.
- For bodyweight, retain the selected variant.

After a clean non-hard return, restore normal sets in baseline fitting mode at the returned load. Return work supplies no progression confirmation. Neither 28 days nor 90% is a scientifically established universal boundary.

Use the last suitable normal exposure or successful calibration for this clock. Easier sessions should not indefinitely renew old normal-performance evidence.

**Changed normal set count:** reset comparisons. If removing sets, retain the vector’s prefix. If adding sets, retain existing goals and append `max(1, lastGoal − 1)` for each new set, in baseline fitting mode. This provisional fatigue adjustment is a heuristic, not a validated decay model. Never increase load simultaneously.

**7. Incomplete or conflicting observations**

| Observation | Required behavior |
|---|---|
| Pain/control loss, including partial or easier work | Pause the affected movement; no working-set prescription until explicitly resolved. |
| Partial/time-limited exercise | Preserve actuals; retain normal goals/load; no confirmation. |
| Skipped set | Record skipped status. Missing is not zero reps or a failed attempt. |
| Unknown effort | Hold goals/load; clear confirmation counters. |
| Unequal left/right reps | Preserve both observations; no upward qualification. Never sum or average away the difference. |
| Changed actual load | Preserve it. Reset comparisons and treat the confirmed available load as a new baseline, not an engine-approved increase. |
| Mixed loads across sets | Require per-set load data or mark noncomparable. Do not average loads. |
| All goals met, some exceeded, clean known non-hard work within ceiling | Adopt the achieved vector without a bonus or load confirmation. |
| Above the hard ceiling | Preserve actuals; hold prior goals and flag review. Safety/too-hard rules still take precedence. |
| Optional easier workout | Preserve the normal prescription independently; exclude easier results from progression, strain, and plateau comparisons. |

For per-side movements, a single number must explicitly mean completed reps **on each side**. If unequal sides cannot be represented, add an unequal/partial flag and preserve the underlying entries.

For an easier workout, retain the existing half-sets-rounded-up policy, capped by any smaller current dose. Prescribe `min(normalTargetᵢ, presetFloor)` with at least four reps left. Restore the saved normal prescription afterward.

Skips and easier sessions can freeze counters; partial/unknown normal work should reset confirmations. All evidence remains subject to expiry after an interruption.

**8. Worked examples**

Unless specified: size goal, three sets, range 8–12, complete controlled normal work, no pain, and **both prior goal and actual performance are 10/10/9**. Loads are per hand.

| Situation | Exact next prescription |
|---|---|
| 40 lb, 10/10/9, about right | **40 lb: 10/10/10** |
| 40 lb, 10/10/9, too easy across all sets | **40 lb: 12/12/11** |
| 40 lb, 10/10/9, first too-hard exposure | **40 lb: 9/9/8** |
| Then 9/9/8 too hard again; 35 available | **35 lb: 8/8/8**, baseline |
| Prior goal 10/10/10; actual 10/10/9, first effort-limited shortfall | **40 lb: 10/10/10**, repeat |
| Same shortfall twice consecutively | **40 lb: 10/10/9**, rebase |
| 50 lb, goal/actual 12/12/12, about right, first ceiling confirmation | **50 lb: 12/12/12** |
| Same, second confirmation; 55 available | **55 lb: 8/8/8**, baseline |
| 40 lb, second ceiling confirmation; next weight 45 exceeds 10% | **40 lb: 13/12/12**, ceiling extended to 14 |
| No history; starting load confirmed as 20 | **20 lb: 8/8/8**, baseline |
| New-load baseline produces 8/7/6, about right | **Same new load: 8/7/6**, no bonus |
| Same bodyweight variant, goal/actual 10/10/9, about right | **Same variant: 10/10/10**, no numeric load |
| Maintenance, two sets, 40 lb, 10/10 about right | **40 lb: 10/10** |
| Easier request; normal prescription 40 lb, 10/10/9 | **Today: 40 lb, 8/8, 4+ reserve. Next normal: 10/10/9** |
| Time-limited partial actual 10/10 | **40 lb: retain 10/10/9**, no confirmation |
| Goal 10/10/9; actual 11/11/10, clean/about right | **40 lb: 11/11/10**, no bonus/confirmation |
| Strength, 50 lb, 6/6/6, second ceiling confirmation; 55 available | **55 lb: 4/4/4**, baseline |
| 28-day interruption; retained 50 lb, 10/10/9; 45 available | **Return: 45 lb, 8/8, 4+ reserve**, then normal baseline |
| Explicit change from three to four sets | **40 lb: 10/10/9/8**, baseline fitting |

**9. Alternatives and implementation**

The recommended approach balances responsiveness with conservative load changes.

Two reasonable alternatives:

- **Add one rep to every set after successful on-target work:** simpler and faster, but increases demand across all sets simultaneously.
- **Use rolling set-wise medians:** smoother under noisy performance, but slower to recognize genuine improvement or the latest fatigue pattern.

Neither has established forecasting superiority. I would avoid unconditional calendar increments and assuming different distributions of the same total reps are interchangeable.

Keep the engine as a pure, versioned transition:

```text
advanceProgram(state, completedWorkout, ruleset, nextWorkoutDate)
  → nextState, exactPrescription, decisions
```

Add exact `targetReps` to each set while retaining the internal floor/ceiling policy. Persist raw actuals, prior goals, session mode, baseline status, comparison counters, ruleset version/hash, reason IDs, and evidence classification separately.

An LLM can explain decisions. The authoritative prescription should come from deterministic code that runs offline.

Label the combined policy **evidence-informed**, with its exact numerical rules identified as product choices. Use the examples above as regression fixtures after specification review.

This consultation does not change Bob’s personal training program.