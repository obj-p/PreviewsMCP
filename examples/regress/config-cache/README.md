# Project Config Cache Invalidation

This fixture reproduces a config-discovery change during one daemon lifetime.
It begins with a light color scheme in the package-root `.previewsmcp.json`.
The nested source directory contains a closer dark config under the template
name `.previewsmcp.closer.json`.

1. Start `Nested/Sources/ConfigCache/ConfigCachePreview.swift` with a fresh
   daemon. It should render `light`.
2. Copy `Nested/.previewsmcp.closer.json` to
   `Nested/.previewsmcp.json` without restarting the daemon.
3. Start the same source again. A live config lookup should now render `dark`.
4. Remove the ignored `Nested/.previewsmcp.json` to reset the fixture.

The daemon currently caches discovery by source directory, including the path
of the more distant file, so step 3 continues using the light config until the
daemon restarts. The same scenario can be inverted to test removal of a nearer
config.
