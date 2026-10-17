# property-tasks Apple app — build, test and TestFlight from the dev Mac. No cloud CI.
# Adapted from phubbard/serpentine and apple-deployment-playbook.md: iPhone, iPad and native macOS
# from one SwiftUI target (no Catalyst, DESIGN.md §10).
#
#   make project                xcodegen → PropertyTasks.xcodeproj (gitignored)
#   make core-test              swift test on the Core package (no simulator needed)
#   make build                  simulator debug build
#   make build-mac              native macOS debug build
#   make run-mac                build and launch the Mac app
#   make test                   core tests, then app unit tests on a simulator
#   make run                    build, install and launch on the simulator
#   make upload-testflight      archive → export .ipa → altool upload
#   make upload-testflight-mac  macOS archive → .pkg → altool upload (never in parallel with iOS)
#   make testflight-notes       CHANGELOG [VERSION] → TestFlight What-to-Test + beta-group distribution
#
# One-time: brew install xcodegen; cp PropertyTasks.local.xcconfig.sample PropertyTasks.local.xcconfig

SHELL         := /bin/bash
APP_NAME       = PropertyTasks
APP_BUNDLE_ID  = net.phfactor.propertytasks
SCHEME         = PropertyTasks
TEAM_ID        = NSR65JVW9F
# Simulator names repeat across runtimes, so pin the OS too.
SIM_DEVICE    ?= iPhone 16 Pro
SIM_OS        ?= $(shell xcrun simctl list runtimes available 2>/dev/null | awk '/iOS/ {v=$$2} END {print v}')

BUILD_DIR      = build
DERIVED        = $(BUILD_DIR)/DerivedData
IOS_ARCHIVE    = $(BUILD_DIR)/$(APP_NAME)-iOS.xcarchive
MAC_ARCHIVE    = $(BUILD_DIR)/$(APP_NAME)-macOS.xcarchive
MAC_EXPORT_DIR = $(BUILD_DIR)/testflight-export-mac
IOS_EXPORT_DIR = $(BUILD_DIR)/testflight-export
TF_EXPORT_OPTS = tools/ExportOptions-TestFlight.plist
TF_MAC_OPTS    = tools/ExportOptions-TestFlight-Mac.plist

VERSION       := $(shell awk '/MARKETING_VERSION:/ {gsub(/[" ]/, "", $$2); print $$2; exit}' project.yml)
BUILD_NUMBER  := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
GIT_SHA       := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

LOCAL = $(APP_NAME).local.xcconfig
APP_STORE_KEY_ID    ?= $(shell awk -F'=' '/^APP_STORE_KEY_ID/ {gsub(/[ ;]/,"",$$2); print $$2; exit}' $(LOCAL) 2>/dev/null)
APP_STORE_ISSUER_ID ?= $(shell awk -F'=' '/^APP_STORE_ISSUER_ID/ {gsub(/[ ;]/,"",$$2); print $$2; exit}' $(LOCAL) 2>/dev/null)
TESTFLIGHT_GROUPS   ?= $(shell awk -F'=' '/^TESTFLIGHT_GROUPS/ {sub(/^[^=]*=/,""); gsub(/^[ \t]+|[ \t;]+$$/,""); print; exit}' $(LOCAL) 2>/dev/null)

# Signing: an Admin-role ASC key provisions headlessly (serpentine ADR-036); SIGN_WITH_KEY=0 falls
# back to Xcode's Apple ID session, which expires silently.
SIGNING_KEY_ID    ?= $(shell awk -F'=' '/^SIGNING_KEY_ID/ {gsub(/[ ;]/,"",$$2); print $$2; exit}' $(LOCAL) 2>/dev/null)
SIGN_WITH_KEY     ?= $(if $(SIGNING_KEY_ID),1,0)
ASC_KEY_PATH       = $(HOME)/.appstoreconnect/private_keys/AuthKey_$(SIGNING_KEY_ID).p8
ifeq ($(SIGN_WITH_KEY),1)
ASC_AUTH = -allowProvisioningUpdates -authenticationKeyPath $(ASC_KEY_PATH) \
           -authenticationKeyID $(SIGNING_KEY_ID) -authenticationKeyIssuerID $(APP_STORE_ISSUER_ID)
