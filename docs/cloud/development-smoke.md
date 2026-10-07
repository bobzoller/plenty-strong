# C1 private CloudKit development smoke (pending, opt-in)

This procedure is prepared code, not evidence that iCloud transport has worked. It must remain disabled until Bob approves the specific development container, signing/capability changes and synthetic private-database writes. No production schema deployment, product creation, account sign-in, publication or real workout upload is part of C1.

## Concrete gate before execution

Review the current proposed container `iCloud.us.zoller.PlentyStrong` and Development environment; the candidate bundle identifier is `us.zoller.PlentyStrong`. Earlier C1 unsigned simulator evidence did not validate signed CloudKit entitlements. The current native target declares proposed CloudKit/APNs entitlements and remote-notification background mode, with provisioning review set to NO and no developer team. A later approved signed configuration must validate the actual container entitlement and capabilities; source declarations alone are not provisioning evidence. Remote-notification/background capabilities and physical devices are required to validate passive notification-driven behavior separately; this explicit fetch/send smoke does not prove that behavior.

The Mac iCloud account and developer account are different roles and currently differ. Their private identifiers are omitted from publishable source. Do not silently switch either account. Bob must choose an approved test device/iCloud account and developer signing configuration. Recovery requires the same Apple account, app container and CloudKit environment; owning a developer membership does not identify the private-database user. The implementation uses the container's opaque user record ID, never an email address.

Review the following exact Development schema. Both record types are immutable, in private custom zones named `PlentyStrong-v1-<lowercase dataset UUID>`:

| Record type | Field | Type |
| --- | --- | --- |
| `JournalV1`, `ArchiveV1` | `payload` | Asset (canonical JSON bytes) |
| `JournalV1`, `ArchiveV1` | `checksum` | String (SHA-256 of full canonical bytes) |
| `JournalV1`, `ArchiveV1` | `datasetID` | String (lowercase UUID) |
| `JournalV1`, `ArchiveV1` | `identity` | String (event ID or archive content hash) |
| `JournalV1`, `ArchiveV1` | `formatVersion` | Int64 (`1`) |

Record names hash the canonical JSON tuple `[kind, datasetID, identity]`, with kinds `journal` and `archive`. No query indexes are needed: discovery enumerates private zones and paginated zone changes. Creating these Development resources is a later authorized live action, not something this task executed.

## Execute only after the gate is approved

1. Use a signed Development build/test configuration and the explicitly chosen test iCloud account. Use synthetic repository fixtures only. Never point this smoke at an existing personal store or production container.
2. In Xcode's test action environment set `PLENTY_RUN_DEVELOPMENT_CLOUD_SMOKE=YES` and `PLENTY_DEVELOPMENT_CLOUD_CONTAINER=<the exact approved identifier>`. Without the first value the test is explicitly skipped. Do not put account identifiers/keys/credentials in environment values or logs.
3. Run only `CloudTransportTests.developmentCloudSmokeIsExplicitlyOptIn` on the approved development test destination. Example command, once the signed scheme/environment/destination have been reviewed:
   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
     -project PlentyStrong.xcodeproj -scheme PlentyStrong \
     -destination '<approved Development test destination>' \
     -only-testing:PlentyStrongTests/CloudTransportTests/developmentCloudSmokeIsExplicitlyOptIn \
     -resultBundlePath '<new local xcresult path>'
   ```
   The current scheme explicitly disables signing; the example does not change it or grant provisioning permission. Use the subsequently approved signed configuration.
4. The smoke creates a fresh synthetic dataset and uploads its initialization plus three frozen archives. It requires zero remaining pending records, a per-record acknowledgement date and no retry reason. It then fetches **each acknowledged record by exact ID** using the private database and compares record kind/zone/ID, claimed checksum, actual SHA-256 and byte-for-byte canonical asset contents.
5. Record the exact configuration/environment, test result and per-record comparison success without keys, opaque account identifiers or workout values. A successful schema/signing step alone is not a passed smoke. Any error or pending item means the smoke has not passed.

The test deliberately leaves the synthetic private Development zone/records in place. Cloud deletion/cleanup needs separate authorization; it never deletes local training or unsent data. If a save succeeds before local acknowledgement, restart retries the same deterministic ID; identical server bytes are acknowledged and differing bytes are retained as a conflict, never overwritten.

## Separate remaining gates

An actual signed Development smoke, physical-device notification behavior, long-term quota/network/account transitions on real devices, and replacement-device exact recovery remain unrun. The historical C1 discovery evidence returned incomplete or unsupported candidates and did not adopt a downloaded head. Subsequent local C2/C3 implementation adds causal verification, branch resolution and app lifecycle/UI opt-in integration; that local evidence does not close the signed/live gates. Drafts stay phone-local and are not cloud records. No production schema or App Store release is approved here.

Sources refreshed read-only on 2026-10-06: [Apple CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine), [installed public Swift SDK interfaces](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), and [archived Apple size limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html). The archived page documents 1 MB non-asset fields and a 50 MB asset-file bound; this implementation caps canonical assets at a conservative 50,000,000 bytes. This is a documented guard, not a current server-limit experiment.
