# Build-System Detection Boundaries

Run these sources without `--build-system` or `--project-path` first. An
explicit override is useful only as a control proving the inner project itself
works.

- `mixed-marker-workspace` places real Xcode and SwiftPM projects below a Bazel
  root that does not own their sources.
- `outer-spm-workspace` places real Xcode and Bazel projects below a valid outer
  package that does not own their sources.
- `same-directory-markers` is valid as both SwiftPM and Bazel. It forces the
  precedence policy to be observable and testable.
- `path-variants` puts spaces and Unicode in project/source paths so argument
  handling is tested independently of marker precedence.

The important distinction is marker presence versus applicability: a distant
marker that cannot resolve an owning target must not permanently win detection.
