# Plenty Strong Private iCloud Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover finalized training history and its exact progression state on a replacement iPhone signed into the same Apple account, while preserving local training when cloud service is unavailable or the account changes.

**Architecture:** Keep the offline plan's local-only repository authoritative. A CKSyncEngine transport uploads immutable journal envelopes and frozen rule/profile archives from a durable outbox into a custom zone in the user's private CloudKit database. Downloads are verified and replayed before becoming a usable projection; divergent causal branches require an explicit, safety-preserving resolution.

**Tech Stack:** Swift 6, CloudKit/CKSyncEngine, CKAsset, SwiftData model actor, CryptoKit, Swift Testing/XCTest; iOS 18 minimum; the exact Xcode/simulator setup from the offline plan.

**Spec:** [Offline app plan and proposed contract](2026-10-05-plenty-strong-ios-implementation.md), especially Tasks 2, 5 and 6; [pinned Kado/Apple research](../../../research/2026-10-05-strength-app-reference/evidence.md). Implement after offline Task 6; UI integration follows offline Tasks 7–8.

## Global Constraints

- No app login, server, public database, sharing, telemetry or subscription. The user signs into iCloud through iOS; no Sign in with Apple service is needed.
- Opt-in cloud recovery; local-only use is complete. Private CloudKit data consumes the user's iCloud storage. Recovery needs the same Apple account, app container and CloudKit environment, plus successful uploads.
- Cloud covers finalized history, configuration/schedule/interruption/resolution events, frozen rules/profile archives. Unfinished drafts remain phone-local; disclose this explicitly.
- Use `ModelConfiguration(cloudKitDatabase: .none)` locally. Never migrate the authoritative store into automatic CloudKit mirroring as a shortcut.
- CloudKit tokens, engine state, record system fields and account associations stay separate from portable backups. Never put keys, account identifiers or workout values into diagnostic logs.
- Account A's dataset must never upload into B automatically. Sign-out, disabling recovery, quota failures and account changes cannot delete local history or unsent records.
- Immutable events are never merged by timestamp or last-write-wins. Same identity/hash is idempotent; same identity/different bytes is an integrity conflict. Preserve all source observations.
- Already-paused movements and pain/control problems from any unresolved branch cannot be cleared by synchronization or by choosing a branch.
- Development CloudKit checks use test accounts/devices. App Store release and production schema deployment are separate, explicit approval gates, after a concrete reviewed schema and release candidate exist.

## Review Focus

- A successful engine cycle or empty engine queue is not proof that every event is recoverable. Test durable per-record acknowledgements, full reconstruction and honest status text.
- Account changes while the app is terminated: detect the current account before fetching/sending; preserve old data without uploading it to the new account.
- Out-of-order records, a missing parent/archive, or a newer rules version: show incomplete recovery, keep original bytes and never invent a current state.
- Two phones completing the same prescription offline: preserve both branches, freeze further progression, require explicit resolution and retain any safety restriction.
- Crash between local commit, cloud save and acknowledgement: reconstruct pending sends from the durable outbox; repeated uploads cannot create duplicate history.

---

## Ownership and schema

All paths are relative to the Plenty Strong repository root. The display name is Plenty Strong; Swift/Xcode names use PlentyStrong. No cloud or app changes occur while writing this plan. Bundle/container IDs come from the offline plan and must be confirmed with the signing team before provisioning.

Use private custom zone `TrainingJournalV1`. `JournalV1` records hold dataset ID, program/event IDs, envelope/event/parent hashes, input revision, schema/rules/profile version identifiers and a CKAsset containing canonical envelope bytes. `ArchiveV1` holds content hash, kind and a CKAsset for frozen rules/profile bytes. Record names are deterministic hashes of type + dataset ID + event ID or archive hash; specify the canonical tuple encoding in `CloudRecordCodec`, rather than concatenate ambiguous strings. Record field types and asset checksums are versioned and validated. Stage asset files durably before send; retain until acknowledgement and clean only unreferenced files. Verify current Apple size limits during the transport spike and reject oversized payloads without losing the local event. Exercise long histories; do not put large journal JSON in ordinary string fields.

