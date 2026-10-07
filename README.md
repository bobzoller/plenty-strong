# Plenty Strong

A native iPhone and iPad strength app with a fixed routine, exact-load progression, local history and lossless JSON backups. No app account, subscription or telemetry. All training features are free; optional consumable tips buy no features or benefits.

Developmental source is published at [bobzoller/plenty-strong](https://github.com/bobzoller/plenty-strong). The public history starts from an audited source snapshot; original development history and native evidence remain local. There is no distributed app release. Real iCloud recovery, App Store purchases, signing and distribution still require their documented release checks. Support/security and a distribution privacy-policy destination remain pending.

## Build and run

You need a Mac with Xcode 27.0 (build 27A266a), Swift 6.4 and the iOS 27.0 simulator runtime. The app deployment minimum is iOS 18.0; executing its minimum-runtime tests is a separate required release gate. No third-party SDK, backend key, private workout files or Apple-account sign-in is needed for the unsigned simulator checks.

1. Open `PlentyStrong.xcodeproj` in Xcode and select the shared `PlentyStrong` scheme.
2. Select the iPhone 17 simulator on iOS 27.0, then Run. Debug iCloud is inert. The scheme's StoreKit configuration uses synthetic local products; no purchase account is needed.
3. To verify from Terminal, run `make verify-current`. This runs core tests, app unit and native UI tests, the macOS process-kill harness and an unsigned generic iOS Release build. It reports **current-only** coverage.
4. Run `make verify` for the full required iOS 18/current matrix. It fails when either selected runtime/destination is missing. The current development Mac has no iOS 18 runtime, so full verification is pending.

Commands: `make test-core`, `make test-app`, `make build-app`, `make crash-proof`. Output goes under `DerivedData/`; commands stop on failures. See [toolchain and exact destinations](docs/release/toolchain.md) for overrides and hosted CI limitations. No signing or provisioning is performed by these commands.

## Using the app

Choose a routine and enter your equipment loads and setup. Today prepares the workout; record actual sets and effort, or choose “I need an easier workout today.” History preserves recorded observations and explanations. Settings provides JSON backup/restore, optional recovery, voluntary tips and About/privacy. Your backup contains training data, so choose its sharing destination carefully.

Optional iCloud uses your private CloudKit database after explicit consent and reviewed provisioning. This candidate's provisioning gate defaults to NO. Tips use Apple's StoreKit; product names and prices come from Apple when available. Neither service is needed for local logging, history or export.

## Contributing and privacy

Read [CONTRIBUTING](CONTRIBUTING.md), [PRIVACY](PRIVACY.md), [SECURITY](SECURITY.md) and the [release privacy audit](docs/release/privacy-audit.md). Use synthetic fixtures only. The pure Swift engine is in `Packages/TrainingCore`; native features are in `Features`, persistence/cloud/commerce in `PlentyStrong`, and portability in `Backup`. The retained app About text predates source publication; its source-link wording will be reviewed with the next native candidate.

Licensed under [MIT](LICENSE); see [NOTICE](NOTICE) and [attribution](docs/release/third-party-attribution.md). Kado inspired the native local-first approach; its code/assets are not incorporated in this candidate.
