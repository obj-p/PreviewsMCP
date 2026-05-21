// Thin shim. PreviewsCLI is a library so test targets can @testable
// import it under Xcode (PR #184); this target is the executable
// product `previewsmcp` and exists only to call into it.
import PreviewsCLI

PreviewsMCPApp.main()
