# Bazel Bzlmod Execution State

This workspace combines two artifact classes that should come from Bazel's
actual configured action graph:

- `@local_badge` is a local Bzlmod dependency. Bazel gives it a canonical
  repository name under the output base; no workspace-relative
  `external/local_badge` path is required to exist.
- `GeneratedBuildStamp.swift` is emitted by a `genrule`, so the source path is
  relative to Bazel's execution root and is not present in the source tree.

Build `//:BzlmodFixture`, then run PreviewsMCP with `--build-system bazel` on
`Sources/BzlmodPreview.swift`. Every `-I`, `-F`, module-map, generated-source,
archive, and framework path in the effective compile context should exist after
the Bazel build, and no unresolved `$(...)` placeholder should remain.

The binary-framework example next to this project supplies generated static,
dynamic, bad-slice, and invalid artifacts for extending this Bazel graph once
artifact staging is represented as a typed build context.
