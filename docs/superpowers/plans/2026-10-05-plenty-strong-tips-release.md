# Plenty Strong Tips and Open-Source Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Kado-style optional tips and prepare a reproducible, openly licensed app release with all training features free, no app account, no subscription and no telemetry.

**Architecture:** A small StoreKit 2 adapter and SwiftUI tip page live outside TrainingCore and the training repository. Release configuration, privacy/attribution documents and automated checks cover the native app and cloud adapter. Signing, production CloudKit schema deployment and external distribution happen only after the concrete release candidate is approved.

**Tech Stack:** SwiftUI, StoreKit 2, StoreKit configuration testing, Swift Testing/XCTest; MIT proposed; Xcode 27.0 / Swift 6.4 and iOS 18 floor from the [offline plan](2026-10-05-plenty-strong-ios-implementation.md). No external runtime SDKs.

**Spec:** [Offline app plan](2026-10-05-plenty-strong-ios-implementation.md), [private recovery plan](2026-10-05-plenty-strong-icloud-recovery.md), [pinned Kado/Apple evidence](../../../research/2026-10-05-strength-app-reference/evidence.md). Tip UI can start after offline Task 7; release waits for all offline/cloud acceptance gates.

## Global Constraints

- “No account, no subscription, no telemetry.” All training features, history, export and cloud recovery remain free. Tips are optional consumable purchases with no entitlement, unlock, reward, subscription or supporter-only cosmetic feature.
- TrainingCore never imports StoreKit; commerce errors and transactions cannot change workout state or block logging.
- Use our own product identifiers, branding, screenshots and support/privacy links. Copy Kado code only with its MIT notice and attribution; do not copy its App Store products or Supporter Pack.
- Use App Store-localized product names/prices. Suggested test tiers are USD 0.99/2.99/4.99; commercial tiers and final product IDs are reviewed before App Store Connect creation, not hard-coded into production UI.
- No analytics, advertising, third-party crash reporter, account system or silent outgoing HTTP. Optional CloudKit and StoreKit processing is explained in the privacy text; user-opened web/support links are explicit.
- No user workout data, Apple identifiers, cloud tokens or commerce credentials in logs, screenshots, source/test fixtures or issue templates. Synthetic fixtures only.
- The minimum/current iOS test matrix and actual toolchain must be recorded. No successful build/test claim from a project file, generated workflow or unrun command.
- Public pull requests must never execute untrusted code on a persistent signing/self-hosted Mac with credentials. Read-only hosted checks require no production secrets; signing is a separate protected/manual step.
- Open-source publication, production CloudKit schema deployment, App Store product creation and TestFlight/App Store distribution require approval of the concrete payload/candidate. Plan review does not grant blanket operational authorization.

## Review Focus

- Product load fails, purchase is cancelled/pending/unverified, or the app quits mid-transaction: keep training unaffected and handle verified transactions exactly once.
- “Restore purchases” must not imply restorable training benefits from consumable tips. Handle unfinished transactions and transaction updates without inventing an entitlement.
- “No telemetry” remains true in the dependency graph, diagnostics and networking, while the privacy page accurately describes Apple cloud/purchase processing.
- Copied code/assets have a valid license and retained notice; branding and private project data never leak into the open-source repository.
- Build/recovery evidence belongs to the actual candidate SHA and signing/container environment; development schema tests do not prove production recovery.

---

## Scope and release gates

Paths are relative to the Plenty Strong repository root. The display name is Plenty Strong; targets/scheme use PlentyStrong. Proposed bundle ID is `us.zoller.PlentyStrong`; proposed products are `.tip.small`, `.tip.medium`, `.tip.large`. Confirm publisher/signing IDs consistently before provisioning. App Store Connect product availability is required for real purchases; `.storekit` tests can run before provisioning.

The app name is settled. The source repository, publisher/developer team, provisioned IDs and public support/privacy URLs are decisions to resolve before publication. Author a local privacy page and README first; don't register hosting or publish a site during planning. A free app can still require Apple developer membership for distribution; this is separate from the no-subscription promise to users.

### Task 1: Add a native, non-blocking tip page

**Files:** Create `PlentyStrong/Monetization/{TipProduct,TipStore,TipJarView}.swift`; `PlentyStrong/Resources/Tips.storekit`; modify `Features/Settings/SettingsView.swift`, `Resources/Localizable.xcstrings` and `AppComposition.swift`; create `PlentyStrongTests/TipStoreTests.swift`, `PlentyStrongUITests/TipJarTests.swift` and test-only `FakeTipPurchaser.swift`.

