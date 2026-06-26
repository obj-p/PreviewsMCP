#!/usr/bin/env bash
# pre-receive hook for the merge-queue bare repo. Every push of a candidate is
# landed through the bar (rebase onto origin/main, test, sign, deploy-key push).
# The push is accepted only if the land succeeds, so `git push queue <branch>`
# succeeds exactly when the change reaches main verified. This is the enforced
# entry: there is no land path that skips the bar.
#
# Placeholders are filled in by `make queue-init`.
set -euo pipefail

WORKTREE="__WORKTREE__"
KEY_BUNDLE="__KEY_BUNDLE__"
TARGET_REPO="__TARGET_REPO__"
ZERO=0000000000000000000000000000000000000000

while read -r _old newsha ref; do
  [ "$newsha" = "$ZERO" ] && continue # branch deletion
  echo "==> merge-queue: landing ${ref#refs/heads/} (${newsha:0:12})" >&2

  # The pushed objects are quarantined during pre-receive, so transfer the
  # candidate into the worktree from inside the hook (which can see them).
  # Unset only the quarantine flag: the push still reads the objects via
  # GIT_OBJECT_DIRECTORY, but the receiving repo no longer refuses the ref
  # update for being "inside a quarantine environment".
  ( unset GIT_QUARANTINE_PATH
    git push -q "$WORKTREE" "$newsha:refs/mq/incoming" )

  # Run the bar in a clean git environment rooted at the worktree.
  (
    unset GIT_DIR GIT_WORK_TREE GIT_QUARANTINE_PATH \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    cd "$WORKTREE"
    git fetch -q origin main
    make -s -C "$WORKTREE/merge-queue" bar \
      CANDIDATE="$newsha" BASE=origin/main \
      KEY_BUNDLE="$KEY_BUNDLE" REPO="$TARGET_REPO"
  ) >&2
done
