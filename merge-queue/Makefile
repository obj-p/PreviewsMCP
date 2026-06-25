VZ_DIR     := $(CURDIR)/../vz
VZ_BIN     := $(VZ_DIR)/.build/release/vz
DEVBOX     := $(CURDIR)/../devbox
STATE      := .state
BUNDLE     ?= $(DEVBOX)/vm/devbox.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz

.PHONY: bundle snapshots clean devbox-base
bundle: $(STATE)/post-ios

devbox-base:
	$(MAKE) -C $(DEVBOX) post-toolchain

$(STATE):
	mkdir -p $(STATE)

$(STATE)/ios: | devbox-base $(STATE)
	$(VZ_BIN) snapshot restore $(BUNDLE) post-toolchain
	$(VZ_BIN) run $(CURDIR)/scripts/ios.swift $(BUNDLE)
	touch $@

$(STATE)/post-ios: $(STATE)/ios | $(STATE)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-ios 2>/dev/null || true
	$(VZ_BIN) snapshot take $(BUNDLE) post-ios
	touch $@

snapshots:
	$(VZ_BIN) snapshot list $(BUNDLE)

clean:
	rm -rf $(STATE)
