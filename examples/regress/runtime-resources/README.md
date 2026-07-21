# SwiftPM Runtime Resources

This package verifies that compilation success is not mistaken for runtime
resource success. The preview reads all of the following from `Bundle.module`:

- a JSON file;
- localized strings in English and Spanish;
- a plain text resource.

Run `ResourcePreview.swift` through PreviewsMCP on macOS and iOS, then switch
from its English preview to its Spanish preview. Each view resolves its title
through the requested locale's `.lproj` sub-bundle explicitly
(`Bundle.module.path(forResource:ofType:)` then `localizedString(forKey:)`),
so the title is `Recursos cargados` exactly when the Spanish directory is
staged and readable, `<locale>.lproj missing` when staging dropped it, and
`resource.title unresolved` when the directory exists without the key. The
explicit lookup is deliberate: `String(localized:bundle:locale:)` does not
select the `.lproj` (its `locale:` only affects interpolation formatting), so
a preview-level locale assertion built on it can never show Spanish even when
staging is correct. Missing staged bundles or resource accessor sources should
be reported separately from Swift compilation failures. Compiled asset
catalogs and Core Data models are covered by the Xcode fixture because
command-line SwiftPM copies those directory resources rather than producing
Xcode build outputs.

`SpanishOnlyPreview.swift` is the control for separating localized resource
loading from a failure that occurs only when selecting or switching to the
second preview in `ResourcePreview.swift`.
