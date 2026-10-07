# Privacy

Effective October 6, 2026, for this source candidate.

No app account, no subscription, no telemetry. Plenty Strong has no analytics, advertising, third-party crash reporter or developer-operated server. The app does not send workout records or purchase receipts to its developers.

## Local training

Your routine, equipment loads, setup descriptions, sets, effort, pain/technique observations, saved drafts, history and progression decisions are stored in the app's local SwiftData store and archive files. Settings stores local recovery consent and root selection in a separate JSON file. Unreadable original history is retained for review. The operating system may include app files in device backups under your Apple settings; this policy does not promise all OS-managed backups remain on-device.

## Optional iCloud recovery

When you enable recovery in a provisioned release, Apple's CloudKit stores training archives and associated recovery records in your private database. Recovery metadata includes opaque account/container scope, verification records and engine cursors. Apple processes this service under your iCloud account and policies; private CloudKit is not a promise of universal end-to-end encryption. The app has no public/shared CloudKit database, developer-accessible server or sharing adapter. Only the user has access to the private database by default; its records are not visible in the developer portal.

Recovery is optional and local logging/history/export remain available without it. Switching accounts does not upload one account's pending records under another account. Turning recovery off stops the adapter; it does not automatically delete previously uploaded records from iCloud. This candidate's provisioning gate defaults to NO and Debug uses synthetic/inert cloud adapters. Live account, quota, deletion and device recovery checks remain pending.

## Optional tips

Tips are voluntary consumable purchases handled by Apple's StoreKit. Apple processes product requests, payment and transaction delivery. A separate local commerce cache stores transaction ID, product ID and handled/finish-pending/finished status to avoid duplicate handling and safely finish verified tips. It contains no training history and is excluded from workout backups and recovery records. Tips grant no entitlement, feature, reward or subscription. Local StoreKit tests are synthetic; real App Store product/purchase validation remains pending.

## Export, restore and explicit sharing

A lossless JSON backup contains training configuration, observations, archived records, drafts and necessary replay/safety information. It excludes account identifiers, CloudKit system fields/cursors and commerce receipts. The separate staged-originals evidence export preserves received original training bytes for review and is not an ordinary restorable backup. Sharing sends the chosen file through Apple's share sheet only to a destination you choose; that destination may store it online under its own policy. Import reads only a file you select. No background HTTP upload or app web link is present in this candidate.

## Collection and future changes

Based on the current source/dependency audit, no data is collected by the developer or a third-party partner for retention beyond servicing a request. Local-only processing is outside Apple's collection definition; Apple service processing is described above and does not mean Apple sees no data. The manifest declares no tracking, no tracking domains and no developer collection, and no currently accessed required-reason API category. See [privacy-audit.md](docs/release/privacy-audit.md) for evidence and remaining archive/network gates.

This public repository contains the source privacy text. A verified distribution privacy-policy destination and private support/security contact remain app-release blockers. Until established, ask the project owner through your existing trusted private channel; do not put private records into public issues. Re-audit APIs, dependencies, disclosures and destinations before any release or data-path change.
