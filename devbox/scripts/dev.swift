import Foundation
import VZKit

let script = Script(usage: "vz run dev.swift <bundle> <worktree> [--clean] [command...]", min: 3)
let bundle = try script.bundle()
let worktree = script[arg: 2]
var rest = Array(script.args.dropFirst(3))
let clean = rest.first == "--clean"
if clean { rest.removeFirst() }
let command = rest.joined(separator: " ")

let shareURL = URL(filePath: worktree).resolvingSymlinksInPath()
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: shareURL.path, isDirectory: &isDir), isDir.boolValue
else {
    FileHandle.standardError.write(Data("worktree is not a directory: \(worktree)\n".utf8))
    exit(2)
}

if clean {
    step("restoring post-toolchain")
    try SnapshotStore.restore(name: "post-toolchain", in: bundle)
}

let guestMount = "/Users/admin/work"
let share = VMConfiguration.DirectoryShare(hostURL: shareURL, readOnly: false)

try await Guest.session(bundle: bundle, adminPass: "vzvz", share: share, mountAt: guestMount) {
    guest in
    let remote =
        command.isEmpty
        ? "cd \(guestMount) && exec $SHELL -l"
        : "cd \(guestMount) && \(command)"
    let rc = try await Task.detached {
        try VMSSH.execInteractive(
            endpoint: guest.endpoint, command: remote, forceTTY: command.isEmpty)
    }.value
    if rc != 0 {
        step("session command exited \(rc)")
    }
}
