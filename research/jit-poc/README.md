# jit-poc — reproduction target

**What it proves (regenerated on every run):** Apple's Xcode-Previews runtime
JIT engine is LLVM ORC + JITLink (established out-of-band by symbol-dumping
`XOJITExecutor.framework`), and that *same public architecture* — LLVM
ORC/JITLink + `swiftc -emit-object` — can ingest Swift objects and hot-swap a
function implementation for every hard Swift emission pattern, with **zero**
imports of Apple's private preview frameworks.

This is a **reproduction**, not a findings doc: `./run.sh` rebuilds from source
and asserts each pattern JIT-links and produces the expected v1→v2 override
output. Green means the finding still holds on the current toolchain; red means
LLVM / swiftc / macOS drift broke a pattern (which is the signal we want).

VM-free (host-tier) — no `Virtualization.framework`, no snapshot.

## Run

```sh
./run.sh    # builds + asserts all patterns; exits non-zero on any failure
```

Requires brewed LLVM (`brew install llvm`) and an Xcode toolchain (`swiftc`).

## Patterns asserted

| Harness | Swift emission pattern | Green marker |
|---|---|---|
| `host` | free-function override | `hello from swift v2` |
| `host_witness` | protocol-witness-table override + cross-JITDylib | `hello from v2 (stretch)` |
| `host_tlv` | TLV + `swift_once`-guarded global-init | `sum_of_squares_1_to_100=338350` |
| `host_objc` | ObjC `__objc_selrefs` uniquing (Foundation) | `touchNSString: ns_v1=7 sum=42` |
| `host_async` | `async` fn + multi-await | `hello from async v1` / `v2` |
| `host_split` | auto-split → `@testable` → JIT-link → pixels differ | `VERDICT: PASS` |

`SCOPE.md` is the detailed spec / success criteria the run asserts. `build.sh`
and `build-split.sh` are the canonical compiles; `run.sh` drives them and adds
the assertions. `build/` is gitignored (regenerated per run).
