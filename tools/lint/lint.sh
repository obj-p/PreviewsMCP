#!/usr/bin/env bash
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  {
    echo >&2 "ERROR: cannot find $f"
    exit 1
  }
f=
set -e
# --- end runfiles.bash initialization v3 ---

mode="${1:-check}"
cd "$BUILD_WORKSPACE_DIRECTORY"

swift_dirs=(previewsmcp Sources)
fail=0

note() { echo "==> $1"; }

if [[ -n "${BUILDIFIER:-}" ]]; then
  note "buildifier ($mode)"
  bf="$(rlocation "$BUILDIFIER")"
  files=()
  while IFS= read -r p; do files+=("$p"); done < <(
    find . -path './bazel-*' -prune -o -path './.git' -prune -o -path './examples' -prune -o \
      \( -name 'BUILD.bazel' -o -name '*.bzl' -o -name 'MODULE.bazel' \) -type f -print
  )
  if [[ "$mode" == fix ]]; then
    "$bf" --mode=fix "${files[@]}"
  else
    "$bf" --mode=check "${files[@]}" || fail=1
  fi
fi

if [[ -n "${CLANG_FORMAT:-}" ]]; then
  note "clang-format ($mode)"
  cf="$(rlocation "$CLANG_FORMAT")"
  files=()
  while IFS= read -r p; do files+=("$p"); done < <(
    find . -path './bazel-*' -prune -o -path './.git' -prune -o -path './examples' -prune -o \
      -path '*/Fixtures' -prune -o \
      \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.m' -o -name '*.mm' \) -type f -print
  )
  if [[ "$mode" == fix ]]; then
    "$cf" --style=file -i "${files[@]}"
  else
    "$cf" --style=file --dry-run -Werror "${files[@]}" || fail=1
  fi
fi

if [[ -n "${SWIFT_FORMAT:-}" ]]; then
  note "swift-format ($mode)"
  sf="$(rlocation "$SWIFT_FORMAT")"
  if [[ "$mode" == fix ]]; then
    "$sf" format --in-place --recursive "${swift_dirs[@]}"
  else
    "$sf" lint --strict --recursive "${swift_dirs[@]}" || fail=1
  fi
fi

# SwiftLint is a semantic linter, not a formatter, so it only runs in check mode.
if [[ -n "${SWIFTLINT:-}" && "$mode" == check ]]; then
  note "swiftlint (check)"
  sl="$(rlocation "$SWIFTLINT")"
  "$sl" lint --quiet "${swift_dirs[@]}" || fail=1
fi

exit "$fail"