Do not mutate or delete accepted cloud records in v1. Resolution events reference both preserved branches. Disabling recovery stops transport and leaves local data intact; explain that existing private cloud copies remain. Cloud-data erasure and retroactive workout edits need their own destructive-operation/replay design; they are not hidden side effects of a switch or import.

`CloudScope` contains dataset ID, environment, container ID and an opaque current-account association used only locally. Resolve the association using supported CloudKit APIs, not access to credentials. Account identity is never a portable dataset ID. Unbound local datasets require explicit confirmation to associate with the current account; an existing association cannot be silently changed. Restoring an exported dataset under another account is an explicit import-and-new-association operation, while preserving event identity and provenance.

### Task 1: Implement durable account-scoped transport

**Files:** Create `PlentyStrong/Cloud/{CloudScope,CloudRecordCodec,CloudTransport,CloudSyncCoordinator,SyncStatus}.swift`; modify `Persistence/TrainingRepository.swift` and the already-defined outbox/cursor fields in `TrainingSchemaV1.swift`; create `PlentyStrongTests/{CloudTransportTests,CloudAccountTests}.swift` and test-only fake transport under `PlentyStrongTests/Support/`.

**Consumes:** `JournalEnvelope`, frozen rule/profile archives, `OutboxRecord`, `CloudCursorRecord` and the single-writer repository from offline Task 6. An accepted local transition and its pending outbox reference already commit atomically.

**Produces:** `CloudTransport` protocol with `start(scope: CloudScope) async throws`, `requestSync() async`, `stop() async`; `CloudSyncCoordinator` owns one transport for the active scope and exposes `SyncStatus`. Coordinator `discoverRecoveryCandidates() async throws -> [RecoveryCandidate]` performs a read-only, current-account-verified fetch of zone roots on a fresh installation before binding a dataset or sending any local data. `RecoveryCandidate` includes dataset/program IDs, known completed-workout count and verified/incomplete/unsupported status; the user selects recovery or creates a new local program. Status includes local-only/account-unavailable/pending/sending/up-to-date-for-known-records/incomplete/conflict, pending record count, last per-record acknowledgement date and a human-readable retry reason. This date is transport metadata, not a training input.

`CloudRecordCodec.recordName(kind: CloudRecordKind, datasetID: UUID, identity: String) throws -> String`, where `CloudRecordKind` is journal/archive, hashes the canonical three-element JSON tuple. Journal identity is event ID; archive identity is content hash. Both kinds have separate record types and deterministic IDs.

Repository extensions: `bindDataset(datasetID: UUID, to: CloudScope) async throws`, `pendingCloudRecords(scope:) async throws -> [PendingCloudRecord]`, `acknowledge(records: [CloudAcknowledgement], scope:) async throws`, `saveCloudCursor(_ data: Data, scope:) async throws`, `cloudCursor(scope:) async throws -> Data?`. `PendingCloudRecord` is record ID, canonical payload/archive references, checksum and retained system fields; `CloudAcknowledgement` is record ID, verified hash and returned system fields. Disabling or changing accounts suspends pending work; it never deletes it. No direct ModelContext writes from the transport.

- [ ] **Step 1:** Add failing fake-transport/on-disk tests: offline finalize creates one durable pending item; save succeeds then process dies before ack → retry acknowledges the same record exactly once; ack of another scope/hash cannot mark an item done. A→signed-out→B, including change while terminated, preserves A's local event and sends nothing to B. Quota/auth/network/server-record conflicts retain pending items. Same server ID/hash is acknowledged; different hash is quarantined and never overwritten. Missing product/cloud availability never blocks local finalize.

```swift
@Test func cloudRecordIdentityCannotCrossDatasetsOrKinds() throws {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let journal = try CloudRecordCodec.recordName(kind: .journal, datasetID: a, identity: "event-1")
    #expect(try journal != CloudRecordCodec.recordName(kind: .journal, datasetID: b, identity: "event-1"))
    #expect(try journal != CloudRecordCodec.recordName(kind: .archive, datasetID: a, identity: "event-1"))
}
```