else
ASC_AUTH = -allowProvisioningUpdates
endif

SIM = -destination 'platform=iOS Simulator,name=$(SIM_DEVICE),OS=$(SIM_OS)'
SIM_UDID = $(shell xcrun simctl list devices available -j | ruby -rjson -e 'd=JSON.parse(STDIN.read)["devices"]; k=d.keys.find{|r| r.end_with?("iOS-"+ARGV[1].tr(".","-"))}; puts((d[k]||[]).find{|x| x["name"]==ARGV[0]}&.fetch("udid"))' "$(SIM_DEVICE)" "$(SIM_OS)")
XCB = xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) -derivedDataPath $(DERIVED)

.PHONY: help version project unindex core-test build build-mac run-mac test run verify-testflight \
	archive-testflight upload-testflight archive-testflight-mac upload-testflight-mac testflight-notes testflight-groups clean

help:
	@echo "$(APP_NAME) $(VERSION)+$(BUILD_NUMBER) ($(GIT_SHA))"
	@sed -n 's/^#   make /  make /p' Makefile

version:
	@echo "$(VERSION)+$(BUILD_NUMBER) ($(GIT_SHA))"

# Spotlight otherwise indexes every .app under build/.
unindex:
	@mkdir -p $(BUILD_DIR) && touch $(BUILD_DIR)/.metadata_never_index

project: unindex
	@xcodegen generate --quiet

core-test:
	@cd Core && swift test 2>&1 | grep -E "error|✘|Test run|Suite .* (passed|failed)" || true
	@cd Core && swift test >/dev/null 2>&1 || { echo "error: core tests failed (run: cd Core && swift test)"; exit 1; }

build: project
	@$(XCB) $(SIM) -configuration Debug build | grep -E "^(error|warning):|\*\* BUILD" || true
	@test -d "$(DERIVED)/Build/Products/Debug-iphonesimulator/$(APP_NAME).app" || { echo "error: build failed"; exit 1; }

build-mac: project
	@$(XCB) -configuration Debug -destination 'platform=macOS' build | grep -E "^(error|warning):|\*\* BUILD" || true
	@test -d "$(DERIVED)/Build/Products/Debug/$(APP_NAME).app" || { echo "error: mac build failed"; exit 1; }

run-mac: build-mac
	@open "$(DERIVED)/Build/Products/Debug/$(APP_NAME).app"

test: core-test project
	@mkdir -p $(BUILD_DIR)
	@set -o pipefail; $(XCB) $(SIM) test 2>&1 | tee $(BUILD_DIR)/test.log | grep -E "error:|✔|✘|Test run|\*\* TEST" \
	    || { echo "error: tests failed (full log: $(BUILD_DIR)/test.log)"; exit 1; }

run: build
	@test -n "$(SIM_UDID)" || { echo "error: no simulator '$(SIM_DEVICE)' on iOS $(SIM_OS)"; exit 1; }
	@xcrun simctl boot $(SIM_UDID) 2>/dev/null || true
	@open -a Simulator 2>/dev/null || true
	@xcrun simctl install $(SIM_UDID) "$(DERIVED)/Build/Products/Debug-iphonesimulator/$(APP_NAME).app"
	@xcrun simctl launch $(SIM_UDID) $(APP_BUNDLE_ID)

# ─── TestFlight ──────────────────────────────────────────────────────────────
verify-testflight:
	@test -n "$(APP_STORE_KEY_ID)" || { echo "error: APP_STORE_KEY_ID not set in $(LOCAL)"; exit 1; }
	@test -n "$(APP_STORE_ISSUER_ID)" || { echo "error: APP_STORE_ISSUER_ID not set in $(LOCAL)"; exit 1; }
	@test -f "$$HOME/.appstoreconnect/private_keys/AuthKey_$(APP_STORE_KEY_ID).p8" || \
	    { echo "error: ~/.appstoreconnect/private_keys/AuthKey_$(APP_STORE_KEY_ID).p8 missing"; exit 1; }
	@echo "✓ ASC key $(APP_STORE_KEY_ID) (upload, notes)"
ifeq ($(SIGN_WITH_KEY),1)
	@test -f "$(ASC_KEY_PATH)" || { echo "error: $(ASC_KEY_PATH) missing (SIGNING_KEY_ID=$(SIGNING_KEY_ID))"; exit 1; }
	@echo "✓ signing key $(SIGNING_KEY_ID) (provisioning, Admin role)"
