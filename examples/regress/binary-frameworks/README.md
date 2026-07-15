# Binary Framework Artifacts

This package uses locally generated C XCFrameworks so the fixture stays
small, deterministic, and network-free:

- `StaticBadge.xcframework` contains a static simulator archive and headers.
- `DynamicBadge.xcframework` contains a dynamic simulator framework with an
  `@rpath` install name and a bundled JSON resource.
- `BadSlice.xcframework` contains only a device slice.

The generator also creates `Invalid.dylib`, which is not a Mach-O file. It is
reserved for a JIT dependency-injection harness because SwiftPM cannot declare
a loose dylib as a binary target.

```bash
cd examples/regress/binary-frameworks
./generate-artifacts.sh
```

Four standalone packages expose combined, static-only, dynamic-only, and
bad-slice cases. Run the single-dependency packages before the combined package so a
static import failure cannot mask dynamic staging/loading. A correct build
context distinguishes compile-time module search, static archive linkage,
dynamic framework loading/embedding, simulator slice selection, install names,
runtime rpaths, and framework resources.

Generated artifacts are ignored. Rerun the script after changing anything in
`FrameworkSources`.
