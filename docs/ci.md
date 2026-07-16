# CI: the on-demand label gate

`main` is protected by one required status check, `ci`, which builds, lints, and
runs the full Bazel suite on the self-hosted Mac mini. It is an **on-demand
gate**: nothing runs automatically on push. You run it by labeling the PR, and a
green run on an up-to-date branch is what lets the PR merge. This gives
merge-queue semantics (test the merged result, no redundant runs) without a
merge queue, which GitHub does not offer for this repo.

## The two labels

- **`ci`** — run the suite on the PR. Test only, does not merge. Use it while
  iterating.
- **`merge`** — run the suite (if this commit is not already green) **and** arm
  GitHub auto-merge. Once `ci` is green and the branch is up to date, GitHub
  squash-merges the PR on its own. If the suite fails, nothing merges.

Adding `merge` after a green `ci` on the same commit does **not** re-run the
suite: the `ci` job sees the existing green check for that commit and exits fast,
so auto-merge lands it without a second full run.

## Test tiers

The required `ci` job runs tests in two ordered Bazel steps after lint:

1. **Unit:** `bazel test //... --test_tag_filters=-integration` runs the
   in-process, parallel-safe targets first.
2. **Integration:** `bazel test //... --test_tag_filters=integration` runs the
   simulator, daemon, agent, and AppKit targets only after the unit tier passes.

A unit failure stops the job before the slow integration tier, while either
tier failing still blocks the merge through the same required `ci` check. The
`integration` tag is only a selection label; existing `exclusive` tags and
runtime simulator locks continue to control scheduling and isolation.

## Normal flow

1. Open the PR. Nothing runs.
2. Rebase onto the latest `main` (`git rebase origin/main` and force-push). The
   ruleset requires the branch be up to date, so this is what makes the run test
   the actual merged result.
3. Add the **`merge`** label. The suite runs once, and on green the PR
   auto-merges (squash). Or add **`ci`** first if you just want to see it pass
   without merging, then **`merge`** when ready.
4. If `main` advances before the merge, the up-to-date requirement blocks it.
   Rebase again and re-add the label to re-run.

Re-running after a new push means removing and re-adding the label — the
`labeled` event only fires when a label is newly added. The same remove-then-add
re-runs the gate after a spurious flake (e.g. the #368 tap residual), which is
why a low-rate flake never permanently blocks a PR under this gate.

## Why on-demand

The runner is a single serial Mac mini. Auto-running on every push would queue
redundant work and, with `cancel-in-progress`, would SIGKILL simulator boots and
leak state that wedges CoreSimulator (the #391 flake). Label-gating means a push
never starts a run, so there is nothing to cancel and no redundant work. There is
deliberately no `concurrency` / `cancel-in-progress` block — do not add one.

## Triggers (`.github/workflows/ci.yml`)

- `pull_request` `types: [labeled]` — the `ci` / `merge` gate above.
- `schedule` (weekly, Sun 05:00 UTC) — catches runner/toolchain drift and acts
  as a standing flake probe while the repo is quiet.
- `workflow_dispatch` — ad-hoc manual run.

A separate `cleanup.yml` (`pull_request` `types: [closed]`, hosted runner)
deletes the head branch of every merged same-repo PR. The repo's native
delete-on-merge setting fires unreliably when auto-merge lands the squash
via the Actions token, so the workflow owns the deletion.

## Ruleset (`main`, id 14088159)

- **Require a pull request before merging.**
- **Require status checks to pass:** context `ci`, with **Require branches to be
  up to date before merging** on (this is the "test the merged result" half).
- **Block force pushes**, **Restrict deletions**.

The required-check context (`ci`) must equal the job name in `ci.yml`. Rename one
and you must rename the other, or the required check goes "missing" and no PR can
merge.
