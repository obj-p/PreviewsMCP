# Multi-Project Xcode Workspace

This fixture contains an `.xcworkspace` with an app-feature framework project
and a referenced framework project. The `WorkspaceFeature` scheme builds both,
uses the custom `Preview Debug` configuration, and imports `SharedKit` from the
other project.

Regenerate checked-in project output after editing either manifest:

```bash
xcodegen generate --spec SharedKit/project.yml
xcodegen generate --spec App/project.yml
```

PreviewsMCP must select the workspace scheme and source-owning target, preserve
the `.xcconfig` compilation condition, and link the cross-project dependency.
