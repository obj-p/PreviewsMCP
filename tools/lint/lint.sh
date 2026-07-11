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

# Modes: check (whole tree, verify), fix (whole tree, format in place),
# staged (verify only the git-staged files; used by the pre-commit hook).
mode="${1:-check}"
cd "$BUILD_WORKSPACE_DIRECTORY"
fail=0

# Generated sources, example projects, and research spikes are never linted.
_exclude='(^examples/|^research/|/IOSAgentAppSource\.swift$|/IOSAppIconData\.swift$)'

_candidates() {
  if [[ "$mode" == staged ]]; then
    git diff --cached --name-only --diff-filter=ACM
  else
    git ls-files
  fi
}

# select <include-ERE> [<extra-exclude-ERE>] -> newline-separated paths
select_files() {
  local out
  out="$(_candidates | grep -E "$1" | grep -vE "$_exclude" || true)"
  if [[ -n "${2:-}" ]]; then out="$(echo "$out" | grep -vE "$2" || true)"; fi
  echo "$out"
}

note() { echo "==> $1"; }

if [[ -n "${BUILDIFIER:-}" ]]; then
  mapfile -t files < <(select_files '(/BUILD\.bazel|\.bzl|/MODULE\.bazel|^MODULE\.bazel)$')
  if ((${#files[@]})); then
    note "buildifier ($mode)"
    bf="$(rlocation "$BUILDIFIER")"
    if [[ "$mode" == fix ]]; then "$bf" --mode=fix "${files[@]}"; else "$bf" --mode=check "${files[@]}" || fail=1; fi
  fi
fi

if [[ -n "${CLANG_FORMAT:-}" ]]; then
  mapfile -t files < <(select_files '\.(c|cc|cpp|h|hpp|m|mm)$' '/Fixtures/')
  if ((${#files[@]})); then
    note "clang-format ($mode)"
    cf="$(rlocation "$CLANG_FORMAT")"
    if [[ "$mode" == fix ]]; then "$cf" --style=file -i "${files[@]}"; else "$cf" --style=file --dry-run -Werror "${files[@]}" || fail=1; fi
  fi
fi

if [[ -n "${SWIFTFORMAT:-}" ]]; then
  mapfile -t files < <(select_files '\.swift$' '^bazel/')
  if ((${#files[@]})); then
    note "swiftformat ($mode)"
    sf="$(rlocation "$SWIFTFORMAT")"
    if [[ "$mode" == fix ]]; then "$sf" "${files[@]}"; else "$sf" "${files[@]}" --lint || fail=1; fi
  fi
fi

# SwiftLint is a semantic linter, not a formatter, so it never runs in fix mode.
if [[ -n "${SWIFTLINT:-}" && "$mode" != fix ]]; then
  mapfile -t files < <(select_files '\.swift$' '^bazel/')
  if ((${#files[@]})); then
    note "swiftlint ($mode)"
    sl="$(rlocation "$SWIFTLINT")"
    "$sl" lint --quiet "${files[@]}" || fail=1
  fi
fi

exit "$fail"