else
	@echo "! signing falls back to Xcode's Apple ID session; set SIGNING_KEY_ID in $(LOCAL) to go headless"
endif

archive-testflight: verify-testflight project
	@rm -rf $(IOS_ARCHIVE) $(IOS_EXPORT_DIR)
	@xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) -configuration Release \
	    -destination 'generic/platform=iOS' -archivePath $(IOS_ARCHIVE) \
	    $(ASC_AUTH) archive | grep -E "^(error|warning):|\*\* ARCHIVE" || true
	@test -d $(IOS_ARCHIVE) || { echo "error: archive failed"; exit 1; }
	@echo "✓ archived $(VERSION)+$(BUILD_NUMBER)"

upload-testflight: archive-testflight
	@xcodebuild -exportArchive -archivePath $(IOS_ARCHIVE) -exportPath $(IOS_EXPORT_DIR) \
	    -exportOptionsPlist $(TF_EXPORT_OPTS) $(ASC_AUTH) | grep -E "^(error|warning):|EXPORT" || true
	@test -f $(IOS_EXPORT_DIR)/$(APP_NAME).ipa || { echo "error: no .ipa exported"; exit 1; }
	@xcrun altool --upload-app --type ios --file $(IOS_EXPORT_DIR)/$(APP_NAME).ipa \
	    --apiKey $(APP_STORE_KEY_ID) --apiIssuer $(APP_STORE_ISSUER_ID)
	@echo "✓ uploaded; TestFlight processing takes 10-30 min. Then: make testflight-notes"

# Native macOS: same listing, a .pkg beside the .ipa. macOS must be enabled under App Store Connect >
# App Information > platforms first. Never run in parallel with the iOS upload (shared DerivedData).
archive-testflight-mac: verify-testflight project
	@rm -rf $(MAC_ARCHIVE) $(MAC_EXPORT_DIR)
	@xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) -configuration Release \
	    -destination 'generic/platform=macOS' -archivePath $(MAC_ARCHIVE) \
	    $(ASC_AUTH) archive | grep -E "^(error|warning):|\*\* ARCHIVE" || true
	@test -d $(MAC_ARCHIVE) || { echo "error: macOS archive failed"; exit 1; }
	@echo "✓ archived $(VERSION)+$(BUILD_NUMBER) (macOS)"

upload-testflight-mac: archive-testflight-mac
	@xcodebuild -exportArchive -archivePath $(MAC_ARCHIVE) -exportPath $(MAC_EXPORT_DIR) \
	    -exportOptionsPlist $(TF_MAC_OPTS) $(ASC_AUTH) | grep -E "^(error|warning):|EXPORT" || true
	@PKG=$$(find $(MAC_EXPORT_DIR) -name '*.pkg' -maxdepth 2 | head -n1); \
	test -n "$$PKG" || { echo "error: no .pkg exported"; exit 1; }; \
	xcrun altool --upload-app --type osx --file "$$PKG" \
	    --apiKey $(APP_STORE_KEY_ID) --apiIssuer $(APP_STORE_ISSUER_ID)
	@echo "✓ uploaded; then: make testflight-notes MIN_BUILDS=2"

MIN_BUILDS ?= 1
testflight-notes: verify-testflight
	@ruby tools/set-testflight-notes.rb --key-id "$(APP_STORE_KEY_ID)" --issuer "$(APP_STORE_ISSUER_ID)" \
	    --bundle-id "$(APP_BUNDLE_ID)" --version "$(VERSION)" --build "$(BUILD_NUMBER)" \
	    --min-builds "$(MIN_BUILDS)" $(if $(strip $(TESTFLIGHT_GROUPS)),--groups "$(TESTFLIGHT_GROUPS)",) \
	    --changelog CHANGELOG.md

testflight-groups:
	@ruby tools/set-testflight-notes.rb --key-id "$(APP_STORE_KEY_ID)" --issuer "$(APP_STORE_ISSUER_ID)" \
	    --bundle-id "$(APP_BUNDLE_ID)" --list-groups

clean:
	@rm -rf $(BUILD_DIR) Core/.build
