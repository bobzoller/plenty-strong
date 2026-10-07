# TestFlight candidate notes

Unsubmitted local draft for Plenty Strong 0.1.0 (2). The local unsigned archive cannot be installed through TestFlight. No uploaded build, tester group, invitation or Apple review status exists. Fixed source/artifact identity and gate results are in `v1-checklist.md`.

## Beta description

Plenty Strong is a free, local strength workout log for a fixed dumbbell/home gym routine. Choose a goal, record your actual work and keep separate saved movement setups. History keeps original observations and saved next targets distinct. Optional consumable tips unlock nothing. Optional private iCloud recovery requires the separately validated provisioned build; unfinished drafts remain phone-local.

## What to test (after approved distribution)

Use synthetic records. Preserve/export them before uninstalling or changing device accounts. Do not send private workout records or actual receipts in feedback.

- Start a new routine or restore a supported lossless JSON file into an empty installation. Use a physical device in airplane mode; record date/device/OS/source/build and actual outcomes.
- Confirm the actual dumbbell load and log natural reps. Record unequal sides separately. Demonstrate pain/control stop, partial/skip, two good reps remaining and easier-workout boundaries with human comprehension and trainer review.
- Create/select/correct saved setup text. Demonstrate separate progression and shared base safety, retained original labels and actual 10/10/9 versus saved next ceiling 12. Changing a label does not calculate resistance.
- Reopen a local draft; export and restore through real Files providers. Verify exact original decisions/prescriptions/rules/actuals rather than regenerated targets. Human VoiceOver, large text, landscape/iPad and measured performance remain required.
- In the approved synthetic iCloud environment, test network/quota/authentication errors, device-account transitions, two-phone offline conflicts, missing dependencies and fresh replacement-device restore. Preserve current-account boundaries and all shared safety pauses. Development results do not prove Production recovery.
- Use Apple's sandbox with approved consumable products. Check unavailable/cancel/pending/unverified/duplicate/interrupted/relaunch/update flows; record training remains usable and unchanged. Do not purchase real products for an unapproved test.

Known local limits: minimum iOS 18 runtime absent; physical/service/signing/hosted and human gates are open. Native tab identifiers are not reliably exposed in this SDK; unique visible/hittable labels and content assertions provide actual navigation evidence. Retained invalid-frame and diagnostic-collection findings require broad review. There is no verified public support/privacy/security endpoint yet.

## Review and feedback fields

| Field | Proposed content / pending owner action |
| --- | --- |
| TestFlight beta description | Text above; revalidate against final provisioned build |
| What to Test | Synthetic scenarios above |
| Feedback email | BLOCKED: Bob supplies and approves monitored address privately |
| Review contact name/email/phone | BLOCKED: Bob provides approved App Store Connect contact |
| Demo login | Not required: no app account. Explain optional device iCloud/App Store sandbox requirements. |
| Review notes | Training is free. Consumable tips unlock nothing. Optional private iCloud recovery uses approved environment; explain exact final configuration and limitations. |
| Audience / groups / public link | BLOCKED: Bob approves exact recipients/group; no public link proposed |
| Build | BLOCKED: identify validated signed source/archive/build separately from current unsigned candidate |

[Apple's TestFlight information workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/) requires beta description and feedback contact for external testing. [TestFlight's overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) distinguishes build upload, tester invitation and possible beta review. Those are independent actions, none performed here. [Apple's TestFlight notice](https://testflight.apple.com/) describes tester information, usage, crashes and submitted feedback reaching developers; that beta service behavior is separate from the app's no-telemetry runtime.

Before upload, Bob approves the exact final signed candidate, environment, schema, products, metadata and tester audience. Deploy approved Production schema first for any Production build, then verify its real replacement recovery before offering it. Record Apple processing/review/availability readbacks; a successful upload alone is not an available beta. Follow-through remains in the repository-specific managed task with explicit authorization.

Any later fix or approved signing/provisioning configuration that changes the executable, configuration or assets requires a new committed source and incremented local build number, rebuilt artifacts and covering checks. Evidence-only documentation does not change the recorded 0.1.0 (2) unsigned candidate.
