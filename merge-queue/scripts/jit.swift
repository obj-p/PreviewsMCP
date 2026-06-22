import Foundation
import VZKit

func provisionJIT(_ guest: Guest, repoRoot: String, jitCache: String) async throws {
    let xcodeApp = "/Applications/Xcode.app"
    let osxOrc = "\(jitCache)/llvm-build-rt/lib/darwin/liborc_rt_osx.a"
    let iossimOrc = "\(jitCache)/llvm-build-rt/lib/darwin/liborc_rt_iossim.a"
    let iossimLib = "\(jitCache)/llvm-build-iossim/lib/libLLVMOrcTargetProcess.a"

    if try await guest.test("test -f \(osxOrc) && test -f \(iossimLib)") {
        step("JIT artifacts already present in \(jitCache), skipping build")
    } else {
        step("selecting Xcode at \(xcodeApp)")
        try await guest.sudo("xcode-select -s \(xcodeApp)")

        step("installing cmake + ninja")
        try await guest.sh("brew install cmake ninja", env: .brew, timeout: 1800)

        step("streaming repo scripts into guest")
        try await guest.uploadTree(localDir: "\(repoRoot)/scripts", to: "~/jit-build-repo/scripts")

        step("building macOS LLVM (build-jit-llvm.sh) — this is the long step")
        try await guest.sh(
            "cd ~/jit-build-repo && bash scripts/build-jit-llvm.sh", env: .brew, timeout: 5400)

        step("building iossim LLVM (build-jit-llvm-iossim.sh)")
        try await guest.sh(
            "cd ~/jit-build-repo && bash scripts/build-jit-llvm-iossim.sh", env: .brew, timeout: 5400)

        step("staging artifacts into \(jitCache)")
        try await guest.sh(
            "rm -rf \(jitCache) && mv ~/jit-build-repo/third_party \(jitCache) && rm -rf ~/jit-build-repo")
    }

    step("verifying baked artifacts")
    try await guest.sh(
        "test -d \(jitCache)/llvm-build && test -f \(osxOrc) && test -f \(iossimOrc) "
            + "&& test -f \(iossimLib) && test -d \(jitCache)/llvm-project/llvm/include")
    step("jit bake complete")
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
