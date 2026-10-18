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
        ui-test-project ui-test-build ui-test testflight testflight-upload

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
TESTFLIGHT_VERSION ?= 0.1.0
TESTFLIGHT_BUILD ?= $(shell date -u +%Y%m%d%H%M)
TESTFLIGHT_OUT := .build/testflight
TESTFLIGHT_APP := $(TESTFLIGHT_OUT)/WellSpent.app
TESTFLIGHT_PKG := $(TESTFLIGHT_OUT)/WellSpent.pkg

testflight:
	DEVELOPER_DIR=$(XCODE) WELLSPENT_ENV=live SIGN=appstore VERSION=$(TESTFLIGHT_VERSION) BUILD=$(TESTFLIGHT_BUILD) \
		OUT=$(TESTFLIGHT_OUT) SCRATCH=.build/appstore PROFILE="$(PROFILE)" KEYINFO="$(KEYINFO)" scripts/make-app.sh
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh package "$(TESTFLIGHT_APP)" "$(TESTFLIGHT_PKG)"
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh validate "$(TESTFLIGHT_PKG)"

# Uploads the package make testflight validated, and nothing else. App Store
# Connect takes a few minutes to process it, then it shows under TestFlight.
testflight-upload:
	DEVELOPER_DIR=$(XCODE) KEYINFO="$(KEYINFO)" scripts/testflight.sh upload "$(TESTFLIGHT_PKG)"
