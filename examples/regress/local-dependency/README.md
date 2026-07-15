# Cross-Package Local Dependency

`App` depends on the sibling package `SharedLocal` through
`.package(path: "../SharedLocal")`. Start
`App/Sources/LocalDependencyApp/LocalDependencyPreview.swift`, then edit
`SharedLocal/Sources/SharedLocal/SharedValue.swift` while the session is live.

The edit crosses the package boundary: the watcher must observe the dependency
package's sources, and the reload must rebuild the dependency module before
recompiling the preview target. The session must show the new value or return
a classified compile error, never a silently stale render.
