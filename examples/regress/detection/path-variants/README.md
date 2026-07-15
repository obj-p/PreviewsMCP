# Path Variants

`Space Package/Sources/PathFixture/Unicode–Preview.swift` puts both spaces and
non-ASCII characters in project/source paths. Detection, subprocess arguments,
watch registration, snapshots, and error messages must preserve the path
without shell splitting or lossy normalization.
