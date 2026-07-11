#!/bin/bash
# Renders one preview from each example project through the built CLI and
# asserts a valid PNG comes back — covering build-system detection, example
# build, default runfiles resource discovery, and the macOS render path
# end-to-end (#372). The equivalent SnapshotCommandTests silently skip for
# every example but spm under bazel's sanitized PATH, so this script is the
# only place the other three build systems render gated. iOS/simulator
# example coverage is a follow-up; keeping this job sim-free lets it run
# scheduled without contending for the simulator lane.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
out=$(mktemp -d)

bazel build //previewsmcp/cli:previewsmcp
bin="$root/bazel-bin/previewsmcp/cli/previewsmcp"

"$bin" kill-daemon --timeout 5 >/dev/null 2>&1 || true
trap '"$bin" kill-daemon --timeout 5 >/dev/null 2>&1 || true; rm -rf "$out"' EXIT

fail=0
for example in spm xcodeproj xcworkspace bazel; do
  source_file="$root/examples/$example/Sources/ToDo/ToDoView.swift"
  png="$out/$example.png"
  echo "=== $example"
  if [ -f "$root/examples/$example/project.yml" ]; then
    if ! (cd "$root/examples/$example" && mint run xcodegen generate); then
      echo "FAIL $example (xcodegen generate)"
      fail=1
      continue
    fi
  fi
  if "$bin" snapshot "$source_file" --project "$root/examples/$example" \
    --output "$png" \
    && file "$png" | grep -q "PNG image data"; then
    echo "OK $example ($(stat -f%z "$png") bytes)"
  else
    echo "FAIL $example"
    fail=1
  fi
done

exit "$fail"
