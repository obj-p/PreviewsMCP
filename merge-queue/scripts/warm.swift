import Foundation
import VZKit

let script = Script(usage: "vz run warm.swift <bundle> [ref]", min: 2)
let bundle = try script.bundle()
let ref = script[arg: 2, default: "HEAD"]

let remoteWork = "/Users/admin/work"

let repoRoot = try host(["git", "rev-parse", "--show-toplevel"])
let sha = try host(["git", "rev-parse", ref], cwd: repoRoot)
step("warming bazel state at \(remoteWork) from \(sha.prefix(8))")

let work = NSTemporaryDirectory() + "mq-warm-work"
step("preparing source worktree at \(work)")
try? FileManager.default.removeItem(atPath: work)
try host(["git", "clone", "--local", "--quiet", "--no-checkout", repoRoot, work])
try host(["git", "checkout", "--detach", "--quiet", sha], cwd: work)

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    step("delivering source to guest \(remoteWork)")
    try guest.rsync(localDir: work, to: remoteWork, exclude: [])
    try await guest.sh("git config --global --add safe.directory \(remoteWork)")

    step("bazelisk build //... (fetches @llvm_src + builds; retries on flaky fetch)")
    try await guest.sh(
        """
        cd \(remoteWork)
        n=0
        until [ $n -ge 6 ]; do
          bazelisk build //... && break
          n=$((n+1)); echo "warm build attempt $n failed; retrying in 60s"; sleep 60
        done
        [ $n -lt 6 ]
        """,
        env: .brew, timeout: 10800
    )

    step("baked external repos:")
    let info = try await guest.sh(
        "cd \(remoteWork) && du -sh $(bazelisk info output_base)/external 2>/dev/null",
        env: .brew, timeout: 300
    )
    step(info)
}

step("warm bake complete for \(sha.prefix(8)) — snapshot post-ios now")