Tests import the app module with `@testable`.
- [ ] **Step 2:** Run the app test command from offline Task 6 with `-only-testing:PlentyStrongTests/CloudTransportTests -only-testing:PlentyStrongTests/CloudAccountTests`; expect missing transport/account handling failures.
- [ ] **Step 3:** Implement CKSyncEngine and its delegate using Apple's sample structure, adapted to this durable outbox. Persist `.stateUpdate` data by scope; handle `.accountChange`, individual `.sentRecordZoneChanges.savedRecords` acknowledgements and failed records. CKSyncEngine may clear its pending state on account changes, so rebuild permitted pending work from our durable outbox after every restart. Save with immutable/create-only semantics; on `serverRecordChanged`, compare the actual server payload/hash before treating it as an identical duplicate. Retain returned system fields. Schedule explicit fetch/send outside delegate callbacks; delegate events are serial, so never await engine fetch/send inside the callback. Rate limits and transient failures retry with backoff without a busy loop or training UI blockage.
- [ ] **Step 4:** Run the same tests plus payload asset/checksum/long-history tests. Add a development-container smoke test verifying an acknowledged record can be fetched by ID with identical canonical bytes; simulator mocks alone cannot prove real transport works.
- [ ] **Step 5:** Stage the listed cloud/persistence/test files; `git commit -m "feat: sync immutable training records to private iCloud"`.

### Task 2: Verify recovery and preserve conflicting causal branches

**Files:** Create `Cloud/{CloudIngestor,RecoveryVerifier}.swift`; `Packages/TrainingCore/Sources/TrainingCore/Configuration/BranchResolver.swift`; modify core `Contracts/Journal.swift`, `Persistence/TrainingRepository.swift` and `Backup/BackupDocument.swift`; create `PlentyStrongTests/{CloudRecoveryTests,CloudConflictTests}.swift`, `Packages/TrainingCore/Tests/TrainingCoreTests/BranchResolutionTests.swift` and synthetic history fixtures.

**Consumes:** Canonical cloud payloads plus parent/rules/profile hashes; frozen versioned core functions; current local head and journal. Downloads are untrusted inputs, even from the user's own private database.

**Produces:** `CloudIngestor.ingest(_ batch: [DownloadedCloudRecord], scope: CloudScope) async throws -> IngestionReport`. `DownloadedCloudRecord` contains record ID, raw canonical bytes, metadata and asset checksum; `IngestionReport` returns accepted/identical/waiting-for-dependencies/quarantined counts and recovery health. `TrainingRepository.ingestCloud(_ batch: VerifiedCloudBatch, scope:) async throws -> IngestionReport` serializes validation with local finalization and commits accepted event/head/dependency/quarantine changes atomically. Received records are not blindly added to the upload outbox again.

`RecoveryVerifier.verify(_ records: [ArchivedRecord]) throws -> VerifiedCloudBatch` validates schema, canonical bytes, identities, hashes, parent linkage, revisions, original input state and archived rules/profile; replays every applicable command and checks full returned state/prescription/decisions. It does not read a clock. Missing dependencies are retained but not accepted as a current state; unsupported versions preserve bytes and block that recovered program. Never substitute the latest rules or trust a remote state projection by itself.

Replay also reconstructs the variant registry, selected variants, independent exercise states and base safety from initialization/variantChange commands. Description text is opaque; never infer a load, merge by matching labels or rewrite historical snapshots. An unresolved variant reference is an incomplete dependency. Archived pre-variant schemas retain their original serialization/rules.

`BranchResolutionInput` contains the common ancestor, all competing head hashes and verified branch commands, the user's selected branch, the union of safety problems/restrictions and a supplied next slot. `resolveCloudBranches(_ input: BranchResolutionInput) throws -> BranchResolution` is pure and deterministic. Result has `state: ProgramState`, workout, decisions and preserved branch references. It preserves all branch observations, chooses one branch's progression path, carries forward the strongest safety restrictions/any pause from either branch, clears comparable streaks and requires a fresh baseline for unpaused movements. Conflicting configuration/load/setup requires an explicit selected configuration. Add typed `JournalCommand.resolveConflict` with selected head and all preserved branch-head hashes; its envelope has the selected parent while the payload records the other causal references. A new resolution can only unblock the exact heads reviewed by the user; later arrivals reopen the conflict. Keep rule IDs/explanation keys for this adapter resolution distinct from R01–R16.

