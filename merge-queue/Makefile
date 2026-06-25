VZ_DIR     := $(CURDIR)/../vzy
VZ_BIN     := $(VZ_DIR)/.build/release/vzy
DEVBOX     := $(CURDIR)/../devbox
STATE      := .state
BUNDLE     ?= $(DEVBOX)/vm/devbox.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz
CANDIDATE  ?= HEAD
BASE       ?= origin/main

.PHONY: bundle bar snapshots clean devbox-base
bundle: $(STATE)/post-ios

bar: $(STATE)/post-ios
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ios
	$(VZ_BIN) run $(CURDIR)/scripts/bar.swift $(BUNDLE) $(CANDIDATE) $(BASE)

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
