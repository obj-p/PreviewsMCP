# Runtime System Frameworks

`FrameworkPreview.swift` itself imports only SwiftUI. Other files in the same
target import AVFoundation, SceneKit, and LinkPresentation and emit references
to those frameworks. Tier 2 compilation and JIT linking must account for
autolink requirements from every linked object, including requirements that
cannot be treated as loose framework bundles inside a simulator runtime.

Run this example on iOS with `--build-system spm`. The acceptable outcomes are
a rendered preview or a classified missing/unavailable-framework session error.
The daemon terminating or subsequent commands disconnecting is never an
acceptable outcome.

The current macOS baseline reaches JIT materialization and fails on the
target-wide framework/autolink closure; a subsequent daemon `status` request
still succeeds. The iOS run is the authoritative framework-classification case.
