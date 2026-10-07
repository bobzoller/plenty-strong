# Privacy/API/network release audit

Audit date: October 6, 2026. Baseline `564bc74900e98a40843356b7fa3b644284262320`; T2 candidate adds documentation, manifest and native/tool configuration, without changing data-path behavior.

## Actual source paths

| Surface | Current findings |
| --- | --- |
| Dependencies | Only local TrainingCore; no remote packages, third-party SDK or analytics/crash reporter. Production source imports native Apple frameworks. |
| Network | No URLSession, Network/socket API, HTTP endpoint, web/support Link or openURL path in app/core/feature/backup sources. CloudKit and StoreKit are the two optional native service adapters. |
| Training | SwiftData explicitly uses `cloudKitDatabase: .none`. Local archives preserve training bytes; portable JSON excludes account/system fields, engine cursors and commerce metadata. |
| Recovery | Explicit CKSyncEngine with `container.privateCloudDatabase`; no public/shared database or sharing/server adapter. Consent/root JSON is outside training history. Container `iCloud.us.zoller.PlentyStrong` is proposed, provisioning gate NO; Debug never constructs a real container. |
| Commerce | StoreKit product/purchase/updates/unfinished/finish, independent of training/recovery. Atomic Application Support/PlentyStrong-Commerce/receipts-v1.json stores transaction/product ID and status; not in portable/cloud training exports. Debug XCTest defaults inert unless local StoreKit is explicitly enabled. |
| Export/import | Native user-initiated ShareLink/fileImporter; security-scoped access to selected JSON. A chosen sharing destination can send data off-device. Staged-original evidence export is separate and read-only. |
| Diagnostics | No production print/NSLog/Logger/os_log or app telemetry endpoint. Apple/Xcode diagnostics are separate. Synthetic harness logs are test-only. |
| Entitlements | Proposed private CloudKit container plus APNs/remote-notification; app/test IDs use us.zoller namespace, no development team/credentials. These are source declarations, not provisioned/signed entitlement proof. |

## Manifest and required-reason audit

`Resources/PrivacyInfo.xcprivacy` is an app Copy Bundle Resources member. It declares tracking false, empty tracking domains, empty collected data types and empty accessed-API categories.

