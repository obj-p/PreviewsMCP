VZ_DIR     := $(CURDIR)/../vz
VZ_BIN     := $(VZ_DIR)/.build/release/vz
STATE      := .state
BUNDLE     ?= $(CURDIR)/vm/devbox.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz
CPUS       ?= 4
MEM_MIB    ?= 8192
DISK_GIB   ?= 120
XCODE_VER  ?= 26.3
IPSW       ?= https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-88870/E47EBB85-45F2-4E3C-B9E7-6FF7868C2FBA/UniversalMac_26.5.1_25F80_Restore.ipsw
XCODE_XIP  ?=
XIP_CACHE  ?= $(HOME)/.cache/merge-queue/xcode
XIP        := $(or $(XCODE_XIP),$(firstword $(wildcard $(XIP_CACHE)/Xcode*.xip)))
SA_RETRIES ?= 3
SSH_RETRIES ?= 2

.PHONY: bundle post-toolchain snapshots clean xcode-xip
bundle: $(STATE)/post-toolchain
post-toolchain: $(STATE)/post-toolchain

xcode-xip:
	command -v xcodes >/dev/null || { echo "xcodes not found; run bootstrap (Brewfile)" >&2; exit 1; }
	mkdir -p $(XIP_CACHE)
	xcodes download "$(XCODE_VER)" --directory "$(XIP_CACHE)"

$(STATE):
	mkdir -p $(STATE)

$(STATE)/vz: | $(STATE)
	cd $(VZ_DIR) && ./build.sh release
	touch $@

$(STATE)/install: $(STATE)/vz | $(STATE)
	$(VZ_BIN) install $(BUNDLE) $(if $(IPSW),--ipsw $(IPSW) ,)--cpu-count $(CPUS) --memory-mib $(MEM_MIB) --disk-gib $(DISK_GIB) --ssh-username $(ADMIN_USER)
	$(VZ_BIN) snapshot take $(BUNDLE) base
	touch $@

$(STATE)/setup: $(STATE)/install | $(STATE)
	$(VZ_BIN) run $(CURDIR)/scripts/setup.swift $(BUNDLE) base $(SA_RETRIES)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-sa 2>/dev/null || true
	$(VZ_BIN) snapshot take $(BUNDLE) post-sa
	touch $@

$(STATE)/ssh: $(STATE)/setup | $(STATE)
	$(VZ_BIN) setup $(BUNDLE) --transport vnc --preset provision-ssh --retry $(SSH_RETRIES) --restore-from post-sa --output-dir $(CURDIR)/$(STATE)/ssh-logs
	$(VZ_BIN) snapshot delete $(BUNDLE) post-ssh 2>/dev/null || true
	$(VZ_BIN) snapshot take $(BUNDLE) post-ssh
	touch $@

$(STATE)/toolchain: $(STATE)/ssh | $(STATE)
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ssh
	$(VZ_BIN) run $(CURDIR)/scripts/toolchain.swift $(BUNDLE) $(XIP)
	touch $@

$(STATE)/post-toolchain: $(STATE)/toolchain | $(STATE)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-toolchain 2>/dev/null || true
	$(VZ_BIN) snapshot take $(BUNDLE) post-toolchain
	touch $@

snapshots:
	$(VZ_BIN) snapshot list $(BUNDLE)

clean:
	rm -rf $(STATE) $(BUNDLE)
