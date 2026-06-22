import Foundation
import VZKit

func hostRun(_ path: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw VMError("\(path) exited \(process.terminationStatus)")
    }
}

@discardableResult
func brewsh(_ guest: Guest, _ command: String, timeout: TimeInterval = 5400) async throws -> String {
    try await guest.sh("eval \"$(/opt/homebrew/bin/brew shellenv)\" && \(command)", timeout: timeout)
}

func provisionJIT(
    _ guest: Guest, repoRoot: String, jitCache: String,
    xcodeApp: String = "/Applications/Xcode.app"
) async throws {
    let osxOrc = "\(jitCache)/llvm-build-rt/lib/darwin/liborc_rt_osx.a"
    let iossimOrc = "\(jitCache)/llvm-build-rt/lib/darwin/liborc_rt_iossim.a"
    let iossimLib = "\(jitCache)/llvm-build-iossim/lib/libLLVMOrcTargetProcess.a"

    if try await guest.test("test -f \(osxOrc) && test -f \(iossimLib)") {
        print("==> JIT artifacts already present in \(jitCache), skipping build")
    } else {
        print("==> selecting Xcode at \(xcodeApp)")
        try await guest.sudo("xcode-select -s \(xcodeApp)")

        print("==> installing cmake + ninja")
        try await brewsh(guest, "brew install cmake ninja", timeout: 1800)

        print("==> streaming repo scripts into guest")
        let hostTar = "/tmp/mq-jit-scripts.tar"
        try hostRun("/usr/bin/git", ["-C", repoRoot, "archive", "--format=tar", "-o", hostTar, "HEAD", "scripts"])
        try await guest.sh("rm -rf ~/jit-build-repo && mkdir -p ~/jit-build-repo")
        try guest.upload(localPath: hostTar, to: "/tmp/mq-jit-scripts.tar")
        try await guest.sh("tar -xf /tmp/mq-jit-scripts.tar -C ~/jit-build-repo")

        print("==> building macOS LLVM (build-jit-llvm.sh) — this is the long step")
        try await brewsh(guest, "cd ~/jit-build-repo && bash scripts/build-jit-llvm.sh")

        print("==> building iossim LLVM (build-jit-llvm-iossim.sh)")
        try await brewsh(guest, "cd ~/jit-build-repo && bash scripts/build-jit-llvm-iossim.sh")

        print("==> staging artifacts into \(jitCache)")
        try await guest.sh(
            "rm -rf \(jitCache) && mv ~/jit-build-repo/third_party \(jitCache) && rm -rf ~/jit-build-repo")
    }

    print("==> verifying baked artifacts")
    try await guest.sh(
        "test -d \(jitCache)/llvm-build && test -f \(osxOrc) && test -f \(iossimOrc) "
            + "&& test -f \(iossimLib) && test -d \(jitCache)/llvm-project/llvm/include")
    print("==> jit bake complete")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: vz run jit.swift <bundle> <repoRoot> [jitCache]\n".utf8))
    exit(2)
}
let bundle = try VMBundle(directory: URL(filePath: arguments[1]))
let repoRoot = arguments[2]
let jitCache = arguments.count > 3 ? arguments[3] : "/Users/admin/jit-cache"

try await Guest.session(bundle: bundle, adminPass: "vzvz") { guest in
    try await provisionJIT(guest, repoRoot: repoRoot, jitCache: jitCache)
}
