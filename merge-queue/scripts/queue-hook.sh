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

# Best-effort: comment the landed SHA on the candidate branch's open PR and
# close it. Runs host-side with the host's gh auth — the VM stays push-only and
# never touches the GitHub API. Never fails the push: main has already moved, so
# any gh error here is logged and ignored.
close_landed_pr() {
  local branch="$1" landed pr
  landed="$(gh api "repos/$TARGET_REPO/commits/main" --jq '.sha' 2>/dev/null)" || return 1
  pr="$(gh pr list --repo "$TARGET_REPO" --head "$branch" --state open \
        --json number --jq '.[0].number' 2>/dev/null)" || return 1
  [ -n "$pr" ] || { echo "==> merge-queue: no open PR for $branch" >&2; return 0; }
  gh pr comment "$pr" --repo "$TARGET_REPO" \
    --body "Landed on \`main\` as $landed via the merge queue." >/dev/null 2>&1 || return 1
  gh pr close "$pr" --repo "$TARGET_REPO" >/dev/null 2>&1 || return 1
  echo "==> merge-queue: closed PR #$pr (landed ${landed:0:12})" >&2
}

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

  # The land succeeded (set -e would have aborted the hook otherwise).
  close_landed_pr "${ref#refs/heads/}" \
    || echo "==> merge-queue: PR close skipped (gh unavailable or errored)" >&2
done
