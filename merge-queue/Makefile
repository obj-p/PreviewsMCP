VZ_DIR     := $(CURDIR)/../vz
VZ_BIN     := $(VZ_DIR)/.build/release/vz
STATE      := .state
BUNDLE     ?= $(CURDIR)/vm/merge-queue.bundle
IPSW       ?=
ADMIN_USER ?= admin
ADMIN_PASS ?= vz
CPUS       ?= 4
MEM_MIB    ?= 8192
DISK_GIB   ?= 120
XCODE_VER  ?= 26.3
XCODE_XIP  ?=
XIP_CACHE  ?= $(HOME)/.cache/merge-queue/xcode
SA_RETRIES ?= 3
SSH_RETRIES ?= 2

.PHONY: bundle snapshots clean
bundle: $(STATE)/post-toolchain

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
	$(VZ_BIN) setup $(BUNDLE) --transport vnc --preset explore-click-vnc --retry $(SA_RETRIES) --restore-from base --output-dir $(CURDIR)/$(STATE)/sa-logs
	$(VZ_BIN) snapshot take $(BUNDLE) post-sa
	touch $@

$(STATE)/ssh: $(STATE)/setup | $(STATE)
	$(VZ_BIN) setup $(BUNDLE) --transport vnc --preset provision-ssh --retry $(SSH_RETRIES) --restore-from post-sa --output-dir $(CURDIR)/$(STATE)/ssh-logs
	$(VZ_BIN) snapshot take $(BUNDLE) post-ssh
	touch $@

$(STATE)/toolchain: $(STATE)/ssh | $(STATE)
	VZ_BIN="$(VZ_BIN)" BUNDLE="$(BUNDLE)" XCODE_VER="$(XCODE_VER)" XCODE_XIP="$(XCODE_XIP)" XIP_CACHE="$(XIP_CACHE)" ADMIN_USER="$(ADMIN_USER)" ADMIN_PASS="$(ADMIN_PASS)" STATE="$(CURDIR)/$(STATE)" ./provision-toolchain.sh
	touch $@

$(STATE)/post-toolchain: $(STATE)/toolchain | $(STATE)
	$(VZ_BIN) snapshot take $(BUNDLE) post-toolchain
	touch $@

snapshots:
	$(VZ_BIN) snapshot list $(BUNDLE)

clean:
	rm -rf $(STATE) $(BUNDLE)