The [current Apple category dictionary](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [required-reason guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) were refreshed, including the primary DocC JSON tables rather than the shortened Markdown page. Exact covered API names/keys were matched against production source:

- File timestamps: no creationDate/modificationDate, UIDocument.fileModificationDate, contentModificationDateKey/creationDateKey or direct stat/fstat/lstat/getattrlist family call.
- System boot time: no systemUptime or mach_absolute_time. RestTimer uses Date deadlines; Task.sleep is a native concurrency API, not a direct covered boot-time call.
- Disk space: no available/total capacity keys, systemFreeSize/systemSize or statfs/statvfs family call.
- Active keyboards: no UITextInputMode.activeInputModes.
- User defaults: no UserDefaults/AppStorage/SceneStorage; recovery settings and commerce receipts are separate JSON files.

CloudRecordCodec reads `.fileSizeKey` through `URL.resourceValues` to reject oversized CKAsset content. That size key is **not** on Apple's current timestamp/category API list; broad wording for reason C617.1 does not itself make every file metadata operation a covered API. No category/reason was fabricated from that call. Foundation fileExists, Data reads/writes and Darwin open/flock/close are also not the listed covered app calls. The final binary check also looked for actual app-owned references; native OS frameworks' own internals are not evidence that our source accesses timestamp or defaults APIs. Re-audit when APIs/toolchain change and confirm with Apple's final archive validation.

## Collection definition and Apple services

[Apple's privacy details](https://developer.apple.com/app-store/app-privacy-details/) exclude exclusively on-device processing from collection and distinguish developer/partner collection from Apple's own collection. [Private CloudKit](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) allows user-only access by default and hides private records from the developer portal. The current private-only adapter has no developer server/sharing path; StoreKit receipts remain local. Together these actual paths support an empty developer-collection declaration for this candidate, not a blanket inference from “no telemetry.” Optional consent alone would not exempt a developer-accessible data path. Apple still processes cloud/purchase data; private CloudKit alone does not promise end-to-end encryption. See the user-facing [PRIVACY.md](../../PRIVACY.md).

## Evidence and pending release checks

Clean candidate app/resource/binary audit, unsigned archive inspection and the synthetic network-session observations are recorded below after execution. Local static/synthetic observations do not prove Apple production-service behavior, physical airplane mode or absence of traffic in every path. Real iCloud/StoreKit account sessions, signed archive validation/App Store privacy report, minimum iOS 18, verified support/source/privacy URLs and publication remain required gates. No public URL or hosted check is fabricated. Sensitive-marker scanning found no private-key/token patterns. Three inherited release/cloud documents contained real account-email references; T2 redacts them into role-only wording while retaining distinct iCloud/developer gates and historical no-live-action evidence. Development-smoke candidate/config wording is updated from the earlier namespace/no-entitlement statement to the current unprovisioned us.zoller source declarations. Fixtures remain synthetic; real account identifiers and receipts are excluded from the current candidate tree. This redaction does not rewrite BASE/ancestor history that contains those earlier email references. Before publishing a Git repository, review the actual history/metadata payload or approve a clean source snapshot; no history rewrite or publication occurred here.

### Executed local evidence

The clean detached synthetic candidate `f4a186136fb47bdaf9c1ce5197be39cbe650b0ab` has its own fresh build directories. Its Debug executable and app debug dylib were inspected with `xcrun nm -u` and `xcrun otool -L`: no app-owned covered API references or third-party libraries were found. Its app bundle contains the manifest with the four declared values, expected fixed-profile/ruleset resources, and no `Tips.storekit`; that configuration remains test/launch-scheme only. Built Info.plist confirms the proposed us.zoller bundle ID, compile minimum18, Development environment, provisioning NO and all four iPad orientations.

During actual synthetic native model tests on iPhone17/iOS27, 90 one-second process-scoped lsof observations had no socket rows. A separate 30-sample session retained stderr: no socket rows or tool errors. A temporary localhost-listener positive control was visible to lsof and then closed. Processes were selected from the candidate run's exact app PIDs and simulator UDID; no account/system traffic or packet payloads was collected. The first attempt filtered by build path rather than simulator installation path and captured zero observations; it supplies no network evidence. This sampling can miss short-lived sockets and Apple services in other processes, and is not a packet trace, physical offline check or authorized production cloud/purchase session.

The final unsigned archive and final-source follow-up findings are recorded separately below and in the local T2 report. A local unsigned archive is not a validated signed App Store archive or an Organizer privacy report.

The later clean source snapshot `2dda69c1f12f11db91fe2194e768acdbc9fbbe08` passed unsigned generic-iOS Release build and archive. Actual archived executable `nm -u`/`otool -L` contains no direct covered API references or third-party libraries; the archive has no embedded framework, provisioning profile or `.storekit` configuration. Its copied manifest exactly matches the source (SHA-256 `521eb6ef8430773e5c010e1838fe9dd8fa5d62b7b76d1cea8d7d8daadcb144e2`). Archived Info.plist has the proposed bundle ID, minimum18, Production environment, provisioning NO, remote-notification and all four iPad orientations. `codesign -dv` reports “code object is not signed at all,” as intended. This is archive-content evidence without signing, service execution, Organizer report or distribution validation. The later bounded UI-test route change does not alter production archive sources.

### T3 fixed-source artifact audit

Source `4e7e79513afd5a5b6964434e8528d63110d73e64` adds actual display/version/build and original icon catalog without production data-path changes. Its original unsigned artifact inventorySHA256 `cf02a26f96c637d258257f965a631ce0ae22b33407cefd3809828e611da87b55` remains preserved locally. Test-only source9ce has a separate inventorySHA256 `f963883ff999e5279f83453887136089b9702a51599067071112b07318802673`. Final clean source `c31657ed90ad59148f7e633c3fef3b533a6cf3dc` changes only bounded UI-test routes after 4e; Git blob inventories confirm all shipped source/config/assets, TrainingCore and model/crash tests are byte-identical.

That the final source has its own fresh unsigned Release archive `DerivedDataT3Final2/PlentyStrong-0.1.0-1-Unsigned.xcarchive`, inventorySHA256 `d2e3ffcd80a13bef5939a134c45bf627f61747fff1aa75caa138986e6f20dc06`, arm64 binaryUUID `116FB6EC-9B1F-3802-BFFB-290B12C42404`. Native `nm -u`/`otool -L` inspection finds only Apple dependencies and no direct covered required-reason API references. The actual bundle contains no third-party framework, provisioning profile or StoreKit test configuration; its manifest bytes equal current source and retain the four declared values above.

Compiled Info confirms Plenty Strong 0.1.0 (1), minimum iOS 18, Production/provisioningNO and AppIcon/Assets.car. Actual effective settings have no developer team and signingNO. `codesign -dv` exits1, code object not signed at all. These are source-bound local observations, not signed entitlements, Organizer privacy validation or real Apple service proof. Original full current aggregate remains failed; later final UI-route evidence is separate and minimum iOS 18 remains absent. See `v1-checklist.md` and `candidate-artifacts.json`. T2 process-scoped sampling remains prior-source evidence only; no new network sampling or live account session is claimed for T3. Privacy answers remain proposed pending signed artifact validation and genuine support/privacy destinations.

### Final fix build2 artifact audit

Clean shipped source `ed276b05375ee903e3861396603ef4eb9953a53e` has a fresh distinct0.1.0(2) unsigned archive, inventorySHA256 `364341ad63afd87b013a310833a8d8cbe10d9afcb1e89515a163ee63c33ef418`/arm64UUID6EBD7848-957E-3320-83BB-4A515C610C35. Actual copied privacy and frozen JSON bytes match source, manifesttrackingfalse with empty trackingdomains/collected/accessed arrays. Native dependencies/symbol/catalog/plist inspection retained; no third-party framework/profile/StoreKit config, teamunset/signingNO, Production/provisioningNO. Debug remains Development/provisioningNO. Tests-only source `85c4d4687460241145eb169e66181fc8f9268a4e` changes only bounded Easier UI observation; exact source/resource and actual bundle equality maps archive/build proofs. No new network sample, actual account/service, Organizer privacy or signed entitlement validation is claimed. All historical artifacts/failures remain preserved, and source/authorship/history/contact/publication/live/privacy gates are unwaived. See `candidate-artifacts.json`/`v1-checklist.md`.

## Source-publication addendum · October 7, 2026

Developmental source is published at [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong), from an audited new initial lineage; original private development ancestry and raw native evidence remain local. Retained dated publication-pending statements above describe the earlier local candidates. Source publication alone closes the public-source destination/payload gate. Original local-native execution identities and their open minimum/hosted/physical/human/performance/live/signing/privacy/distribution gates remain unchanged. No new native or hosted verification is claimed.
