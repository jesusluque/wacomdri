# wacomdri — userspace macOS driver for the Wacom Intuos3 (PTZ-630)
#
# Everything builds from the command line with ad-hoc signing; no Xcode project
# and no Apple Developer account are required.

CONFIG      ?= debug
BUILD_DIR   := .build/$(CONFIG)
BUNDLE_DIR  := .build/bundles
SWIFT_FLAGS := $(if $(filter release,$(CONFIG)),-c release,)

.PHONY: all build release test clean probe list scope

all: build

build:
	swift build $(SWIFT_FLAGS)

release:
	$(MAKE) CONFIG=release build

test:
	swift test

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR)

## --- Milestone 1 de-risking tools -------------------------------------------

# List every HID device. Useful for confirming the tablet's actual VID/PID
# before assuming it is 056a:00b1.
list: build
	$(BUILD_DIR)/wacomdri-probe --list

# Dump raw HID reports. No root needed: Input Monitoring is enough, and seizing
# the device succeeds as a normal user.
# Capture fixtures with:  make probe | tee fixtures/raw.txt
probe: build
	$(BUILD_DIR)/wacomdri-probe --no-seize

# Inspect what actually arrives as NSEvent tablet data.
scope: $(BUNDLE_DIR)/PressureScope.app
	open -W $(BUNDLE_DIR)/PressureScope.app

## --- Bundle assembly --------------------------------------------------------

# A SwiftPM executable is a bare Mach-O. AppKit apps need a bundle to get a
# stable identity for TCC and a proper activation policy, so assemble one by
# hand. The same recipe serves the preferences app later.
$(BUNDLE_DIR)/PressureScope.app: build Packaging/PressureScope-Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS
	cp Packaging/PressureScope-Info.plist $@/Contents/Info.plist
	cp $(BUILD_DIR)/PressureScope $@/Contents/MacOS/PressureScope
	codesign --force --sign - $@
	@echo "built $@"

## --- Install ----------------------------------------------------------------

# Everything installs into the user's home: the driver is a LaunchAgent, not a
# system daemon, so nothing here needs sudo.
PREFIX  ?= $(HOME)/.local
LABEL   := tv.mediapro.wacomdri
AGENTS  := $(HOME)/Library/LaunchAgents
LOGDIR  := $(HOME)/Library/Logs
PLIST   := $(AGENTS)/$(LABEL).plist

.PHONY: install uninstall restart logs status

install: release
	mkdir -p $(PREFIX)/bin $(AGENTS) $(LOGDIR)
	cp $(BUILD_DIR)/wacomdrid $(PREFIX)/bin/wacomdrid
	codesign --force --sign - $(PREFIX)/bin/wacomdrid
	sed -e 's|__PREFIX__|$(PREFIX)|g' -e 's|__LOGDIR__|$(LOGDIR)|g' \
		Packaging/$(LABEL).plist > $(PLIST)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	@echo
	@echo "Installed. The first run will ask for Input Monitoring, and needs"
	@echo "Accessibility granted to $(PREFIX)/bin/wacomdrid for events to reach"
	@echo "applications: System Settings > Privacy & Security."
	@echo "Logs: $(LOGDIR)/wacomdri.log"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(PREFIX)/bin/wacomdrid
	@echo "Uninstalled. Config left at $(HOME)/Library/Application Support/wacomdri."

restart:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(PLIST)

status:
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | head -20 \
		|| echo "not loaded"

logs:
	tail -f $(LOGDIR)/wacomdri.log

# The preferences app.
prefs: $(BUNDLE_DIR)/Wacom\ Intuos3.app
	open "$(BUNDLE_DIR)/Wacom Intuos3.app"

$(BUNDLE_DIR)/Wacom\ Intuos3.app: build Packaging/WacomdriPrefs-Info.plist
	rm -rf "$@"
	mkdir -p "$@/Contents/MacOS"
	cp Packaging/WacomdriPrefs-Info.plist "$@/Contents/Info.plist"
	cp $(BUILD_DIR)/WacomdriPrefs "$@/Contents/MacOS/WacomdriPrefs"
	codesign --force --sign - "$@"
	@echo "built $@"
