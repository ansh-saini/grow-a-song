SHELL := /bin/bash
DERIVED := .build/xcode
DERIVED_IOS := .build/xcode-ios
SPM := .build/xcode/SourcePackages
# First connected iPhone; override with `make device IPHONE_ID=<udid>`.
IPHONE_ID ?= $(shell xcrun devicectl list devices 2>/dev/null | grep -m1 iPhone | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')
SIM ?= iPhone 17 Pro
LOGS := .build/logs

.PHONY: gen test render eval sim device install launch check clean

gen:
	@xcodegen generate --quiet

test:
	@cd Packages/GrowCore && swift test 2>&1 | grep -E "error:|✘|recorded an issue|Test run"

render:
	@cd Packages/GrowCore && swift build -c release --product growsong-render 2>&1 | grep -E "error:" || true
	@Packages/GrowCore/.build/release/growsong-render out 15

eval: gen
	@mkdir -p $(LOGS)
	@xcodebuild -project GrowASong.xcodeproj -scheme ComposerEval -configuration Release \
		-derivedDataPath $(DERIVED) -skipMacroValidation -skipPackagePluginValidation -destination 'platform=macOS' build > $(LOGS)/eval-build.log 2>&1 \
		|| (grep -E "error:" $(LOGS)/eval-build.log | head -20; exit 1)
	@$(DERIVED)/Build/Products/Release/ComposerEval $(N)

sim: gen
	@mkdir -p $(LOGS)
	@xcodebuild -project GrowASong.xcodeproj -scheme GrowASong -configuration Debug \
		-derivedDataPath $(DERIVED_IOS) -clonedSourcePackagesDirPath $(SPM) -skipMacroValidation -skipPackagePluginValidation -destination 'generic/platform=iOS Simulator' build > $(LOGS)/sim.log 2>&1 \
		&& echo "sim build OK" || (grep -E "error:" $(LOGS)/sim.log | sort -u | head -30; exit 1)

device: gen
	@mkdir -p $(LOGS)
	@xcodebuild -project GrowASong.xcodeproj -scheme GrowASong -configuration Release \
		-derivedDataPath $(DERIVED_IOS) -clonedSourcePackagesDirPath $(SPM) -skipMacroValidation -skipPackagePluginValidation -destination 'generic/platform=iOS' -allowProvisioningUpdates build > $(LOGS)/device.log 2>&1 \
		&& echo "device build OK" || (grep -E "error:" $(LOGS)/device.log | sort -u | head -30; exit 1)
	@$(MAKE) --no-print-directory install

install:
	@xcrun devicectl device install app --device $(IPHONE_ID) $(DERIVED_IOS)/Build/Products/Release-iphoneos/GrowASong.app | tail -3
	@$(MAKE) --no-print-directory launch

launch:
	@xcrun devicectl device process launch --device $(IPHONE_ID) --terminate-existing com.anshsaini.growasong | tail -1

check: test render sim

clean:
	rm -rf .build GrowASong.xcodeproj out
