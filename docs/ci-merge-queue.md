# CI merge queue

How `main` is gated: the self-hosted `bazel` suite runs only inside GitHub's
native merge queue, so every PR is tested already squashed onto `main` at merge
time. There is no per-push or per-PR run.

This is the GitHub-native queue (the `merge_group` event). It is unrelated to
the retired VM-backed design in `docs/local-merge-queue.md`, which was
decommissioned in #364.

## Why a queue

The runner is a single self-hosted Mac mini. Under the old
`push` + `pull_request` model with `cancel-in-progress`, a new commit on a ref
would cancel the in-flight run. That cancellation `SIGKILL`ed a running
`xcodebuild`/`simctl` mid-boot, and CoreSimulator kept the half-booted device
`Booted` after its controlling process died (which is why post-mortem `pgrep`
was always empty). The orphaned device degraded the shared
CoreSimulator/WindowServer for the *next* serial run, which surfaced as the
intermittent `agentDispatchesAppKitEvents` pump stall — #391.

The queue removes the trigger by construction: entries run on unique
`gh-readonly-queue/*` refs (nothing to cancel), so `cancel-in-progress` is gone
and no run kills another's simulator. Stream A (#394) adds a pre-job
CoreSimulator reset as a belt-and-suspenders backstop for any leftover state.

## Workflow triggers (`.github/workflows/ci.yml`)

- `merge_group` — the gate. GitHub places a queued PR on a temporary
  `gh-readonly-queue/main/*` ref and dispatches this event; the suite runs
  against the PR squashed onto `main`.
- `schedule` (weekly heartbeat, Sun 05:00 UTC) — toolchain/host drift + standing
  flake probe while the repo is quiet.
- `workflow_dispatch` — ad-hoc manual runs (e.g. to smoke a PR branch on demand,
  since there is no automatic per-PR run).

No `push`, no `pull_request`, no `concurrency` block.

## The main-ruleset flip (ruleset `14088159`)

The workflow change alone does nothing until the branch ruleset *requires* the
merge queue. Add a `merge_queue` rule to the existing `main` ruleset. The
required status check stays `bazel`; keep the other rules as-is.

**Invariant (the #1 merge-queue footgun):** the required check must run on
`merge_group`. It does — `bazel` triggers on `merge_group` above. If a required
check only ran on `pull_request`, the queue would hang forever waiting for a
check that never reports.

Recommended `merge_queue` parameters, tuned for one runner and low PR volume —
each PR forms its own group of one, is tested squashed onto `main`, and merges
before the next dequeues (deterministic, clean per-PR bisection, no batching
stall):

```json
{
  "type": "merge_queue",
  "parameters": {
    "merge_method": "SQUASH",
    "grouping_strategy": "ALLGREEN",
    "max_entries_to_build": 1,
    "max_entries_to_merge": 1,
    "min_entries_to_merge": 1,
    "min_entries_to_merge_wait_minutes": 0,
    "check_response_timeout_minutes": 120
  }
}
```

`merge_method: SQUASH` matches the repo's squash convention;
`check_response_timeout_minutes: 120` matches the job's `timeout-minutes`.

To apply (operator step — re-fetch the live rules first in case a sibling PR
changed the ruleset, then PATCH the full array with the `merge_queue` rule
appended):

```bash
gh api repos/obj-p/PreviewsMCP/rulesets/14088159 --jq '.rules'   # inspect current
# append the merge_queue rule above to that array, then:
gh api -X PUT repos/obj-p/PreviewsMCP/rulesets/14088159 -f name=main \
  -f target=branch -f enforcement=active --input rules.json         # rules.json = full updated array
```

## Activation sequence

This PR **lands last**, after the CI-hardening campaign. Order:

1. The de-flake campaign is complete on `main`: the CI-hygiene reset,
   `cancel-in-progress` removal (#403), the required-dedicated-sim fail-loud
   (#401), and the #368 HID-tap fix (#404) are all merged, and the full suite
   re-measured 0-flake uncached. This branch is cut fresh off that `main`, so
   its diff is scoped to `on:` only (the `concurrency` block was already gone).
2. Validate the new workflow with a manual `workflow_dispatch` on
   `flip-merge-queue` against a clean baseline. This is the gate for this PR —
   see "Why this PR cannot gate itself" below.
3. Merge this PR **and** flip the ruleset as one operator step. Preferred
   (surgical — keeps the required `bazel` gate *active* for every other PR, so
   nothing can merge ungated during the window): add the operator to
   `bypass_actors` on ruleset `14088159`, squash-merge this PR, then PATCH the
   ruleset to **add the `merge_queue` rule and remove the bypass in the same
   update**. Fallback if `bypass_actors` is awkward: briefly set `enforcement`
   to `disabled`, merge, re-enable with the `merge_queue` rule added — this drops
   the gate globally for the toggle window, so keep it to seconds. Either way the
   ruleset PATCH may be an owner-run step if the operator's tooling can't call
   the rulesets API.
4. Dry-run before trusting the queue — see below.

## Dry-run and rollback

Validate queue *mechanics* in isolation from any real PR's test outcome. Use a
throwaway guinea-pig PR (a one-line docs/comment change) that will reliably pass,
so a red means the queue is misconfigured, not that some feature broke.

1. Confirm the ruleset flip landed: `merge_queue` rule active, `bazel` required,
   and `merge_group` is on `main`'s `ci.yml`.
2. Open the guinea-pig PR and approve it.
3. Click **Merge when ready** — the PR enters the queue.
4. Confirm a workflow run appears on a `gh-readonly-queue/main/*` ref and the
   `bazel` job runs there (this is the `merge_group` event firing).
5. On green, GitHub squash-merges the entry automatically. Confirm `main`
   advanced and the PR closed as merged.

Failure triage:
- Entry sits queued with **no check** → `merge_group` is not on `main`'s
  `ci.yml` (the required check never reports; re-verify step 1).
- Check runs green but the entry **won't merge** → inspect the `merge_queue`
  params (`min_entries_to_merge`/`grouping_strategy`).
- Entry queued forever with no run starting → the single runner is offline/busy.

Rollback is not free: reverting to the pre-queue model means removing the
`merge_queue` rule **and** restoring the `push`/`pull_request` triggers in
`ci.yml` (a revert of this PR) — otherwise PRs get no gate at all. That coupling
is exactly why the guinea-pig dry-run runs before any real PR is queued.

### Why this PR cannot gate itself

A regular `pull_request` run uses the workflow file from the PR's **head** (the
base+head merge commit), not the base branch — which is exactly why the separate
`pull_request_target` event exists for jobs that need the base version. This
PR's head removes the `pull_request` trigger, so `bazel` does **not** run on this
PR. Because the ruleset requires the `bazel` check, that check is *missing* (not
failing), and a normal merge is blocked. Hence the `workflow_dispatch` gate
(step 2) and the bypass merge (step 3).

The same head-version rule opens a window the instant this PR merges: once
`main` has no `pull_request` trigger, any open PR gets no `bazel` run. With the
preferred `bypass_actors` approach the gate stays active, so those PRs are
*blocked* (fail-safe) until the queue is required; the `enforcement=disabled`
fallback instead lets them merge ungated, which is why it must be kept to
seconds. Flipping the ruleset in the same operator step as the merge (step 3)
closes the window either way.

`release.yml` is unchanged (already `tag`-only, never gated by this).
