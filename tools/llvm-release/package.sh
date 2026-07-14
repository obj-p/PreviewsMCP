#!/usr/bin/env bash
#
# Build and publish the pinned swiftlang/llvm-project sparse source archive that
# @llvm_src fetches (see bazel/llvm.bzl + the MODULE.bazel llvm_repository pin).
#
# The archive is the exact tree the retired ctx.execute(git) repo rule produced:
# a shallow + partial + cone-sparse checkout of the fork at a Swift release tag,
# minus .git. Patches (patches/llvm-*.patch) are NOT baked in — llvm.bzl applies
# them at fetch time via ctx.patch. This turns an LLVM/Swift version bump into
# one command: check out the fork at a new tag, tar it deterministically, create
# the GitHub release, upload the asset, and print the url + sha256 to paste into
# MODULE.bazel.
#
# Usage:
#   tools/llvm-release/package.sh <fork-tag> [--publish]
#     <fork-tag>   a swiftlang/llvm-project tag, e.g. swift-6.2.3-RELEASE
#     --publish    create the GitHub release + upload the asset (default: build
#                  the archive and print the sha256 only, no network writes)
#
# Env overrides:
#   LLVM_REMOTE          fork remote (default swiftlang/llvm-project)
#   LLVM_RELEASE_REPO    repo that hosts the release asset (default obj-p/PreviewsMCP)
#   LLVM_EXPECT_COMMIT   if set, fail unless the checked-out HEAD matches it
#   LLVM_SPARSE_PATHS    space-separated cone paths (default: the five below)
#
set -euo pipefail

REMOTE="${LLVM_REMOTE:-https://github.com/swiftlang/llvm-project.git}"
REPO="${LLVM_RELEASE_REPO:-obj-p/PreviewsMCP}"
read -r -a SPARSE_PATHS <<<"${LLVM_SPARSE_PATHS:-llvm compiler-rt cmake third-party runtimes}"

TAG="${1:-}"
PUBLISH=0
[ "${2:-}" = "--publish" ] && PUBLISH=1

die() { echo "error: $*" >&2; exit 1; }

[ -n "$TAG" ] || die "usage: $0 <fork-tag> [--publish]  (e.g. $0 swift-6.2.3-RELEASE)"

# GNU tar is required for a byte-reproducible archive: the macOS system (BSD) tar
# has no --sort/--mtime, so its output ordering and timestamps vary run to run,
# which would break the sha256 pin.
TAR="$(command -v gtar || true)"
[ -n "$TAR" ] || die "gtar (GNU tar) not found — install it: brew install gnu-tar"
command -v git >/dev/null || die "git not found"
if [ "$PUBLISH" = 1 ]; then command -v gh >/dev/null || die "gh not found"; fi

RELEASE_TAG="llvm-src-${TAG}"
ASSET="${RELEASE_TAG}.tar.gz"
OUT="$(pwd)/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> sparse-checkout ${REMOTE} @ ${TAG}  (paths: ${SPARSE_PATHS[*]})"
git -C "$WORK" init -q .
git -C "$WORK" remote add origin "$REMOTE"
git -C "$WORK" config extensions.partialClone origin
git -C "$WORK" sparse-checkout set --cone "${SPARSE_PATHS[@]}"
git -C "$WORK" fetch -q --depth 1 --filter=blob:none origin "refs/tags/${TAG}"
git -C "$WORK" checkout -q FETCH_HEAD

HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
echo "==> checked out ${HEAD_SHA}"
if [ -n "${LLVM_EXPECT_COMMIT:-}" ] && [ "$HEAD_SHA" != "$LLVM_EXPECT_COMMIT" ]; then
  die "HEAD ${HEAD_SHA} != expected ${LLVM_EXPECT_COMMIT}"
fi

# Drop the git metadata so the archive is a clean source tree (the BUILD glob
# excludes **/.git/** anyway; leaving it just bloats the asset). The cyclic test
# symlink llvm/test/tools/llvm-cas/Inputs/self is left in place — llvm.bzl
# deletes it after extraction, so the archive is expected to contain it.
rm -rf "$WORK/.git"

echo "==> tar (deterministic) -> ${OUT}"
# --sort=name + fixed mtime/owner + gzip -n = same bytes for the same tree, so
# the sha256 below is reproducible and meaningful as a pin.
"$TAR" --sort=name --format=posix \
  --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  --pax-option='delete=atime,delete=ctime' \
  -C "$WORK" -cf - . | gzip -n >"$OUT"

SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
SIZE="$(du -h "$OUT" | awk '{print $1}')"

echo
echo "==> archive: ${OUT} (${SIZE})"
echo "==> sha256:  ${SHA}"
echo
echo "Paste into MODULE.bazel llvm_repository(...):"
echo "    sha256 = \"${SHA}\","
echo "    url = \"https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET}\","
echo

if [ "$PUBLISH" = 1 ]; then
  echo "==> publishing release ${RELEASE_TAG} on ${REPO}"
  if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" --repo "$REPO" \
      --title "$RELEASE_TAG" \
      --notes "Sparse source tree of ${REMOTE} at ${TAG} (${HEAD_SHA}), paths: ${SPARSE_PATHS[*]}. Consumed by @llvm_src via bazel/llvm.bzl."
  fi
  gh release upload "$RELEASE_TAG" "$OUT" --repo "$REPO" --clobber
  echo "==> uploaded ${ASSET} to ${RELEASE_TAG}"
else
  echo "(build only — pass --publish to create the release and upload the asset)"
fi
