import Foundation
import VZKit

final class DataBox: @unchecked Sendable {
    var value = Data()
}

@discardableResult
func host(_ args: [String], cwd: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(filePath: cwd) }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let outBox = DataBox()
    let errBox = DataBox()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "mq-warm-host", attributes: .concurrent)
    try process.run()
    queue.async(group: group) {
        outBox.value = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    }
    queue.async(group: group) {
        errBox.value = (try? err.fileHandleForReading.readToEnd()) ?? Data()
    }
    process.waitUntilExit()
    group.wait()
    guard process.terminationStatus == 0 else {
        let stderr = String(decoding: errBox.value, as: UTF8.self)
        throw VMError(
            "host command failed (exit \(process.terminationStatus)): "
                + "\(args.joined(separator: " "))\n\(stderr)"
        )
    }
    return String(decoding: outBox.value, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let script = Script(usage: "vz run warm.swift <bundle> [ref]", min: 2)
let bundle = try script.bundle()
let ref = script[arg: 2, default: "HEAD"]

let cache = "grpc://100.121.199.61:9092"
let bazelFlags = "--remote_cache=\(cache) --remote_upload_local_results=false"
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
          bazelisk build //... \(bazelFlags) && break
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
