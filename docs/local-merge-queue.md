# Local merge queue — design

Design for replacing GitHub Actions with a local, VM-backed merge queue.
Verification runs on hardware we control, commits that pass are signed by a
key that exists only inside the VM, and a GitHub ruleset makes that VM the
only thing able to update `main`.

## Motivation

GitHub Actions has been unreliable and slow for this repository (most
recently: the JIT executor's LLVM cache would not persist, see
`.claude/handoffs/2026-06-04-jit-phase4-ci.md`). The bar to merge is already
defined as local unit tests plus example integration tests. This design makes
that bar enforceable rather than honor-system.

## Prior art

[no-mistakes](https://github.com/kunchenguid/no-mistakes) is a local git
proxy: you push to a `no-mistakes` remote instead of `origin`, it runs a
verification pipeline in a disposable worktree, and forwards to the real
remote only on success. Its merge gate on GitHub is a marker string in the
PR body checked by a small Action, which proves nothing cryptographically.
This design keeps the proxy-remote shape and replaces the marker with a
signature from a key the verification environment alone holds.

The result is a single-worker merge queue: every change is rebased onto the
latest `main` and verified in that exact post-merge state before it lands,
and landings are serialized.

## Architecture

```
developer                    host (Mac)                      GitHub
─────────                    ──────────                      ──────
git push queue main   ──►    bare repo + hook
                             │
                             ▼
                             restore VM from snapshot
                             push SHAs into VM over SSH
                                  │
                                  ▼  (inside VM)
                             fresh worktree at exact SHA
                             rebase onto origin/main
                             lint + unit + integration tests
                             sign commits (SSH key, VM-only)
                             push signed SHAs:
                               1. to the PR branch        ──►  PR marked merged
                               2. fast-forward main       ──►  via deploy key
                                  │                            (ruleset bypass)
                                  ▼
                             host resets local branch to signed SHAs
```

### 1. Trigger: proxy remote

A bare repository on the host acts as the `queue` remote. Its receive hook
starts the harness. The real `origin` is never the default push target for
landings, so the gate cannot be skipped by accident. Feature branches still
push to `origin` normally for review; only updates to `main` go through the
queue.

### 2. Verification: clean worktree inside a VM

The harness restores a macOS VM from a snapshot (built on the `research/vm/`
kit and its `post-ssh` checkpoint), pushes the exact SHAs into a bare repo
inside the VM over SSH, and checks them out into a fresh worktree. Only
committed state is verified — uncommitted files, stale build products, and
untracked configs cannot influence the result.

A `post-toolchain` snapshot tier holds everything `bootstrap --examples
--jit` installs: Xcode, brew deps, the LLVM and orc-runtime builds, and the
example projects' dependencies. Per run the VM only fetches commits, builds,
and tests. Refreshing the snapshot is an explicit, versioned event — the
replacement for CI cache, with no silent eviction.

The in-VM pipeline runs:

- `bazel test //...`
- `bazel run //tools/lint:check` (hermetic, Bazel-pinned SwiftFormat,
  SwiftLint, clang-format, and buildifier)

The documented merge bar also requires the example integration tests;
those are not yet part of the in-VM pipeline (`examples/` is excluded
from the Bazel graph).

### 3. Attestation: SSH commit signing

The VM generates an SSH signing keypair when the snapshot is built; the
private key never leaves the VM. After the pipeline passes, the in-VM script
rewrites the verified range with `git rebase --gpg-sign` (`gpg.format ssh`)
so every commit carries the signature. The signature means exactly: this
tree passed the pipeline in a clean VM.

The public key is checked into the repo as `allowed_signers`, so anyone can
audit `main` locally:

```
git config gpg.ssh.allowedSignersFile allowed_signers
git verify-commit <sha>
```

Signing rewrites SHAs. The landed history is the signed rewrite, and the
local branch is reset to match after each landing.

### 4. Merge gate: deploy key + ruleset

GitHub enforcement uses no Actions:

- A read-write **deploy key** on the repo whose private half lives only in
  the VM. This is the identity the VM pushes `main` with.
- A **ruleset** on `main` that blocks all updates, with deploy keys as the
  only bypass actor. This is enforced at the ref level, so it also blocks
  the web UI merge buttons (which would otherwise land commits signed by
  GitHub's own web-flow key, the loophole in the built-in
  require-signed-commits rule).
- The built-in **require signed commits** rule as a free second layer: the
  VM key is the only signing key registered on the account, so unsigned
  local commits cannot land even if the ruleset is misconfigured.

The VM key must remain the only read-write deploy key, since the bypass
entry covers all deploy keys on the repo.

## Landing flow

1. Open a PR from a feature branch as usual; review happens on GitHub.
2. To land, push the branch to the `queue` remote.
3. The VM restores from snapshot, rebases the branch onto current
   `origin/main`, and runs the pipeline on that exact post-merge state.
4. On success the VM signs the rebased commits, force-pushes them to the PR
   branch, then fast-forwards `main` to the same SHAs over the deploy key.
5. GitHub sees the PR head become reachable from `main` and marks the PR
   merged (same mechanism as command-line merges).
6. The host resets the local branch to the signed SHAs.

On failure nothing is pushed anywhere; the harness surfaces the log.

## Threat model

The adversary is workflow slop — an agent or a hurried human pushing
unverified code to `main` — not a malicious attacker. The signing key sits
on a disk image on the same Mac, so a determined human could extract it.
That is accepted: the VM boundary makes the lazy path impossible, which is
what local CI needs. GitHub's permission layer (deploy key + ruleset) is
what actually holds the door; the signature is the audit trail.

## Open questions

- Whether to bake warm SwiftPM/Bazel build caches into the snapshot for
  speed, at the cost of a less pristine environment.
- Per-push vs per-merge verification tiers: the full pipeline per landing is
  the requirement; whether feature-branch pushes get a cheaper tier is open.
- Batching: the queue is single-worker. If landings ever back up, the
  harness can batch several approved branches into one VM run (Bors-style).

## Implementation phases

1. **VM pipeline**: `post-toolchain` snapshot; in-VM script that checks out
   a SHA, runs the pipeline, signs on green. Verify: a known-good SHA comes
   back signed, a known-bad SHA is rejected.
2. **Host harness**: bare `queue` remote + receive hook driving VM restore,
   push-in, result collection, branch reset. Verify: end-to-end landing on a
   scratch repo.
3. **GitHub cutover**: deploy key, ruleset on `main` with deploy-key bypass,
   require-signed-commits, `allowed_signers` checked in, disable Actions
   workflows. Verify: account push to `main` rejected, web merge button
   blocked, VM landing succeeds and PR shows merged.
