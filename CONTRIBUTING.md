# Contributing

Use Xcode 27.0 build 27A266a / Swift 6.4 and the runtime destinations in [toolchain.md](docs/release/toolchain.md). Work on a branch prefixed `bobzoller/` in an isolated checkout. Contributions use [this public repository](https://github.com/bobzoller/plenty-strong).

Keep changes small. TrainingCore is pure and deterministic: preserve exact decimal loads, archived hashes, original observations, movement variants and shared safety restrictions. Follow existing native Apple patterns; do not add SDKs, analytics, accounts, subscriptions or paid training features. Commerce must remain independent of workout and recovery storage.

Use synthetic fixtures; never commit real workouts, account identifiers, cloud tokens, receipts from real purchases, credentials, personal screenshots or provisioning profiles. Test failures and unavailable services must not destroy stored history.

Run the focused checks for the change, then `make verify-current` on a clean checkout for available coverage. `make verify` is the full minimum/current matrix and must remain nonzero if a required runtime is missing. Include exact command, source SHA, Xcode/runtime, case counts and any diagnostics in the PR template. A current-only pass does not close the iOS 18 release gate.

Public CI must use ephemeral hosted runners, read-only repository permissions and no signing/cloud secrets. Never run public-fork code on a persistent credentialed self-hosted Mac or use `pull_request_target` to execute it. Publication, push/merge, cloud schema deployment, products, signing and distribution need explicit approval of the candidate. Do not change global xcode-select or sign in just to run local verification.

Bug reports should describe synthetic reproduction steps and expected/actual behavior. For sensitive findings, follow [SECURITY.md](SECURITY.md). License new original contributions under the repository's MIT license; retain upstream notices for any approved copied material.
