# FileWatcher

`Sources/PreviewsCore/FileWatcher.swift` currently polls modification dates via `DispatchSourceTimer` at
0.5s intervals. For typical sessions this means O(paths × sessions) `stat()` calls per tick, and a
worst-case 500ms latency between the user saving a file and the hot-reload firing. Replace with macOS File
System Events (FSEvents).

## Why not kqueue / DispatchSource.makeFileSystemObjectSource

Kqueue file-system sources watch an **inode**, not a path. The atomic-rename save pattern used by
NSDocument, Xcode, JetBrains, and default-config `vim` (`backupcopy=auto`) unlinks the original inode and
creates a new file at the same path. A kqueue watcher receives `.delete`, then is permanently bound to
the vanished inode; later writes are invisible until the watcher re-resolves the path and re-arms — which
races the rename window and adds branching logic for every edge case. It also requires one fd per watched
file, which doesn't scale to large transitive build contexts.

## Why FSEvents

Path-based, not inode-based. One watch per parent directory regardless of how many files inside it we
care about. Atomic-rename is naturally observed because FSEvents reports events at path granularity.
Flags worth setting:

- `kFSEventStreamCreateFlagFileEvents` — per-file event granularity within the directory, so we don't
  need a post-event re-stat to identify which watched path changed.
- `kFSEventStreamCreateFlagNoDefer` — deliver the first event immediately rather than after the latency
  window. Combined with a low latency (~50ms) this beats today's 500ms polling cadence by ~10×.

## Behavioral changes the new implementation needs to handle

- **Directory-level events surface unrelated files.** Filter incoming event paths against the
  watched-path set (a `Set<String>` resolved through `realpath` at init time).
- **Coalescing.** FSEvents collapses successive writes into a single event. This matches our usage — one
  reload per change burst — but tests that fire two rapid saves must allow for it.
- **Symlinks.** Resolve through `realpath()` once at init and store both the canonical path (for
  filtering) and the user-provided path (for callback identity).
- **Public API unchanged.** `init(path:callback:)` and `init(paths:callback:)` keep their signatures;
  `interval:` becomes meaningless and is removed (or kept as a deprecated no-op for migration). Tests
  that pass `interval: 0.1` are updated to drop the argument.

## Testing

The existing tests (`IntegrationTests.swift:217`, `BuildSystemTests.swift:372`,
`PreviewHostTests.swift:21`) write to a file and `await` change detection. They keep working with a
tighter timeout (200ms ought to be safe). Add new tests for the cases polling didn't cover:

- atomic-rename save (write to temp + `rename`),
- back-to-back saves within the FSEvents latency window (expect one callback, not zero),
- watcher survives an editor that deletes and re-creates the file on every save.
