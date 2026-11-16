# BalanceKeeper: `make` builds .build/BalanceKeeper.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.0
BUILD    ?= .build
APP      := $(BUILD)/BalanceKeeper.app
STAGE    := $(BUILD)/stage/BalanceKeeper.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.balancekeeper.agent
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -mmacosx-version-min=$(MIN_OS)
DIAGNOSTIC_LOG ?= 0
ifeq ($(DIAGNOSTIC_LOG),1)
AGENT_DIAGNOSTIC_FLAGS := -DBALANCEKEEPER_DIAGNOSTIC_LOG
endif

# Code signing identity. The default is a self-signed certificate created once per Mac by
# scripts/create-signing-identity.sh: a fixed signature keeps the login item working across rebuilds (an ad-hoc
# signature changes with every build). For distribution use Developer ID:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= Local Code Signing
TIMESTAMP     ?=
SIGN_FLAGS    := --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)"

# Release builds go to their own folder, signed with Developer ID and a secure timestamp (notarization needs both).
# Set RELEASE_IDENTITY and NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) on the command line or
# in release.local.mk, which is not committed:
#   RELEASE_IDENTITY := Developer ID Application: Your Name (TEAMID)
#   NOTARY_PROFILE   := my-notary-profile
-include release.local.mk
RELEASE_DIR      := .build/release
RELEASE_IDENTITY ?=
NOTARY_PROFILE   ?= notary
DMG              := $(RELEASE_DIR)/BalanceKeeper-$(VERSION).dmg

AGENT_SRC := Sources/Agent/balancekeeperd.m
AGENT_HEADERS := Sources/Agent/DiagnosticLog.h
APP_SRC   := Sources/App/BalanceKeeperApp.swift

.PHONY: all clean install uninstall signing-identity release-app dmg release test diagnostic FORCE

all: $(APP)

# Local troubleshooting build with an in-memory diagnostic log.
diagnostic:
	$(MAKE) DIAGNOSTIC_LOG=1 all

FORCE:

define CHECK_LOGGING
	@set -e; for binary in $(1)/BalanceKeeper.app/Contents/MacOS/*; do \
		symbols=$$(nm -u "$$binary"); \
		if printf '%s\n' "$$symbols" | grep -E '_os_log|_NSLog'; then \
			echo "FAIL: logging symbols in $$binary"; exit 1; \
		fi; \
		echo "PASS: no logging symbols in $$binary"; \
	done
endef

$(BUILD)/agent-build-mode: FORCE
	@mkdir -p $(BUILD)
	@if [ ! -f $@ ] || [ "$$(cat $@)" != "$(DIAGNOSTIC_LOG)" ]; then echo "$(DIAGNOSTIC_LOG)" > $@; fi

# Checks use a private notification center without changing system settings.
test: $(BUILD)/app-moved-tests $(BUILD)/diagnostic-tests $(BUILD)/diagnostic-release-tests $(BUILD)/balancekeeperd-diagnostic-check
	$(BUILD)/app-moved-tests
	$(BUILD)/diagnostic-tests
	$(BUILD)/diagnostic-release-tests
	sh Tests/release-logging.sh
	$(MAKE) -B BUILD=.build/test-release SIGN_IDENTITY=- TIMESTAMP= DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS= all
	$(call CHECK_LOGGING,.build/test-release)

$(BUILD)/app-moved-tests: $(AGENT_SRC) $(AGENT_HEADERS) Tests/app-moved.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework CoreAudio -framework AudioToolbox Tests/app-moved.m -o $@

$(BUILD)/diagnostic-tests: $(AGENT_HEADERS) Tests/diagnostic.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DBALANCEKEEPER_DIAGNOSTIC_LOG -framework Foundation Tests/diagnostic.m -o $@

$(BUILD)/diagnostic-release-tests: $(AGENT_HEADERS) Tests/diagnostic.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation Tests/diagnostic.m -o $@

$(BUILD)/balancekeeperd-diagnostic-check: $(AGENT_SRC) $(AGENT_HEADERS)
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DBALANCEKEEPER_DIAGNOSTIC_LOG -framework Foundation -framework CoreAudio -framework AudioToolbox $(AGENT_SRC) -o $@

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(AGENT_HEADERS) $(APP_SRC) Resources/Info.plist Resources/$(AGENT_ID).plist $(wildcard Resources/AppIcon.icns) $(BUILD)/agent-build-mode Makefile | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(BUILD)/module-cache $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) $(AGENT_DIAGNOSTIC_FLAGS) -framework Foundation -framework CoreAudio -framework AudioToolbox $(AGENT_SRC) \
		-o $(CONTENTS)/MacOS/balancekeeperd
	swiftc -O -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) \
		$(APP_SRC) -o $(CONTENTS)/MacOS/BalanceKeeper
	sed -e 's/VERSION/$(VERSION)/' -e "s/BUILD_ID/$$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > $(CONTENTS)/Info.plist
ifeq ($(DIAGNOSTIC_LOG),1)
	/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion $(VERSION)d1' $(CONTENTS)/Info.plist
endif
	cp Resources/$(AGENT_ID).plist $(CONTENTS)/Library/LaunchAgents/
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(CONTENTS)/Resources/; fi
	codesign $(SIGN_FLAGS) --identifier $(AGENT_ID) $(CONTENTS)/MacOS/balancekeeperd
	codesign $(SIGN_FLAGS) $(STAGE)
	rm -rf $(APP)
	mv $(STAGE) $(APP)

# scripts/install.sh replaces the app and keeps the background agent working across updates.
install: $(APP)
	./scripts/install.sh $(APP)

release-app:
	@if [ "$(DIAGNOSTIC_LOG)" != "0" ]; then echo "Release builds require DIAGNOSTIC_LOG=0."; exit 1; fi
	@if [ -z "$(RELEASE_IDENTITY)" ]; then echo "Set RELEASE_IDENTITY (see the Makefile)."; exit 1; fi
	rm -rf $(RELEASE_DIR)
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS=
	$(call CHECK_LOGGING,$(RELEASE_DIR))

# Disk image only, without notarization: for checking the window layout.
dmg: release-app
	./scripts/make-dmg.sh $(RELEASE_DIR)/BalanceKeeper.app $(DMG) "$(RELEASE_IDENTITY)"

release: release-app
	./scripts/release.sh $(RELEASE_DIR)/BalanceKeeper.app $(DMG) "$(RELEASE_IDENTITY)" $(NOTARY_PROFILE)

uninstall:
	-pkill -x BalanceKeeper
	-/Applications/BalanceKeeper.app/Contents/MacOS/BalanceKeeper --unregister
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -rf /Applications/BalanceKeeper.app
	defaults delete io.github.fratayaydn.balancekeeper 2>/dev/null || true
	@echo "BalanceKeeper removed."

clean:
	rm -rf .build
