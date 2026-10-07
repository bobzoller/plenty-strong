# App Store metadata candidate

App Store review payload only. Developmental source is published at [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong); no App Store Connect app/product record, upload or submission exists. Bind this draft to the fixed source and archive described in `v1-checklist.md`; signing or provisioning changes require a new source/build identity and review.

## English (U.S.) listing

| Field | Proposed value / owner gate |
| --- | --- |
| Name | Plenty Strong (actual display name; App Store availability unverified) |
| Subtitle | Simple strength, your pace |
| Version / build | 0.1.0 / 2, local proposed identity |
| Primary category | Health & Fitness |
| Primary language | English (U.S.) |
| Bundle ID / internal SKU | us.zoller.PlentyStrong / proposed plenty-strong-ios; Bob confirms availability before creation |
| App Store license / trader and tax status | BLOCKED: Bob approves required legal/commercial fields for the actual publisher; source MIT is already tracked |
| Price | Free; all training, history, export and recovery stay free |
| Keywords | strength,workout,dumbbell,fitness,training,offline,log,home,gym |
| Copyright | 2026 Plenty Strong contributors; publisher/legal identity Bob must confirm |
| Support URL | BLOCKED: Bob must supply and approve a real monitored destination |
| Privacy policy URL | BLOCKED: publish reviewed PRIVACY.md at an approved genuine destination |
| Marketing/source URL | [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong), source only; distribution marketing destination pending |
| Age rating | BLOCKED: owner completes current questionnaire; no fabricated rating |
| Export compliance / content rights | BLOCKED: Bob completes Apple questionnaire for the final binary, publisher and system-service encryption; no legal exemption claim or submission |
| Territories / availability | BLOCKED: Bob approves exact territories and release mode |
| Review contact | BLOCKED: Bob supplies approved contact outside public source |
| Sign-in | No app account or app login. Optional Apple services use device/App Store accounts. |

Proposed promotional text:

> Keep a simple strength routine on your device. Record the reps you actually do, keep separate setups, and see your next workout without a subscription.

Proposed description:

> Plenty Strong is a free strength workout log for a fixed home gym routine using dumbbells, an adjustable bench and a pull-up bar. Choose size, strength, fat loss or maintenance, then train on Sunday, Tuesday and Thursday.
>
> Record actual loads and reps, including separate sides. Save different movement setups without combining their progress. History keeps original observations and labels alongside the next targets saved at the time. Pain or loss of control stops a movement; a new setup cannot bypass that safety pause. Choose an easier workout before you start when you need it.
>
> Training works locally. Export a lossless JSON backup or restore a supported backup you choose. Optional iCloud recovery, once configured, helps recover completed history; unfinished drafts stay on their original device. Every training feature, history, export and recovery remains free. Optional consumable tips support the project and unlock nothing.
>
> No app account, subscription, ads or app telemetry. Apple processes optional iCloud and StoreKit services under its policies. User-selected sharing destinations may store exported data. Read the published privacy policy before enabling recovery or sharing a backup.

These describe implemented flows, not demonstrated training efficacy or guaranteed cloud availability. Trainer/human policy review and live recovery proof are required before external beta. Public source availability refers only to the audited repository snapshot; App Store/download/support/privacy destinations and distribution remain unverified.

Name13/30 and subtitle26/30 characters; keywords63/100 UTF-8 bytes; promotional text151/170 and description1204/4000 characters. These fit the refreshed [app fields](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) and [version fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information). First-version What's New is not submitted; final contact/support, age/content/export/trader status and territory choices remain owner gates. No accessibility nutrition-label support claim is submitted before human evaluation.

## Privacy answer payload

Proposed App Store Connect answer: developer/third-party partner data collection **No**; tracking **No**, with no collected data categories. This follows the candidate's actual local-only training/receipt storage, user-only private CloudKit adapter, zero third-party SDK/server and no telemetry. It is not inferred merely from optional consent or absence of analytics.

