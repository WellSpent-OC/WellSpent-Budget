# swift-testing lives in different places depending on which developer directory
# is active.
#
# With Xcode selected (CI, and most machines) plain `swift test` finds it. With
# only CommandLineTools selected, as on the author's Mac, the framework ships but is
# not on the search path, so the flags below are needed. Detecting rather than
# hardcoding means the same commands work in both places.
#
# To stop needing the flags locally:
#   sudo xcodebuild -license accept && sudo xcode-select -s /Applications/Xcode.app
DEVELOPER_DIR_PATH := $(shell xcode-select -p 2>/dev/null)
CLT := /Library/Developer/CommandLineTools

ifeq ($(findstring Xcode.app,$(DEVELOPER_DIR_PATH)),Xcode.app)
FLAGS :=
else
FLAGS := -Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks \
         -Xlinker -F -Xlinker $(CLT)/Library/Developer/Frameworks \
         -Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks \
         -Xlinker -rpath -Xlinker $(CLT)/Library/Developer/usr/lib
endif

.PHONY: build run test clean server-build server-test integration-test serve all-test coverage gates icon app \
        ui-test-project ui-test-build ui-test iphone-project iphone-build iphone-ui-test-build \
        iphone-ui-test testflight testflight-upload

build:
	swift build

# Builds the Mac app, signs it with this Mac's Apple Development certificate, and
# runs it. `swift run` leaves the app unsigned, so every rebuild looks like a new
# app to the keychain and it asks for the login password again. A stable
# signature means one "Always Allow" per key, once, not once per build.
#
# This is WellSpent Staging: a bare executable has no Info.plist saying live, so
# it keeps its own data, keychain items and settings, and never connects to the
# live server. It is signed as staging too, so the keychain does not hand it
# items that trust the live signature without asking first. Real budgets belong
# in the live beta, or `WELLSPENT_ENV=live make app`.
run:
	swift build --product WellSpentApp
	@identity=$$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'); \
	if [ -z "$$identity" ]; then \
		echo "No Apple Development certificate on this Mac. Xcode, Settings, Accounts, Manage Certificates, then +."; \
		exit 1; \
	fi; \
	codesign --force --sign "$$identity" --identifier app.wellspent.mac.staging .build/debug/WellSpentApp
	.build/debug/WellSpentApp

test:
	swift test $(FLAGS)

server-build:
	cd Server && swift build

server-test:
	cd Server && swift test $(FLAGS)


# Client against server over real HTTP. Boots the server in-process on a random
# port; needs no database server, because development and test both use SQLite.
integration-test:
	cd Server && swift test $(FLAGS) --filter IntegrationTests

# Runs on SQLite with no setup. Set DATABASE_URL to point at postgres instead.
serve:
	cd Server && swift run WellSpentServer serve --hostname 127.0.0.1 --port 8080

all-test: test server-test

# Line coverage over the library targets, with a floor. See scripts/coverage.sh
# for what is measured and what is not.
coverage:
	@FLAGS="$(FLAGS)" ./scripts/coverage.sh

# Everything CI runs, in the same order, so a failure here is a failure there.
gates: build test server-test integration-test coverage