**Interfaces:** `TipProduct` is ID/displayName/displayPrice, not a training entitlement. `TipPurchasing` exposes `products() async throws -> [TipProduct]`, `purchase(id: String) async -> TipPurchaseOutcome`, `verifiedTransactions: AsyncStream<VerifiedTip>` and `finishVerified(transactionID: UInt64) async throws`. `VerifiedTip` is transactionID/productID; `TipPurchaseOutcome` is verifiedTip(VerifiedTip)/pending/cancelled/failed(message). `@MainActor @Observable TipStore.init(purchaser: any TipPurchasing)` exposes `load() async`, `tip(productID:) async` and `state: TipUIState` (idle/loading/ready/purchasing/pending/thankYou/failed). The adapter verifies StoreKit results; store acknowledgement invokes finishVerified only after verified handling. Listen to `Transaction.updates` and inspect unfinished transactions from app startup; deduplicate delivery/thank-you by transaction ID in a local commerce-only receipt cache. Never save tips into the progression journal or cloud training outbox.

- [ ] **Step 1:** Add failing fake-purchaser tests: verified purchase produces one thank-you and finishes once; repeated update/unfinished delivery doesn't duplicate handling; cancelled returns idle, pending remains understandable, unverified fails without granting anything, interrupted verified transaction is finished after relaunch. Product-load failure leaves Settings/workouts usable. UI test compares identical training capabilities before and after a tip.

```swift
@Test @MainActor func voluntaryTipFinishesVerifiedTransaction() async {
    let productID = "us.zoller.PlentyStrong.tip.small"
    let fake = FakeTipPurchaser(outcome: .verifiedTip(
        VerifiedTip(transactionID: 42, productID: productID)))
    let store = TipStore(purchaser: fake)
    await store.load()
    await store.tip(productID: productID)
    #expect(store.state == .thankYou)
    #expect(fake.finishedTransactionIDs == [42])
}
```

The test fake provides the three synthetic products and records finish calls; `TipUIState` is Equatable. Pending/cancelled/unverified test variants assert no finish call and no training repository write.

Receipt handling is idempotent; external finish delivery is retriable. Persist handled/finish-pending status before invoking StoreKit finish, then mark finished after it returns. If interrupted, an unfinished transaction must still be finished on relaunch even if its thank-you was already recorded; repeated finish attempts cannot grant anything or duplicate a receipt. Test the interruption boundary separately from the ordinary once-only fake call above.
- [ ] **Step 2:** Run the app test command from offline Task 6 with `-only-testing:PlentyStrongTests/TipStoreTests -only-testing:PlentyStrongUITests/TipJarTests`; expect missing StoreKit/page failures. Use `Tips.storekit` in the shared test scheme, not real purchases.
- [ ] **Step 3:** Implement StoreKit 2 product loading, verification, unfinished/update lifecycle and the tip page. Suggested copy: “The app is free. No account, no subscription, no telemetry. If it helps you, you can leave a tip. Tips unlock nothing.” Add a brief appreciative confirmation, no nagging notification or workout interstitial. Prices come from Product.displayPrice; no price appears if product loading fails. Do not add a restore-benefits button for consumables. Apple's optional consumable transaction-history configuration is a separate API choice; it does not create app entitlements.
- [ ] **Step 4:** Run fake tests and StoreKit local scenarios: success/cancel/Ask to Buy pending/failure/unfinished delivery. Confirm products unavailable in airplane mode while normal/easier/partial training and backup still work. Later, record one sandbox purchase/update test with the final products/team before release; do not count local StoreKit simulation as App Store Connect evidence.
- [ ] **Step 5:** Stage tip/UI/test files; `git commit -m "feat: offer optional tips without paid training features"`.

### Task 2: Make the source and build reviewable without private services

**Files:** Create repo `LICENSE`, `NOTICE`, `README.md`, `CONTRIBUTING.md`, `PRIVACY.md`, `SECURITY.md`, `.gitignore`, `Makefile`, `.github/workflows/ci.yml`, `.github/PULL_REQUEST_TEMPLATE.md`; app `Resources/PrivacyInfo.xcprivacy`; `docs/release/{toolchain,privacy-audit,third-party-attribution}.md`. Modify Xcode shared schemes/configurations and `Features/Settings/AboutView.swift`.

**Consumes:** Actual dependency graph, repository paths/contracts, entitlements and completed test suites from all three plans. **Produces:** source/license/privacy/build documentation; reproducible `make test-core`, `make test-app`, `make build-app`, `make verify` entry points; CI status tied to current head. These commands wrap the exact verified Swift/xcodebuild commands and selected destinations, returning nonzero on any failed required check.

