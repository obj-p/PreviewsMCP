# Setup Plugin Faults

Each subdirectory is a standalone SwiftPM app fixture with its own setup package
and `.previewsmcp.json`:

- `throwing` builds successfully, then throws from `setUp()`.
- `slow` spends eight seconds in `setUp()` before completing.
- `build-failure` has an intentionally invalid setup source while the app
  package itself remains valid.

Run the preview source from inside one case so config discovery cannot select a
sibling. Setup build/runtime failures must be reported separately from app
build failures, and the daemon must remain responsive. The slow case must emit
elapsed-time progress before it renders.
