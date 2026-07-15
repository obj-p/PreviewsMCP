# Example Projects

Each directory contains a minimal project for a specific build system, used for integration testing PreviewsMCP's build system support.

| Directory | Build System | Status |
|-----------|-------------|--------|
| `spm/` | Swift Package Manager | Implemented |
| `xcodeproj/` | Xcode (.xcodeproj via XcodeGen) | Example project |
| `bazel/` | Bazel | Example project |
| `regress/` | Mixed / fault-oriented | Reproduction matrix |

See each project's `README.md` for integration test instructions.

`regress/` contains intentionally adversarial, greenfield projects. Unlike the
three happy-path examples, each regression fixture isolates a build-discovery,
compiler-context, runtime, lifecycle, or interaction boundary and documents the
behavior PreviewsMCP should eventually guarantee.