Retain compatible saved variant definitions from both branches and all original per-variant observations. The selected branch determines active selection; other retained variants require fresh baseline after resolution, as do other unpaused resolved variants. Conflicting definitions/description edits for the same ID require explicit selection and never silently merge. Shared safety is unioned by base movement ID across branches, so selecting/creating another variant cannot bypass a pause.

Repository `resolveConflict(programID: UUID, expectedHeadHashes: [String], selection: BranchSelection, next: WorkoutSlot) async throws -> StoreSnapshot` verifies the current conflict set, runs the pure resolver, journals the resolution and outbox atomically. `BranchSelection` carries the selected head/configuration; it cannot waive a pause or external safety restriction. Existing `StoreHealth.integrityConflict` freezes finalization but still permits viewing/exporting all observations and saving a draft. Portable backups include every branch/quarantine/resolution; they exclude transport state as before.

- [ ] **Step 1:** Add failing recovery tests: fresh empty store receives shuffled events/archives and reconstructs byte-identical state, history and decisions only when dependencies arrive. Repeated batch is no-op; truncated/tampered/hash-mismatched/newer-schema records never alter accepted state. Two children of the same head, same workout date with different IDs, conflicting same-ID payloads and a local finalize racing a remote ingest all preserve originals and block unsafe projection. Selecting a pain-free branch cannot erase pain on the other. Stale resolution selection rejects. Round-trip backups preserve both branches and a resolved head.

Add restore/conflict cases for active and inactive modified setups, independent rep streaks, original description snapshots after wording corrections, selection restored on a replacement device, a missing variant-creation parent, same label/different ID retained separately, and same ID/incompatible definitions quarantined. Restore must keep numeric bodyweight load null even if description contains “+25 lb.” A pause from one variant must gate all sibling variants on both devices after resolution.

```swift
@Test func selectingCleanBranchCannotClearOtherBranchPain() throws {
    let fixture = try BranchResolutionFixtureLoader.load(named: "pain-on-unselected-branch")
    let result = try resolveCloudBranches(fixture.input)
    #expect(result == fixture.expected)
    #expect(result.state.exercises["incline_db_press_24"]!.mode == .paused)
    #expect(result.state.exercises["incline_db_press_24"]!.ceilingStreak == 0)
}
```

Create test-only `Packages/TrainingCore/Tests/TrainingCoreTests/BranchResolutionFixtureLoader.swift` with `load(named: String) throws -> (input: BranchResolutionInput, expected: BranchResolution)`, loading independently authored JSON fixtures under `Fixtures/Cloud/`. This fixture has a clean selected branch and a pain-paused press on the unselected branch. Its expected result retains both branches and the pause.
- [ ] **Step 2:** Run `swift test --package-path Packages/TrainingCore --filter BranchResolutionTests` and app `CloudRecoveryTests`/`CloudConflictTests`; expect missing verifier/resolver failures. Independently author expected full resolver outputs; don't record implementation output as the oracle.
- [ ] **Step 3:** Implement dependency staging, full replay and causal-head comparison inside the exclusive repository writer. Fetch may finish before every dependency is usable; display incomplete recovery until the verified graph supports a head. Distinct independent programs can coexist; sibling transitions on one program require resolution. Do not concatenate competing workouts into an invented linear sequence or upload a mutable “latest state.” For same-ID/different-bytes conflicts retain both raw payloads in quarantine and require choosing the authoritative valid payload explicitly before any progression resumes, with the same safety union. User selection never bypasses schema/hash/replay validation; invalid bytes remain quarantined and cannot be selected as accepted history.
- [ ] **Step 4:** Run all offline/core/cloud tests. Stress two simulated devices with shuffled/duplicated fetches and simultaneous offline commands; assert convergence only after an explicit valid resolution and identical full projection on both devices. Each accepted cloud envelope must reproduce its archived result or remain visibly quarantined.
- [ ] **Step 5:** Stage resolver/ingestion/backup/test files; `git commit -m "feat: verify iCloud recovery and retain divergent training history"`.

