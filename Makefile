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

.PHONY: build run test clean server-build server-test integration-test serve all-test coverage gates icon

build:
	swift build

# Builds the Mac app, signs it with this Mac's Apple Development certificate, and
# runs it. `swift run` leaves the app unsigned, so every rebuild looks like a new
# app to the keychain and it asks for the login password again. A stable
# signature means one "Always Allow" per key, once, not once per build.
run:
	swift build --product WellSpentApp
	@identity=$$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'); \
	if [ -z "$$identity" ]; then \
		echo "No Apple Development certificate on this Mac. Xcode, Settings, Accounts, Manage Certificates, then +."; \
		exit 1; \
	fi; \
	codesign --force --sign "$$identity" --identifier app.wellspent.mac .build/debug/WellSpentApp
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

# Rebuilds the app icon from its SVG master. Commit the .icns it writes.
# Run it after every change to Design/AppIcon/AppIcon.svg. Nothing checks that
# the two still match: no CI step runs this, and it needs a Mac (AppKit, iconutil).
icon:
	@iconset=$$(swift scripts/make-app-icon.swift) && \
	iconutil -c icns "$$iconset" -o Sources/WellSpentApp/Resources/AppIcon.icns && \
	echo "Wrote Sources/WellSpentApp/Resources/AppIcon.icns"
