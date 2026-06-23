VZ_DIR     := $(CURDIR)/../vz
VZ_BIN     := $(VZ_DIR)/.build/release/vz
DEVBOX     := $(CURDIR)/../devbox
STATE      := .state
BUNDLE     ?= $(DEVBOX)/vm/devbox.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz
REPO_ROOT  ?= $(CURDIR)/..
JIT_CACHE  ?= /Users/$(ADMIN_USER)/jit-cache

.PHONY: bundle snapshots clean devbox-base
bundle: $(STATE)/post-ios

devbox-base:
	$(MAKE) -C $(DEVBOX) post-toolchain

$(STATE):
	mkdir -p $(STATE)

$(STATE)/jit: | devbox-base $(STATE)
	$(VZ_BIN) snapshot restore $(BUNDLE) post-toolchain
	$(VZ_BIN) run $(CURDIR)/scripts/jit.swift $(BUNDLE) $(REPO_ROOT) $(JIT_CACHE)
	touch $@

$(STATE)/post-jit: $(STATE)/jit | $(STATE)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-jit 2>/dev/null || true
	$(VZ_BIN) snapshot take $(BUNDLE) post-jit
	touch $@

$(STATE)/ios: $(STATE)/post-jit | $(STATE)
	$(VZ_BIN) snapshot restore $(BUNDLE) post-jit
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
