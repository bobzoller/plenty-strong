# iCloud recovery schema candidate — 2026-10-06

This is an unsigned, unprovisioned candidate. No container, schema, subscription, account or production resource was read or changed. The candidate container is `iCloud.us.zoller.PlentyStrong`, candidate App ID `us.zoller.PlentyStrong`; developer team remains unset and must be explicitly approved before provisioning. Development and Production are separate stores. The distinct Mac iCloud and developer account roles are a signing/access gate for Bob; private account identifiers are omitted, and this code never changes either account.

Native target candidates are `us.zoller.PlentyStrongTests`, `us.zoller.PlentyStrongUITests` and `us.zoller.PlentyStrongCrashHarness`. These share the reviewed publisher namespace with the app and existing proposed product IDs; none establishes App ID/container availability or a developer team.

## Exact proposed schema diff

From an empty reviewed container schema, add `JournalV1` and `ArchiveV1` with the identical fields below, in private custom zones only. No public/shared records, query indexes, deletion migration, mutable-history update, authentication service or server.

| Field | CloudKit type | Required by app | Index |
| --- | --- | --- | --- |
| payload | Asset | yes | none |
| checksum | String | yes | none |
| datasetID | String | yes | none |
| identity | String | yes | none |
| formatVersion | Int64 | yes, value 1 | none |

Parent-reviewed correction to the original plan: retain the C1/C2 per-dataset zone namespace below, rather than the original single `TrainingJournalV1` literal. Independent verified roots, portable descriptor provenance and scoped deletion/discovery use this existing namespace. No live zone has been provisioned; real zone limits/discovery remain pending verification. No transport, canonical identity or payload migration accompanies the candidate-ID correction.

CloudKit-managed system fields are not app schema additions. Custom-zone names are `PlentyStrong-v1-<lowercase dataset UUID>`. Record names are SHA256 of canonical JSON `[kind, lowercase dataset UUID, identity]`, with kind `journal` or `archive`. Journal identity is eventID; archive identity is the content hash. Fetch enumerates private zones/change pages, so no queryable indexes are required. Saves create new records without change tags; changed immutable bytes are retained as conflict evidence rather than overwritten.

JournalV1 asset is exact canonical JournalEnvelope bytes, with frozen rule/profile hashes and original decisions/prescriptions. ArchiveV1 carries frozen rule/profile payloads or a content-addressed `causal-original-v1` wrapper. The wrapper embeds exact original bytes and portable zone/type/name/checksum integrity descriptor, excluding account IDs/system fields; its `contentHash` hashes the canonical wrapper excluding that field. Resolution envelopes reference every required original/ancestor and frozen archive. Missing wrappers or other dependencies keep recovery incomplete. Portable graph exports use formatVersion 2; ordinary legacy linear exports retain version 1. These payload semantics introduce no additional CloudKit record types or fields.

Assets are bounded locally at 50,000,000 bytes using Apple's archived documented asset limit conservatively. Oversize events stay local. This is not a measured live quota. Non-asset field limits do not imply that large journals can use String fields.

## Exact unsigned capability/configuration payload

`PlentyStrong/PlentyStrong.entitlements` declares CloudKit service, the candidate container, environment via `PLENTY_STRONG_CLOUD_ENVIRONMENT`, and APNs environment via `PLENTY_STRONG_APNS_ENVIRONMENT`. Debug candidates use Development/development; Release candidates use Production/production. Existing CODE_SIGNING_ALLOWED=NO remains unchanged. Entitlements are a reviewable payload, not proof of a provisioned resource or notification delivery.

The supplied Info.plist expands `PlentyStrongCloudProvisioningReviewed=NO` by default, controlled by `PLENTY_STRONG_CLOUD_PROVISIONING_REVIEWED` and `PlentyStrongCloudEnvironment` bound to the build environment. Real construction requires an explicitly reviewed enabled build and a valid Development/Production environment. DEBUG always refuses real CKContainer construction, irrespective of persisted preferences or UI fixture state. A signed Development smoke build must be a deliberately reviewed non-DEBUG configuration with Development/development values; never enable a live test by persisting consent in a simulator.

## Approval gates

Before any live step Bob approves the exact team/App ID/container/environment/capability payload above. Prepare the Development schema first with synthetic accounts/devices. Inspect its actual dashboard/export diff against this candidate; adjust documentation for actual provider metadata. No live schema diff is currently available, so this is the exact proposed addition, not a claim of an observed Production delta. Production promotion, signing/distribution and App Store publication each require separate explicit approval after Development and two-device proof. Never deploy or distribute merely because the simulator tests pass.
