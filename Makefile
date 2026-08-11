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
LABEL   := io.github.jesusluque.wacomdri
AGENTS  := $(HOME)/Library/LaunchAgents
LOGDIR  := $(HOME)/Library/Logs
PLIST   := $(AGENTS)/$(LABEL).plist

.PHONY: install uninstall restart logs status

install: release
	mkdir -p $(PREFIX)/bin $(AGENTS) $(LOGDIR)
	cp $(BUILD_DIR)/wacomdrid $(PREFIX)/bin/wacomdrid
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q wacomdri-self-signed; then \
		echo "codesign (stable identity)"; \
		codesign --force --sign wacomdri-self-signed \
			--identifier $(LABEL) $(PREFIX)/bin/wacomdrid; \
	else \
		echo "codesign (ad-hoc — Privacy permissions will need re-granting after"; \
		echo "          each rebuild; run 'make signing-identity' to avoid that)"; \
		codesign --force --sign - --identifier $(LABEL) $(PREFIX)/bin/wacomdrid; \
	fi
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

## --- Stable signing identity ------------------------------------------------

# Ad-hoc signatures identify a program by the hash of its contents, so every
# rebuild looks like a different program to macOS and the Privacy permissions
# granted to the previous build stop applying. That turns every update into a
# round of re-granting Input Monitoring and Accessibility by hand.
#
# Signing with a real identity fixes it: the requirement becomes the certificate
# and the identifier, both of which survive a rebuild. A self-signed certificate
# is enough — this is never distributed, so there is nothing to notarise.
#
# Run once:  make signing-identity
SIGN_NAME := wacomdri-self-signed
SIGN_ID    = $(shell security find-identity -v -p codesigning 2>/dev/null \
               | grep -c "$(SIGN_NAME)")

.PHONY: signing-identity

signing-identity:
	@if security find-identity -v -p codesigning | grep -q "$(SIGN_NAME)"; then \
		echo "Signing identity '$(SIGN_NAME)' already exists."; \
	else \
		echo "Creating a self-signed code signing certificate…"; \
		tmp=$$(mktemp -d); \
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
			-keyout $$tmp/key.pem -out $$tmp/cert.pem \
			-subj "/CN=$(SIGN_NAME)" \
			-addext "basicConstraints=critical,CA:false" \
			-addext "keyUsage=critical,digitalSignature" \
			-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
		openssl pkcs12 -export -out $$tmp/id.p12 -inkey $$tmp/key.pem \
			-in $$tmp/cert.pem -passout pass: 2>/dev/null; \
		security import $$tmp/id.p12 -k ~/Library/Keychains/login.keychain-db \
			-T /usr/bin/codesign -P "" ; \
		security add-trusted-cert -r trustRoot \
			-k ~/Library/Keychains/login.keychain-db $$tmp/cert.pem ; \
		rm -rf $$tmp; \
		echo "Done. Re-run 'make install', then grant the permissions once more."; \
		echo "They will survive rebuilds from now on."; \
	fi

## --- System Settings pane ---------------------------------------------------

# No space in the bundle's file name: make splits target names on whitespace and
# a quoted path does not help. The name shown in System Settings comes from
# CFBundleName in the Info.plist, so nothing is lost.
PANE := $(BUNDLE_DIR)/WacomIntuos3.prefPane
PANE_INSTALLED := $(HOME)/Library/PreferencePanes/WacomIntuos3.prefPane

.PHONY: pane install-pane uninstall-pane

pane: $(PANE)

# SwiftPM has no notion of a loadable macOS bundle, so it builds a dynamic
# library and the bundle is assembled around it here.
$(PANE): build Packaging/WacomdriPane-Info.plist
	rm -rf $(PANE)
	mkdir -p $(PANE)/Contents/MacOS $(PANE)/Contents/Resources
	cp Packaging/WacomdriPane-Info.plist $(PANE)/Contents/Info.plist
	cp $(BUILD_DIR)/libWacomdriPane.dylib $(PANE)/Contents/MacOS/WacomdriPane
	install_name_tool -id WacomdriPane $(PANE)/Contents/MacOS/WacomdriPane
	codesign --force --deep --sign - $(PANE)
	@echo "built $(PANE)"

install-pane: $(PANE)
	mkdir -p $(HOME)/Library/PreferencePanes
	rm -rf $(PANE_INSTALLED)
	cp -R $(PANE) $(PANE_INSTALLED)
	@echo "Installed. It appears at the bottom of the System Settings sidebar."

uninstall-pane:
	rm -rf $(PANE_INSTALLED)
