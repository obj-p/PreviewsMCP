VZ_DIR     := $(CURDIR)/../vz
VZ_BIN     := $(VZ_DIR)/.build/release/vz
STATE      := .state
BUNDLE     ?= $(CURDIR)/vm/merge-queue.bundle
IPSW       ?=
ADMIN_USER ?= admin

.PHONY: bundle snapshots clean
bundle: $(STATE)/post-toolchain

$(STATE):
	mkdir -p $(STATE)

$(STATE)/vz: | $(STATE)
	cd $(VZ_DIR) && ./build.sh release
	touch $@

$(STATE)/install: $(STATE)/vz | $(STATE)
	@echo "STUB install -> $(VZ_BIN) install $(BUNDLE) $(if $(IPSW),--ipsw $(IPSW),)--user $(ADMIN_USER)"
	touch $@

$(STATE)/setup: $(STATE)/install | $(STATE)
	@echo "STUB setup -> $(VZ_BIN) setup $(BUNDLE) (Setup Assistant to desktop)"
	touch $@

$(STATE)/ssh: $(STATE)/setup | $(STATE)
	@echo "STUB ssh -> provision sshd + authorized key, verify $(VZ_BIN) ssh $(BUNDLE) -- uname -a"
	touch $@

$(STATE)/toolchain: $(STATE)/ssh | $(STATE)
	@echo "STUB toolchain -> install Xcode + Homebrew + Bazel, runFirstLaunch, enable autologin"
	touch $@

$(STATE)/post-toolchain: $(STATE)/toolchain | $(STATE)
	@echo "STUB snapshot -> $(VZ_BIN) snapshot save $(BUNDLE) post-toolchain"
	touch $@

snapshots:
	$(VZ_BIN) snapshot list $(BUNDLE)

clean:
	rm -rf $(STATE) $(BUNDLE)
