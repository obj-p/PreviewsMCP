# Preview Declaration Forms

This target keeps parser and selection cases independent by source file:

- `LegacyProvider.swift` contains only `PreviewProvider` syntax.
- `ConditionalPreviews.swift` guards previews with compilation conditions.
- `DuplicateNames.swift` declares two previews with the same display name.
- `GenericContext.swift` constructs a generic view through a constrained
  extension.
- `NoPreview.swift` contains a `View` but no preview declaration.

Listing must be deterministic, selecting an index must render the matching
declaration, and a file with no supported preview must return a specific
diagnostic rather than an empty or stale result.
