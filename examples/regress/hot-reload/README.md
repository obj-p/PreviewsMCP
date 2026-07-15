# Hot-Reload Watcher Mutations

Start `Sources/HotReload/HotReloadPreview.swift` detached, then exercise one
mutation at a time without restarting the daemon or session:

1. Change the string in `MutationModel.swift`.
2. Add a new Swift source and reference it from the preview.
3. Rename `RenameCandidate.swift` and update the reference.
4. Remove the renamed source and its reference.
5. Change only `Resources/reload-value.txt`.
6. Change `Package.swift` target settings or resource membership.
7. Make several rapid source edits while a compile is in flight.
8. Save `MutationModel.swift` the way editors do: write the new content to a
   temporary file in the same directory, then rename it over the original
   (`mv MutationModel.swift.tmp MutationModel.swift`).

Each mutation must either hot-reload to the new value or return a classified
compile/configuration error. No mutation may leave the session silently stale,
leak a compiler process, or require a daemon restart.