- [ ] **Step 1:** Establish a clean checkout verification before documentation/tooling changes. Record missing commands/configuration and actual failing checks, not fabricated unit tests for prose. Inventory copied code/assets and dependencies; audit app-originated network/diagnostic paths against the promised Apple-only integrations and explicit user links. Check entitlement/container IDs and absence of private credentials or personal fixtures.
- [ ] **Step 2:** Run `make verify` in a clean checkout once defined; initially it must expose missing app/core configuration or required checks rather than report success. Provision the supported Xcode Mac from the offline plan. Validate simulator runtimes for iOS 18 and current iOS; pin the concrete available destinations in Makefile and document setup.
- [ ] **Step 3:** Write MIT/NOTICE attribution, beginner-focused README, contribution/test instructions, vulnerability-reporting route and plain-language local/iCloud/tip/export privacy text. Complete Apple's privacy manifest using APIs actually used and their required reasons; “no telemetry” is not a substitute for that audit. Choose a presently available hosted macOS runner/image with the exact validated Xcode toolchain before enabling public CI; record image/Xcode/version output. Workflow uses read-only permissions, no signing/cloud secrets, no `pull_request_target` execution of fork code, and runs core/app tests plus build. If no compatible hosted image exists, keep public app CI explicitly unavailable and use a trusted manual clean-checkout Mac check; don't run public forks on a credentialed self-hosted runner or label unrun app checks green.
- [ ] **Step 4:** Run `make verify` locally and trigger the configured workflow on a synthetic review branch, then inspect the current-head checks. Verify a contributor can build and run offline without an Apple account, paid SDK/backend key, private Trainer files or our cloud credentials. Audit the actual archive/dependency graph/privacy manifest and a synthetic-data network session; Apple's services may communicate, but no app analytics endpoint is present. Validate source/license/support/privacy links once real destinations exist.
- [ ] **Step 5:** Stage only source/tooling/documentation configuration; `git commit -m "chore: document and verify the open-source iOS release"`.

### Task 3: Produce a concrete release candidate and approved distribution

**Files:** Create `docs/release/{v1-checklist,testflight-notes,app-store-metadata}.md`; add owned app icons/screenshots under `PlentyStrong/Resources/Assets.xcassets` and `docs/release/screenshots/`; modify release build/version/signing configuration after publisher/IDs are settled. Release evidence records candidate commit SHA, archive build number, schema/environment, toolchain and actual results.

**Consumes:** Passing offline/core/cloud/tip/build checks; Bob/trainer approval of contract resolutions and user-facing training policy; real same-account replacement-device recovery; license/privacy audit. **Produces:** a signed reviewable archive and complete metadata/schema diff/acceptance record. App Store Connect/production CloudKit mutations remain a final separate approval gate.

- [ ] **Step 1:** Run the complete pre-release checklist against a fixed candidate SHA and identify missing evidence. Must include every C01–C47/F01–F14 case, on-disk crash/backup tests, offline user flows, physical iCloud account-change/recovery/conflict checks, accessible stopping/per-side UI and sandbox tips. No failing, pending or missing required gate is treated as green.

Include Plenty Strong display-name validation and saved-setup create/select/correction, independent progression, shared safety, and replacement-device restore. Use synthetic modification text in screenshots; no personal setups or workout data.
- [ ] **Step 2:** Build/archive that candidate with the approved development team and final IDs; validate signing/entitlements and archive reports. Use synthetic workouts for icons/screenshots/metadata. Prepare exact privacy answers based on the shipped app and Apple's current definitions, and a copy of the production CloudKit schema diff. Do not claim the developer “collects no data” without checking the definition and actual service behavior.
- [ ] **Step 3:** Present Bob the candidate SHA/build, distribution destination, final products/prices/metadata and production schema changes for approval. Explain any remaining blocker. Do not deploy the schema, publish the repository, create live products or distribute until the relevant action is explicitly approved. Earlier approval of this implementation plan permits implementation/review, not these operational actions.
- [ ] **Step 4:** Once authorized, execute only the approved publication/product/schema/distribution changes. Production CloudKit schema must be deployed before the production-environment build is offered. Verify that exact build's production-container upload and replacement-device restore on synthetic data; a development-container pass is insufficient. Verify current-head CI and approval again before any authorized PR merge. Submit TestFlight/App Store metadata only within the approved scope; don't claim availability until confirmed by Apple.
- [ ] **Step 5:** Record approved actions, production recovery evidence and real distribution status; commit release documentation and tag the approved candidate. If Apple review or any gate is pending, report that status without declaring release complete. Security/schema/distribution follow-through stays with the repo-specific managed task when that capability is available.

## Self-review and completion conditions

Optional tipping, source publication and privacy promises are separate from training state. The five Review Focus conditions have explicit lifecycle tests/audits and current-candidate release gates. User data remains local/private; all training is free; no paid SDK or backend is needed for an offline contributor build.

Refresh StoreKit details at execution using [consumable purchases](https://developer.apple.com/documentation/storekit/product/producttype/consumable), [transaction updates](https://developer.apple.com/documentation/storekit/transaction/updates), [unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished) and [Xcode support requirements](https://developer.apple.com/xcode/system-requirements). Refer to the pinned evidence for Kado's current tip implementation and MIT license. No StoreKit purchase, CI build, archive, product creation or release has been executed during this planning turn.
