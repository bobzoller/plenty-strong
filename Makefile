DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# Local/public checks never inherit permission to exercise a real cloud account.
override PLENTY_RUN_DEVELOPMENT_CLOUD_SMOKE := NO
export PLENTY_RUN_DEVELOPMENT_CLOUD_SMOKE
# Xcode's diagnostic child may drop DEVELOPER_DIR; preserve tool lookup via PATH.
export PATH := $(DEVELOPER_DIR)/usr/bin:$(PATH)
DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=27.0
MINIMUM_DESTINATION ?= platform=iOS Simulator,name=iPhone 16,OS=18.0
DERIVED_DATA ?= $(CURDIR)/DerivedData
XCODEBUILD = xcodebuild -project PlentyStrong.xcodeproj -scheme PlentyStrong

.PHONY: verify verify-current check-toolchain check-current check-minimum test-core test-app build-app crash-proof test core-test
.NOTPARALLEL: verify verify-current

check-toolchain:
	python3 scripts/check-toolchain.py

check-current:
	python3 scripts/check-toolchain.py --required-ios-major 27 --destination '$(DESTINATION)'

check-minimum:
	python3 scripts/check-toolchain.py --required-ios-major 18 --destination '$(MINIMUM_DESTINATION)'

# Full required release matrix. Missing/failed required checks always return nonzero.
verify:
	$(MAKE) check-current check-minimum
	$(MAKE) verify-current
	$(MAKE) test-app DESTINATION='$(MINIMUM_DESTINATION)' DERIVED_DATA='$(DERIVED_DATA)/Minimum'
	@echo 'Minimum/current local matrix passed; physical/service/signing/publication gates remain separate.'

# Explicitly limited to the current runtime. This cannot close the minimum iOS gate.
verify-current:
	@echo 'CURRENT-ONLY verification; minimum iOS 18 runtime is a separate required release gate.'
	$(MAKE) check-current test-core test-app crash-proof build-app
	@echo 'CURRENT-ONLY verification passed. Full required matrix: make verify.'

test-core: check-toolchain
	xcrun swift test --package-path Packages/TrainingCore

test-app: check-toolchain
	python3 scripts/check-toolchain.py --destination '$(DESTINATION)'
	$(XCODEBUILD) test -configuration Debug -destination '$(DESTINATION)' -parallel-testing-enabled NO -derivedDataPath '$(DERIVED_DATA)/App' CODE_SIGNING_ALLOWED=NO

build-app: check-toolchain
	$(XCODEBUILD) build -configuration Release -destination 'generic/platform=iOS' -derivedDataPath '$(DERIVED_DATA)/Release' CODE_SIGNING_ALLOWED=NO

crash-proof: check-toolchain
	xcodebuild build -project PlentyStrong.xcodeproj -scheme PlentyStrongCrashHarness -configuration Debug -destination 'platform=macOS' -derivedDataPath '$(DERIVED_DATA)/Crash' CODE_SIGNING_ALLOWED=NO
	python3 PlentyStrongTests/Support/run-crash-proof.py '$(DERIVED_DATA)/Crash/Build/Products/Debug/PlentyStrongCrashHarness' '$(CURDIR)'

# Existing entry points remain compatible.
test: test-app
core-test: test-core
