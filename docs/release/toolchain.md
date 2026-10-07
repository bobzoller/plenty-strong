# Toolchain and reproducible checks

Candidate baseline: `564bc74900e98a40843356b7fa3b644284262320`. Local inventory read October 6, 2026: macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), Python 3.14.7. The package requires Swift tools 6.4. Deployment target iOS 18.0 is a compile setting, not minimum-runtime execution evidence.

`Makefile` exports a command-local `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and prepends its `usr/bin` to PATH. Global xcode-select remains untouched. The Python standard-library preflight checks the exact Xcode build/Swift version and requires one available simulator matching the selected destination and the gate’s required iOS major version; missing or ambiguous selections fail. It does not download runtimes, sign in or read credentials.

| Command | Required checks / default destination |
| --- | --- |
| `make test-core` | TrainingCore full Swift package suite |
| `make test-app` | All app unit and native UI tests; iPhone 17, iOS 27.0 |
| `make build-app` | Unsigned Release, generic iOS; no archive/signing |
| `make crash-proof` | Native macOS harness, four synthetic SIGKILL/reopen proofs |
| `make verify-current` | All four above and current preflight; explicitly current-only |
| `make verify` | Both destination preflights, current verification, all app tests on minimum iOS 18.0 |

Local current simulator: iPhone 17, iOS 27.0 (24A434), UDID `9468C341-5B70-40C7-8F40-29CC9CFD3FAA`. Name/OS are portable defaults; override `DESTINATION='platform=iOS Simulator,id=…'` for an exact local device. Minimum defaults to `platform=iOS Simulator,name=iPhone 16,OS=18.0`; after explicitly provisioning a compatible runtime, override `MINIMUM_DESTINATION` to an exact iOS 18 device. No iOS 18 runtime is installed here. `make verify` currently fails at that required preflight; a current-only success cannot close it. Check and record both actual destination versions before approving release. Do not change a destination to iOS 27 and describe it as minimum coverage.

`DEVELOPER_DIR`, `DESTINATION`, `MINIMUM_DESTINATION` and `DERIVED_DATA` can be overridden on the make command. Toolchain mismatches fail deliberately; update the pin only after equivalent clean-source verification. Checks use no signing/provisioning/backend/private Trainer input and force the test-only live-cloud opt-in flag to NO, even if inherited or passed to make. An authorized signed smoke uses the separately reviewed direct procedure. Debug cloud is inert; XCTest composition is synthetic, with Xcode-local StoreKit only when explicitly requested by tests. The shared launch scheme uses the synthetic `Tips.storekit` resource. Production resources do not include it.

## Hosted candidate and remaining gates

The [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [official image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), refreshed October 6, list `xcode-27` as public preview. The documented image is 20260928.0222.1 / macOS 27.0 (26A428), with Xcode 27.0 (27A266a) at `/Applications/Xcode_27.app` and iOS 27.0/iPhone 17. Its inventory does not list iOS 18. The label can change; it is not an immutable image pin.

The proposed workflow records actual image variables and asserts the toolchain/destination. The current job has a 120-minute ceiling for the full native suite (cold local model checks alone take more than 20 minutes; hosted timing is unverified) and runs the available checks; a separate required minimum job fails if iOS 18 is absent. Require **both** jobs before claiming the matrix. Read-only checkout uses [actions/checkout v4](https://github.com/actions/checkout/tree/11d5960a326750d5838078e36cf38b85af677262), with its primary public tag ref resolved October 6 to that exact SHA, and does not persist credentials. No workflow secrets, signing, account setup, `pull_request_target` or self-hosted runner are used.

Public developmental source is at [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong), from an audited new initial lineage. No hosted run, current-head check or status badge is claimed by this source-publication update. A trusted manual clean checkout may provide evidence for available checks, but cannot erase the missing minimum gate. Physical offline operation, real CloudKit/StoreKit, signing, archive validation, performance and distribution retain their separate acceptance gates.

## Retained diagnostics

Earlier successful native tests still reported an internal xcrun/simctl diagnostic-collection failure. With global xcode-select on CommandLineTools, a child lacking DEVELOPER_DIR reproduces that failure; the selected Xcode `usr/bin` on PATH repairs tool lookup. This is a local harness change, not a claim that every platform diagnostic is resolved. AppIntents extraction may report “no AppIntents.framework dependency found” because this app has no App Intents. Earlier invalid-frame observations and the unrooted eight-second local StoreKit interruption failure remain recorded for final review. Supporting all iPad orientations addresses the inherited multitasking build warning, not physical iPad layout coverage.

The fresh clean candidate's full current-only command actually failed at one native UI case (`testLargeTextOnboardingKeepsRestoreAndConfirmReachable`); its unchanged isolated rerun reproduced the failure. Video inspection showed whole-application swipes passing over Size between hittability probes at extreme text. The approved test-only route uses smaller native gestures within the Form viewport, preserving the original three-probe limit, extreme text, real goal tap and all Restore/Confirm assertions. Focused onboarding/About checks cover that correction; the original failed aggregate remains in the local report. The full failed run's diagnostic child then timed out after600 seconds despite working simctl lookup. Focused diagnostic collection was explicitly disabled for those scoped follow-ups; Make/CI defaults remain unchanged. Separate final-source crash proof, unsigned Release build and unsigned archive pass. No pristine-output or full minimum/current gate claim is made.

## Final fix build2 closed phases

Shipped source `ed276b05375ee903e3861396603ef4eb9953a53e`; tests-only source `85c4d4687460241145eb169e66181fc8f9268a4e`, clean before final UI execution. Plenty Strong0.1.0(2), Xcode27.0/Swift6.4, iPhone17/iOS27.0. Cross-root current safety admission, fresh staged-generation reservation, valid legacy read-only compatibility/export format retention, provider retry floor/owner handoff and stored-identity disclosure are covered by controlled RED/GREEN evidence.

| Phase / source | Actual closed outcome |
| --- | --- |
| One full default `make verify-current`, ed276b | FAILED native65/Make2,3888.086s. Core258 expanded PASS9.227s; models216 expanded PASS (55XCTest plus161Swift bodies; one liveDevelopment opt-in skipped); UI33/34, immediate Easier-label assertion failed during awaited save. Default diagnostics closed naturally; no process terminated. |
| Separate remaining components, clean ed276b | `make crash-proof build-app` exit0/46.575s: four macOS SIGKILL/reopen proofs and unsigned generic-iOS Release build pass. Not iOS kill evidence or a relabeled Make pass. |
| Narrow Easier test observation correction, ed276b+retained patch | Predicate waits exact Easier label within existing15s; every later actual-set/partial/Finish assertion retained. Focused1/1 PASS27.111s, nativeexit0; only this authorized focused phase uses diagnostics-never. |
| Clean tests-only85c4 full native UI | All34/34 PASS,0failed/0skipped, case total1031.475s/native command1443.765s/exit0, default diagnostics; only freshly reverified optional collector14750 SIGTERM under ruling81 at actual6:16, partial diagnostics retained (not natural600timeout). Eleven invalid-frame runtime warnings remain. Actual full Debug bundle bytes equal pre-run, including launcher/debug dylib. Shipped/core/model/crash/build/resource Git/blob/SHA inventories equal ed276b; retained component/archive proofs map only through that equality. |
| Actual required `make verify`, ed276b | FAILED exit2: minimum iOS18 destination absent. No substituted minimum proof. |

Fresh distinct unsigned archive `DerivedData/FinalFixBuild2/PlentyStrong-0.1.0-2-Unsigned.xcarchive`, nativeexit0/29.541s, inventorySHA256 `364341ad63afd87b013a310833a8d8cbe10d9afcb1e89515a163ee63c33ef418`, binaryUUID6EBD7848-957E-3320-83BB-4A515C610C35, binarySHA256 `3fdde7da1f27cc9a4c26b52e1547a86ea911279b8108833318523ca273f3c359`. Actual0.1.0(2), min18, proposed Production/provisioningNO, teamunset/signingNO; no profile/StoreKit configuration/third-party framework. Seven packaged JSON/privacy resources equal source; manifesttrackingfalse/empty arrays. This is local artifact preparation, not signed/live/release proof. The final UI Debug launcher/dylib are distinct from Release; exact source/phase/hash mappings and six fresh raw affected captures are in `candidate-artifacts.json` and `screenshots/manifest.json`.

Original build1 archives/failed commands/collector records below remain preserved historical evidence. The original build2 full Make also remains FAILED. Current local component coverage is phase-bound; minimum/hosted/physical/human/Release-performance/live/signing/privacy/publication gates remain open. Parent owns one scoped rereview before Bob decides local integration. Documentation changes do not alter executable/build identity.

## Source-publication addendum · October 7, 2026

Developmental source is published at [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong), from an audited new initial lineage; original private development ancestry and raw native evidence remain local. Retained dated publication-pending statements above describe the earlier local candidates. Source publication alone closes the public-source destination/payload gate. Original local-native execution identities and their open minimum/hosted/physical/human/performance/live/signing/privacy/distribution gates remain unchanged. No new native or hosted verification is claimed.