[Apple's definition](https://developer.apple.com/app-store/app-privacy-details/) concerns off-device transmission retained for developer/partner access; on-device processing is excluded and Apple's framework/service collection differs from developer collection. Apple still processes purchases and private recovery. The [private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) hides user records from the developer portal. User-selected exports are explicit sharing. Review any new support/hosting destination and signed archive privacy report before submitting these answers. TestFlight itself can provide Apple-managed tester feedback/diagnostics; beta notices must explain that separately.

The shipped manifest values and required-API analysis are in `privacy-audit.md`. No health/fitness, user ID, purchase history or diagnostic category is claimed developer-collected for this source. Future developer-readable recovery, receipt backend, analytics or integrated support upload would change the answers. No universal end-to-end encryption promise is made.

## Proposed optional products (not created)

| Product identifier | Type | English (U.S.) name | Proposed description | Local USD fixture only |
| --- | --- | --- | --- | --- |
| us.zoller.PlentyStrong.tip.small | Consumable | Small tip | Optional tip. Unlocks nothing. | 0.99 |
| us.zoller.PlentyStrong.tip.medium | Consumable | Medium tip | Optional tip. Unlocks nothing. | 2.99 |
| us.zoller.PlentyStrong.tip.large | Consumable | Large tip | Optional tip. Unlocks nothing. | 4.99 |

Internal reference names proposed: Plenty Strong Small Tip / Medium Tip / Large Tip; English (U.S.) display names above are9/10/9 characters and the description is30/45. [Apple's IAP fields](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information) require a review screenshot of the offered item. Final sandbox product screenshots, product availability/territories/tax classification and any promotion choice remain Bob's approved payload; no promotion or paid cosmetic is proposed.

Commercial tiers, localization and identifiers need Bob's exact approval before creation. Production UI uses loaded StoreKit names and display prices; missing products show no guessed prices. [Consumables](https://developer.apple.com/documentation/storekit/product/producttype/consumable) can be purchased repeatedly; they are not a subscription or entitlement. Transaction handling covers [updates](https://developer.apple.com/documentation/storekit/transaction/updates) and [unfinished delivery](https://developer.apple.com/documentation/storekit/transaction/unfinished), with real sandbox proof still required.

## Screenshot payload

See `screenshots/README.md` for fresh raw captures and hashes. Current iPhone 17 captures are review evidence at 1206 × 2622, not a complete App Store set. [Apple's current specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) require an accepted large-iPhone set and 13-inch iPad set for the universal app; images must have no alpha. Capture those sizes from the final approved executable and validate device layouts rather than stretching these files. Text-size/dark acceptance captures are diagnostic evidence, not marketing claims. No screenshots have been uploaded.

## Exact future action scope

1. Bob confirms publisher/legal team, available App ID `us.zoller.PlentyStrong`, private container `iCloud.us.zoller.PlentyStrong`, and separate iCloud/developer roles. Approve Development-only signed synthetic validation payload first (`icloud-schema-v1.md`); normal provisioning remains NO until an approved build changes it.
2. After actual Development and two-device evidence, review observed Development-to-Production schema diff. Proposed additions are only JournalV1/ArchiveV1 with payload Asset, checksum/datasetID/identity String, formatVersion Int64=1, no indexes, private per-dataset zones. No live diff exists yet; see exact semantics in `icloud-schema-v1.md`.
3. Approve commercial products above, genuine URLs/security contact, publication/history payload, final signed source/build and distribution audience. Public Git history includes earlier personal-account and committer metadata; audit or approved clean snapshot is required. Do not publish current ancestors automatically.
4. Deploy only the approved Production schema before offering a Production build, then prove that exact build's upload/replacement recovery. Submit only approved listing/privacy/products/screenshots, upload only the approved signed archive and invite only approved testers. No tag, release mode, public link or App Review submission is implied by this draft.

Every step is pending and must leave dated action/readback evidence. Parent fresh T3 review and broad final review precede presenting account or publication approvals. A simulator pass does not authorize these actions.

Any later fix or approved signing/provisioning configuration that changes the executable, configuration or assets requires a new committed source and incremented local build number, rebuilt artifacts and covering checks. Evidence-only documentation does not change the recorded 0.1.0 (2) unsigned candidate.
