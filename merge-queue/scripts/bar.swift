import Foundation
import VZKit

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
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw VMError(
            "host command failed (exit \(process.terminationStatus)): "
                + "\(args.joined(separator: " "))\n\(stderr)"
        )
    }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

let script = Script(usage: "vz run bar.swift <bundle> [candidate-ref] [base-ref]", min: 2)
let bundle = try script.bundle()
let candidateRef = script[arg: 2, default: "HEAD"]
let baseRef = script[arg: 3, default: "origin/main"]

let cache = "grpc://100.121.199.61:9092"
let bazelFlags = "--remote_cache=\(cache) --remote_upload_local_results=false"
let remoteWork = "/Users/admin/work"

let repoRoot = try host(["git", "rev-parse", "--show-toplevel"])
let candidateSHA = try host(["git", "rev-parse", candidateRef], cwd: repoRoot)
let baseSHA = try host(["git", "rev-parse", baseRef], cwd: repoRoot)
step("candidate \(candidateSHA.prefix(8)) onto base \(baseSHA.prefix(8))")

let work = NSTemporaryDirectory() + "mq-bar-work"
step("preparing candidate worktree at \(work)")
try? FileManager.default.removeItem(atPath: work)
try host(["git", "clone", "--local", "--quiet", "--no-checkout", repoRoot, work])
try host(["git", "checkout", "--detach", "--quiet", candidateSHA], cwd: work)
try host(
    ["git", "-c", "user.name=merge-queue", "-c", "user.email=merge-queue@local",
     "rebase", baseSHA],
    cwd: work
)

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    step("delivering candidate to guest \(remoteWork)")
    try guest.rsync(localDir: work, to: remoteWork, exclude: [])
    try await guest.sh("git config --global --add safe.directory \(remoteWork)")

    step("bazel test //... (first run fetches all external deps; slow)")
    try await guest.sh(
        "cd \(remoteWork) && bazelisk test //... \(bazelFlags) --flaky_test_attempts=3",
        env: .brew, timeout: 10800
    )
    step("bazel run //tools/lint:check")
    try await guest.sh(
        "cd \(remoteWork) && bazelisk run //tools/lint:check",
        env: .brew, timeout: 1800
    )
}

step("merge bar PASSED for candidate \(candidateSHA.prefix(8))")