### Task 3: Add truthful sync UI and prove replacement-phone recovery

**Files:** Create `PlentyStrong/Features/Settings/{CloudRecoveryView,ConflictResolutionView}.swift`; modify `Onboarding/OnboardingView.swift`, `Settings/SettingsView.swift`, `PlentyStrong/AppComposition.swift`, app entitlements and localized strings; create `PlentyStrongUITests/CloudRecoveryFlowTests.swift`; `docs/release/{icloud-schema-v1,icloud-recovery-acceptance}.md`.

**Consumes:** `SyncStatus`, `IngestionReport`, repository snapshots/conflict selection and the offline app flows. **Produces:** optional onboarding/settings recovery control; understandable status/retry/export UI; an explicit branch comparison/selection flow; a reviewed development schema and dated recovery evidence. Production container name, App ID/team and environments must be fixed before provisioning; app signing requires Bob's Apple developer access at execution.

- [ ] **Step 1:** Add failing UI tests: decline recovery and finish offline; enable with no iCloud account explains how to sign into iOS without an app-login screen; full storage shows pending and export, not “backed up.” Disabled cloud preserves all local work. Account switch offers view/export of old local history and explicit new-account association, never automatic transfer. Partial restore disables new progression for the affected program and shows missing-data status. Conflict comparison includes all actuals and safety restrictions; selection cannot clear a pause. A restored program renders stored decisions under their original rules.

```swift
func testPendingUploadDoesNotClaimRecoveryComplete() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-fixture", "cloud-pending"]
    app.launch()
    app.buttons["tab.settings"].tap()
    app.buttons["settings.cloud-recovery"].tap()
    XCTAssertEqual(app.staticTexts["sync.pending-count"].label, "1 completed workout waiting to upload")
    XCTAssertFalse(app.staticTexts["sync.all-uploaded"].exists)
}
```

Add these accessibility IDs and a DEBUG-only synthetic seed/injected transport in AppComposition, using offline Task 7's launch-argument boundary. `cloud-pending` has one unacknowledged valid finalized workout and an unavailable network.
- [ ] **Step 2:** Run `xcodebuild test ... -only-testing:PlentyStrongUITests/CloudRecoveryFlowTests`; expect missing status/conflict UI failures.
- [ ] **Step 3:** Implement UI and lifecycle integration. Say “All known completed workouts uploaded” only when every required envelope/archive has durable per-record ack; show last acknowledgement and pending count. Say “Recovery incomplete” if fetched data is unresolved; never promise future availability or recovery of an unfinished draft. Enabling/turning off this user-facing preference is explicit in-app consent. Do not conflate the preference with iOS's system iCloud toggle.
- [ ] **Step 4:** Run automated tests on minimum/current iOS. On two physical test iPhones and a development container, prove: train/finalize offline→reconnect/upload→fresh installation on same account→fetch/verify→same actuals, state, prescription and decisions; airplane mode; device quit/restart; quota/auth failures; disable iCloud for the app; sign out/switch while closed; concurrent offline finalization and safe resolution; restoring an old valid export. Preserve/export test data before destructive device tests. Record actual toolchain/account environment and evidence; don't infer a physical recovery pass from mocks.
- [ ] **Step 5:** Stage UI/entitlements/docs/tests; `git commit -m "feat: expose honest iCloud recovery and conflict status"`. Prepare the exact production schema diff and release checklist. Stop before production schema deployment or app distribution until Bob approves that concrete candidate.

## Acceptance and source checks

The five Review Focus items have named transport/account/recovery/conflict/UI tests above. The completed app must work without iCloud and recover successfully with it. Local persistence crash tests from the offline plan remain mandatory: cloud success cannot mask a lost local transaction.

Before execution, refresh API details against [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [Apple's sample](https://github.com/apple/sample-cloudkit-sync-engine), [per-record save acknowledgements](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/sentrecordzonechanges), [account events](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/accountchange) and [mirroring's account-removal behavior](https://developer.apple.com/forums/thread/811294). The research captured current behavior; no SDK build, CloudKit schema deployment or recovery test has been performed during planning.
