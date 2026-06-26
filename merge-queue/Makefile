VZ_DIR     := $(CURDIR)/../vzy
VZ_BIN     := $(VZ_DIR)/.build/release/vzy
DEVBOX     := $(CURDIR)/../devbox
STATE      := .state
BUNDLE     ?= $(DEVBOX)/vm/devbox.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz
CANDIDATE  ?= HEAD
BASE       ?= origin/main
WARM_REF   ?= origin/main
KEY_HOME   ?= $(HOME)/.config/merge-queue
KEY_BUNDLE ?=
AGE_ID     ?= $(KEY_HOME)/identity.txt
PRINCIPAL  ?= merge-queue@local

.PHONY: bundle bar warm snapshots clean devbox-base
bundle: $(STATE)/post-ios

# With KEY_BUNDLE set (an age-encrypted bundle), the bar decrypts it on the host,
# injects the signing key onto a guest RAM disk, and signs the squashed range on
# green. Without it, the bar is a pure pass/fail test gate.
bar: $(STATE)/post-ios
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ios
	$(VZ_BIN) run $(CURDIR)/scripts/bar.swift $(BUNDLE) $(CANDIDATE) $(BASE) \
		$(if $(KEY_BUNDLE),$(KEY_BUNDLE) $(AGE_ID) $(PRINCIPAL),)

# Bake a warm bazel state (fetched @llvm_src + built externals) into post-ios so
# the bar never re-fetches LLVM source per run. warm.swift stops the VM cleanly,
# leaving the warmed disk to re-snapshot.
warm: $(STATE)/post-ios
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ios
	$(VZ_BIN) run $(CURDIR)/scripts/warm.swift $(BUNDLE) $(WARM_REF)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-ios
	$(VZ_BIN) snapshot take $(BUNDLE) post-ios

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
