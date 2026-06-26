VZ_DIR     := $(CURDIR)/../vzy
VZ_BIN     := $(VZ_DIR)/.build/release/vzy
VM_DIR     := $(CURDIR)/../vm
STATE      := .state
BUNDLE     ?= $(VM_DIR)/macos.bundle
ADMIN_USER ?= admin
ADMIN_PASS ?= vzvz
CANDIDATE  ?= HEAD
BASE       ?= origin/main
WARM_REF   ?= origin/main
KEY_HOME   ?= $(HOME)/.config/merge-queue
KEY_BUNDLE ?=
AGE_ID     ?= $(KEY_HOME)/identity.txt
PRINCIPAL  ?= merge-queue@local
REPO       ?=
# Landing must commit under an account-linked email or GitHub won't verify the
# signature, so derive the account noreply only when REPO is set (lazy: no gh
# call for plain test/sign runs).
NOREPLY     = $(shell gh api user --jq '(.id|tostring) + "+" + .login + "@users.noreply.github.com"')
LAND_PRINCIPAL = $(if $(REPO),$(NOREPLY),$(PRINCIPAL))
QUEUE_DIR  ?= $(CURDIR)/.queue
QUEUE_GIT  := $(QUEUE_DIR)/queue.git

.PHONY: bundle bar warm queue-init snapshots clean vm-base
bundle: $(STATE)/post-ios

# Modes by argument: no KEY_BUNDLE = pure pass/fail test gate; KEY_BUNDLE alone =
# sign the squashed range on green (dry-run, no push); KEY_BUNDLE + REPO = land,
# i.e. sign then push to REPO main from the VM via the deploy key.
bar: $(STATE)/post-ios
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ios
	$(VZ_BIN) run $(CURDIR)/scripts/bar.swift $(BUNDLE) $(CANDIDATE) $(BASE) \
		$(if $(KEY_BUNDLE),$(KEY_BUNDLE) $(AGE_ID) $(LAND_PRINCIPAL) $(REPO),)

# Bake a warm bazel state (fetched @llvm_src + built externals) into post-ios so
# the bar never re-fetches LLVM source per run. warm.swift stops the VM cleanly,
# leaving the warmed disk to re-snapshot.
warm: $(STATE)/post-ios
	$(VZ_BIN) snapshot restore $(BUNDLE) post-ios
	$(VZ_BIN) run $(CURDIR)/scripts/warm.swift $(BUNDLE) $(WARM_REF)
	$(VZ_BIN) snapshot delete $(BUNDLE) post-ios
	$(VZ_BIN) snapshot take $(BUNDLE) post-ios

# Create the bare queue remote + pre-receive hook. Pushing a candidate to it
# lands the change through the bar (REPO + KEY_BUNDLE baked into the hook).
#   make queue-init KEY_BUNDLE=~/.config/merge-queue/bundle.age REPO=obj-p/PreviewsMCP
#   git remote add queue $(QUEUE_GIT) && git push queue <branch>
queue-init:
	@test -n "$(REPO)" || { echo "set REPO=<owner/repo> (and KEY_BUNDLE) to land" >&2; exit 1; }
	git init -q --bare $(QUEUE_GIT)
	sed -e 's|__WORKTREE__|$(abspath $(CURDIR)/..)|' \
	    -e 's|__KEY_BUNDLE__|$(KEY_BUNDLE)|' \
	    -e 's|__TARGET_REPO__|$(REPO)|' \
	    $(CURDIR)/scripts/queue-hook.sh > $(QUEUE_GIT)/hooks/pre-receive
	chmod +x $(QUEUE_GIT)/hooks/pre-receive
	@echo "queue ready at $(QUEUE_GIT)"
	@echo "  git remote add queue $(QUEUE_GIT) && git push queue <branch>"

vm-base:
	$(MAKE) -C $(VM_DIR) post-toolchain

$(STATE):
	mkdir -p $(STATE)

$(STATE)/ios: | vm-base $(STATE)
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