clean:
	swift package clean
	cd Server && swift package clean
	rm -rf .build/*/debug/codecov

# Rebuilds the app icon from its two SVG drawings: AppIcon_Small.svg for the
# 16 pixel slot and AppIcon.svg for the rest. Commit the .icns it writes. Run it
# after every change to either drawing in Design/AppIcon/. Nothing checks that
# they still match: no CI step runs this, and it needs a Mac (AppKit, iconutil).
icon:
	@iconset=$$(swift scripts/make-app-icon.swift) && \
	iconutil -c icns "$$iconset" -o Sources/WellSpentApp/Resources/AppIcon.icns && \
	echo "Wrote Sources/WellSpentApp/Resources/AppIcon.icns"

# Builds ".build/app/WellSpent Staging.app", signed ad hoc. WELLSPENT_ENV=live
# builds .build/app/WellSpent.app instead. The beta workflow runs this as live,
# with VERSION, BUILD and ARCHS set; locally it builds for this Mac only.
app:
	scripts/make-app.sh

# The Mac UI test: the real window, driven by XCUITest against the staging
# server with two test accounts (Tests/WellSpentUITests). It needs Xcode and
# xcodegen (brew install xcodegen), and these four variables in the shell,
# exported from a file kept outside the repo and sourced by hand first:
#   WELLSPENT_UI_TEST_EMAIL    WELLSPENT_UI_TEST_PASSWORD
#   WELLSPENT_UI_TEST_EMAIL_2  WELLSPENT_UI_TEST_PASSWORD_2
# WELLSPENT_UI_TEST_SERVER is optional and defaults to https://staging.wellspent.space.
# Both accounts must exist on staging with their addresses confirmed. The values
# reach the test runner as TEST_RUNNER_ variables, never on a command line.
#
# The app's window opens on screen for the whole run, so run it when nobody is
# using this Mac for anything else. The first run asks once to let Xcode's test
# manager control the app.
#
# Xcode/project.yml is the source; the .xcodeproj it generates is ignored.
# Everything xcodebuild writes stays under .build/, including the result bundle
# with the screenshots XCUITest takes when a step fails.
UI_TEST_PROJECT := Xcode/WellSpentMac.xcodeproj
UI_TEST_VARS := WELLSPENT_UI_TEST_EMAIL WELLSPENT_UI_TEST_PASSWORD WELLSPENT_UI_TEST_EMAIL_2 WELLSPENT_UI_TEST_PASSWORD_2
ifeq ($(findstring Xcode.app,$(DEVELOPER_DIR_PATH)),Xcode.app)
UI_TEST_DEVELOPER_DIR := $(DEVELOPER_DIR_PATH)
else
UI_TEST_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
UI_TEST_XCODEBUILD := DEVELOPER_DIR="$(UI_TEST_DEVELOPER_DIR)" xcodebuild \
	-project $(UI_TEST_PROJECT) -scheme WellSpentUITests -destination 'platform=macOS' \
	-derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/xcode-packages

# Generates the Xcode project from Xcode/project.yml.
ui-test-project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is not installed. brew install xcodegen"; exit 1; }
	xcodegen generate --spec Xcode/project.yml --quiet

# Compiles the app and the test without running anything. No window opens.
ui-test-build: ui-test-project
	$(UI_TEST_XCODEBUILD) build-for-testing

ui-test: ui-test-project
	@for name in $(UI_TEST_VARS); do \
		eval "value=\$$$$name"; \
		if [ -z "$$value" ]; then \
			echo "$$name is not set. Source the file that exports the four test account variables first."; \
			exit 1; \
		fi; \
	done
	rm -rf .build/xcode/ui-test.xcresult
	TEST_RUNNER_WELLSPENT_UI_TEST_EMAIL="$$WELLSPENT_UI_TEST_EMAIL" \
	TEST_RUNNER_WELLSPENT_UI_TEST_PASSWORD="$$WELLSPENT_UI_TEST_PASSWORD" \
	TEST_RUNNER_WELLSPENT_UI_TEST_EMAIL_2="$$WELLSPENT_UI_TEST_EMAIL_2" \
	TEST_RUNNER_WELLSPENT_UI_TEST_PASSWORD_2="$$WELLSPENT_UI_TEST_PASSWORD_2" \
	TEST_RUNNER_WELLSPENT_UI_TEST_SERVER="$$WELLSPENT_UI_TEST_SERVER" \
	$(UI_TEST_XCODEBUILD) test -resultBundlePath .build/xcode/ui-test.xcresult

# The iPhone app (iOS/), as a staging build for the iOS Simulator. It needs
# Xcode and xcodegen. iOS/project.yml is the source, and the .xcodeproj it
# generates is ignored. Everything xcodebuild writes stays under .build/, and
# the app lands in .build/xcode-iphone/Build/Products/Debug-iphonesimulator.
IPHONE_PROJECT := iOS/WellSpentPhone.xcodeproj
IPHONE_XCODEBUILD := DEVELOPER_DIR="$(UI_TEST_DEVELOPER_DIR)" xcodebuild \
	-project $(IPHONE_PROJECT) -scheme WellSpentPhone -destination 'generic/platform=iOS Simulator' \
	-derivedDataPath .build/xcode-iphone -clonedSourcePackagesDirPath .build/xcode-packages

# Generates the Xcode project from iOS/project.yml.
iphone-project:
	@command -v xcodegen >/dev/null || { echo "xcodegen is not installed. brew install xcodegen"; exit 1; }
	xcodegen generate --spec iOS/project.yml --quiet

# Builds the iPhone app for the simulator. Nothing runs and no window opens.
iphone-build: iphone-project
	$(IPHONE_XCODEBUILD) build

# Builds the iPhone app and its UI tests, without running them.
iphone-ui-test-build: iphone-project
	$(IPHONE_XCODEBUILD) build-for-testing

# The iPhone UI tests (iOS/UITests), once in light and once in dark, each on a
# simulator made for the run and deleted after, so nothing of an earlier run
# is left in the app. It runs headless: no Simulator window opens, and the
# Mac's screen is never taken. The tests that sign in read the same four
# WELLSPENT_UI_TEST_ variables as the Mac's (see ui-test above), and skip
# without them. The rest need no account and no server. The simulator is the
# newest numbered iPhone the machine has, unless IPHONE_UI_TEST_DEVICE names
# one, such as "iPhone 17".
IPHONE_SIMCTL := DEVELOPER_DIR="$(UI_TEST_DEVELOPER_DIR)" xcrun simctl
iphone-ui-test: iphone-ui-test-build
	@set -e; \
	export DEVELOPER_DIR="$(UI_TEST_DEVELOPER_DIR)"; \
	runtime=$$($(IPHONE_SIMCTL) list runtimes available | grep '^iOS ' | tail -1 | awk '{print $$NF}'); \
	device="$(IPHONE_UI_TEST_DEVICE)"; \
	if [ -z "$$device" ]; then \
		device=$$($(IPHONE_SIMCTL) list devicetypes | grep -E '^iPhone [0-9]+ \(' | sort -k2,2n | tail -1 | sed -E 's/.*\((.*)\)$$/\1/'); \
	fi; \
	for look in light dark; do \
		udid=$$($(IPHONE_SIMCTL) create "wellspent-ui-test-$$look" "$$device" "$$runtime"); \
		$(IPHONE_SIMCTL) boot "$$udid"; \
		$(IPHONE_SIMCTL) ui "$$udid" appearance $$look; \
		rm -rf .build/xcode-iphone/ui-test-$$look.xcresult; \
		status=0; \
		TEST_RUNNER_WELLSPENT_UI_TEST_EMAIL="$$WELLSPENT_UI_TEST_EMAIL" \
		TEST_RUNNER_WELLSPENT_UI_TEST_PASSWORD="$$WELLSPENT_UI_TEST_PASSWORD" \
		TEST_RUNNER_WELLSPENT_UI_TEST_EMAIL_2="$$WELLSPENT_UI_TEST_EMAIL_2" \
		TEST_RUNNER_WELLSPENT_UI_TEST_PASSWORD_2="$$WELLSPENT_UI_TEST_PASSWORD_2" \
		TEST_RUNNER_WELLSPENT_UI_TEST_SERVER="$$WELLSPENT_UI_TEST_SERVER" \
		DEVELOPER_DIR="$(UI_TEST_DEVELOPER_DIR)" xcodebuild test-without-building \
			-project $(IPHONE_PROJECT) -scheme WellSpentPhone -destination "id=$$udid" \
			-derivedDataPath .build/xcode-iphone -clonedSourcePackagesDirPath .build/xcode-packages \
			-resultBundlePath .build/xcode-iphone/ui-test-$$look.xcresult || status=$$?; \
		$(IPHONE_SIMCTL) shutdown "$$udid" || true; \
		$(IPHONE_SIMCTL) delete "$$udid" || true; \
		if [ $$status -ne 0 ]; then echo "iPhone UI tests failed in $$look mode"; exit $$status; fi; \
	done

# The TestFlight build: WellSpent.app sandboxed and signed for the Mac App Store,
# inside a signed installer package, checked by App Store Connect. It never
# uploads. The profile, the certificate names and the API key info live outside
# the repo in a folder each machine sets up. scripts/make-app.sh and
# scripts/testflight.sh list the variables. It needs Xcode, not just the command
# line tools, so DEVELOPER_DIR is set for every step. The build number is the UTC
# minute, which only ever goes up, as App Store Connect requires.
XCODE ?= /Applications/Xcode.app/Contents/Developer
APPLE_DIR ?= $(HOME)/.config/wellspent/apple
PROFILE ?= $(APPLE_DIR)/WellSpent_Mac_App_Store.provisionprofile
KEYINFO ?= $(APPLE_DIR)/keyinfo.txt
# The version is the release's, from the vX.Y.Z tag on the commit being built,
# since a TestFlight build comes only from a release tag. Without one, make
# testflight stops, unless TESTFLIGHT_VERSION is given for a trial build.
TESTFLIGHT_VERSION ?= $(patsubst v%,%,$(shell git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null))
# Worked out once, so every step of one run uses the same build number.
ifeq ($(origin TESTFLIGHT_BUILD),undefined)
TESTFLIGHT_BUILD := $(shell date -u +%Y%m%d%H%M)
endif
TESTFLIGHT_OUT := .build/testflight
TESTFLIGHT_APP := $(TESTFLIGHT_OUT)/WellSpent.app
TESTFLIGHT_PKG := $(TESTFLIGHT_OUT)/WellSpent.pkg

testflight:
	@[ -n "$(TESTFLIGHT_VERSION)" ] || { echo "make testflight builds a release: check out its vX.Y.Z tag, or give TESTFLIGHT_VERSION for a trial build." >&2; exit 1; }
	DEVELOPER_DIR=$(XCODE) WELLSPENT_ENV=live SIGN=appstore VERSION=$(TESTFLIGHT_VERSION) BUILD=$(TESTFLIGHT_BUILD) \
		OUT=$(TESTFLIGHT_OUT) SCRATCH=.build/appstore PROFILE="$(PROFILE)" KEYINFO="$(KEYINFO)" scripts/make-app.sh
	scripts/release-check.sh "$(TESTFLIGHT_APP)" "$(TESTFLIGHT_VERSION)" "$(TESTFLIGHT_BUILD)"
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh package "$(TESTFLIGHT_APP)" "$(TESTFLIGHT_PKG)"
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh validate "$(TESTFLIGHT_PKG)"

# Uploads the package make testflight validated, and nothing else. App Store
# Connect takes a few minutes to process it, then it shows under TestFlight.
testflight-upload:
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh upload "$(TESTFLIGHT_PKG)"
