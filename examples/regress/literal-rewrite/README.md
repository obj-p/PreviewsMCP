# Literal Rewrite Edge Cases

`RangePreview.swift` is a small regression fixture for token boundaries in the
literal-thunk transform. The source expression `0 ..< 12` is valid Swift. A
naive replacement produces calls immediately adjacent to `..<`, for example
`integer(... )..< integer(...)`, which the Swift parser rejects when the
operator loses its required whitespace.

`LocalizedStringPreview.swift` covers a different failure class: the string
literal passed to `String(localized:bundle:)` has the contextual type
`String.LocalizationValue`. Replacing it with a thunk that returns `String`
breaks overload resolution even though the visible source builds normally.

Run the preview on macOS or iOS with `--build-system spm`. Project compilation
should succeed, and the generated preview source must remain syntactically
valid. This fixture is separate from the large and interaction projects so a
literal-transform failure cannot mask their intended assertions.
