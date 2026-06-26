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
    let queue = DispatchQueue(label: "mq-bar-host", attributes: .concurrent)
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

let script = Script(
    usage: "vz run bar.swift <bundle> [candidate-ref] [base-ref] [key-bundle.age] "
        + "[age-identity] [principal] [target-repo]",
    min: 2
)
let bundle = try script.bundle()
let candidateRef = script[arg: 2, default: "HEAD"]
let baseRef = script[arg: 3, default: "origin/main"]
let keyBundle: String? = script.args.count > 4 ? script.args[4] : nil
let ageIdentity: String? = script.args.count > 5 ? script.args[5] : nil
let principal = script[arg: 6, default: "merge-queue@local"]
let targetRepo: String? = script.args.count > 7 ? script.args[7] : nil
if keyBundle != nil, ageIdentity == nil {
    throw VMError("signing requires both a key bundle and an age identity file")
}

if targetRepo != nil, keyBundle == nil {
    throw VMError("landing to a target repo requires a key bundle to sign with")
}

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
do {
    try host(
        ["git", "-c", "user.name=merge-queue", "-c", "user.email=merge-queue@local",
         "rebase", baseSHA],
        cwd: work
    )
} catch {
    try? host(["git", "rebase", "--abort"], cwd: work)
    throw VMError(
        "candidate \(candidateSHA.prefix(8)) does not rebase cleanly onto "
            + "base \(baseSHA.prefix(8)) — rejecting: \(error)"
    )
}

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    step("delivering candidate to guest \(remoteWork)")
    try guest.rsync(localDir: work, to: remoteWork, exclude: [])
    try await guest.sh("git config --global --add safe.directory \(remoteWork)")

    step("bazel test //... (first run fetches all external deps; slow)")
    try await guest.sh(
        "cd \(remoteWork) && bazelisk test //... --flaky_test_attempts=3",
        env: .brew, timeout: 10800
    )
    step("bazel run //tools/lint:check")
    try await guest.sh(
        "cd \(remoteWork) && bazelisk run //tools/lint:check",
        env: .brew, timeout: 1800
    )

    guard let keyBundle, let ageIdentity else { return }
    step("decrypting key bundle + signing landed range on green (principal \(principal))")
    let stage = NSTemporaryDirectory() + "mq-bar-keys"
    try? FileManager.default.removeItem(atPath: stage)
    try FileManager.default.createDirectory(
        atPath: stage, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(atPath: stage) }
    let members = targetRepo == nil
        ? "signing_key signing_key.pub"
        : "signing_key signing_key.pub deploy_key"
    try host([
        "sh", "-c",
        "age -d -i \(ageIdentity) \(keyBundle) | tar -C \(stage) -xf - \(members)",
    ])
    try await guest.sh(
        """
        DEV=$(hdiutil attach -nomount ram://$((16 * 2048)) | awk '{print $1}')
        diskutil erasevolume HFS+ mqkeys "$DEV" >/dev/null
        """
    )
    try guest.upload(localPath: stage + "/signing_key", to: "/Volumes/mqkeys/signing_key")
    try guest.upload(localPath: stage + "/signing_key.pub", to: "/Volumes/mqkeys/signing_key.pub")
    if targetRepo != nil {
        try guest.upload(localPath: stage + "/deploy_key", to: "/Volumes/mqkeys/deploy_key")
    }
    let signedSHA = try await guest.sh(
        """
        set -e
        printf '%s %s\\n' "\(principal)" "$(cat /Volumes/mqkeys/signing_key.pub)" \
            > /Volumes/mqkeys/allowed_signers
        chmod 600 /Volumes/mqkeys/signing_key
        cd \(remoteWork)
        git config gpg.format ssh
        git config user.signingkey /Volumes/mqkeys/signing_key
        git config gpg.ssh.allowedSignersFile /Volumes/mqkeys/allowed_signers
        git config user.name merge-queue
        git config user.email "\(principal)"
        MSG=$(git log -1 --format=%s)
        git reset --soft \(baseSHA)
        GIT_COMMITTER_NAME=merge-queue GIT_COMMITTER_EMAIL="\(principal)" \
            git commit -q -S -m "$MSG"
        git verify-commit HEAD >&2
        git rev-parse HEAD
        """
    )
    step("signed + verified commit \(signedSHA.prefix(12))")
    if let targetRepo {
        step("pushing \(signedSHA.prefix(12)) to \(targetRepo) main via deploy key")
        try await guest.sh(
            """
            set -e
            chmod 600 /Volumes/mqkeys/deploy_key
            cd \(remoteWork)
            GIT_SSH_COMMAND="ssh -i /Volumes/mqkeys/deploy_key -o IdentitiesOnly=yes \
                -o IdentityAgent=none -o StrictHostKeyChecking=accept-new" \
                git push git@github.com:\(targetRepo).git HEAD:main
            """
        )
        step("landed \(signedSHA.prefix(12)) on \(targetRepo) main")
    }
    try await guest.sh("diskutil eject /Volumes/mqkeys >/dev/null")
    step("keys on tmpfs ejected")
}

step("merge bar PASSED for candidate \(candidateSHA.prefix(8))")
