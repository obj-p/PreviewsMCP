# Large Tier 2 Compile

Generate 800 tiny Swift files plus an aggregate catalog:

```bash
cd examples/regress/large-tier2
./generate-sources.sh
```

Set `FILE_COUNT=2000` (or another value) when a faster machine needs a longer
compile window.

Then start `Sources/LargeTier2/LargeTier2Preview.swift` with `--detach --json`.
The generated files are intentionally untracked. This keeps the repository
small while making the compiler process a genuinely large target.

Healthy CLI behavior keeps stdout valid JSON and writes periodic elapsed-time
compile/link/setup/render heartbeats to stderr. Fast runs do not need to emit a
heartbeat. Deleting `Sources/LargeTier2/Generated` restores the ungenerated
fixture.
