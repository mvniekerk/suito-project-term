# projects-term — a tab-of-tabs terminal grouper for macOS.
#
# The terminal core is Rio's librio, consumed as the prebuilt RioKit
# xcframework (PTY + VT + grid + render state; no renderer, no windowing).
# Rendering, chrome and badges are ours, in Swift.

RIO_VERSION  := 0.5.28
RIO_ZIP      := RioKit.xcframework.zip
RIO_URL      := https://github.com/raphamorim/rio/releases/download/v$(RIO_VERSION)/$(RIO_ZIP)
# Recorded here because Rio's release checksums.txt does not cover this asset.
RIO_SHA256   := 23adc6ec49672bb5d5045da48aec704f91b2013d0e9b0b8930490d091453ed3f
RIO_XCF      := vendor/RioKit.xcframework

APP          := Suisto.app
CONFIG       ?= debug
BIN          := .build/$(CONFIG)/Suisto

.PHONY: all fetch-rio build release smoke test run bundle clean distclean

all: build

# --- dependency -------------------------------------------------------------

$(RIO_XCF):
	@mkdir -p vendor
	@echo "==> fetching RioKit.xcframework v$(RIO_VERSION)"
	@curl -sSL -o vendor/$(RIO_ZIP) "$(RIO_URL)"
	@echo "$(RIO_SHA256)  vendor/$(RIO_ZIP)" | shasum -a 256 -c - \
	  || { echo "!! checksum mismatch; refusing to extract"; exit 1; }
	@unzip -q -o vendor/$(RIO_ZIP) -d vendor/
	@echo "==> $(RIO_XCF) ready (macos-arm64)"

fetch-rio: $(RIO_XCF)

# --- build ------------------------------------------------------------------

build: $(RIO_XCF)
	swift build

release: $(RIO_XCF)
	swift build -c release
	@$(MAKE) bundle CONFIG=release

# Phase 0 gate: proves RioKit links, the PTY round-trips, and that the
# wakeup/action/render-state contract behaves. Must pass before anything else.
smoke: $(RIO_XCF)
	@swift build --product rio-smoke
	@./.build/debug/rio-smoke

test: $(RIO_XCF)
	swift test

# --- app bundle -------------------------------------------------------------

# SwiftPM produces a bare executable; AppKit needs a bundle to get a Dock
# icon, a menu bar and a proper activation policy.
bundle: $(RIO_XCF)
	@swift build $(if $(filter release,$(CONFIG)),-c release,)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@cp $(BIN) $(APP)/Contents/MacOS/Suisto
	@cp Resources/Icon/Suisto.icns $(APP)/Contents/Resources/Suisto.icns
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@codesign --force --sign - $(APP) 2>/dev/null || echo "   (ad-hoc signing skipped)"
	@echo "==> $(APP)"

run: bundle
	@open $(APP)

clean:
	swift package clean
	rm -rf $(APP)

# Also drops the vendored xcframework.
distclean: clean
	rm -rf vendor .build
