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

# Dump raw HID reports. Seizing the device requires root, hence sudo.
# Capture fixtures with:  make probe | tee fixtures/raw.txt
probe: build
	sudo $(BUILD_DIR)/wacomdri-probe

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
