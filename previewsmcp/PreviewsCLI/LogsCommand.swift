import ArgumentParser
import Foundation

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the daemon log for debugging (~/.previewsmcp/serve.log)",
        discussion: """
            Prints the last N lines of the daemon log and exits. Pass
            --follow to stream new lines as they're appended — useful for
            diagnosing a stuck command (e.g., an iOS host build) from a
            second terminal.

            Log path: ~/.previewsmcp/serve.log, or $PREVIEWSMCP_SOCKET_DIR/serve.log
            when that variable is set.
            """
    )

    @Flag(
        name: [.short, .long],
        help: "Stream new lines as they're appended (Ctrl-C to stop)"
    )
    var follow: Bool = false

    @Option(
        name: [.customShort("n"), .long],
        help: "Number of lines to print from the end of the log"
    )
    var lines: Int = 100

    func run() throws {
        // Create the log file (and parent dir) if absent so `tail` has
        // something to open. Mirrors the daemon's own fallback at
        // DaemonClient.swift:122-125 — running `logs` before the daemon
        // has ever started should succeed quietly, not error.
        try DaemonPaths.ensureDirectory()
        let logPath = DaemonPaths.logFile.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        let process = Process()
        // Hardcoded /usr/bin/tail matches repo convention (DaemonClient.swift:109)
        // and avoids picking up a trojaned `tail` on PATH. BSD tail's -F
        // follows by name and reopens on rotation/truncation.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments =
            ["-n", String(lines)] + (follow ? ["-F", logPath] : [logPath])

        // Stream output directly to the CLI's own stdio rather than
        // capturing via a Pipe. Ctrl-C in the terminal is delivered to
        // the foreground process group, which on Darwin the child
        // inherits from Process.run() — so SIGINT reaches `tail` on its
        // own, no setpgid required.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        let childPID = process.processIdentifier

        // After run() the child is exec'd with its own (default) signal
        // dispositions, so adjusting the parent's from here on doesn't
        // affect it. Suppress the default terminate-on-signal behavior
        // in the parent and forward SIGINT/SIGTERM to the child. Two
        // scenarios to cover:
        //   - Ctrl-C in a terminal: the tty sends SIGINT to the whole
        //     foreground process group, so tail already receives it on
        //     its own. The forward is a redundant, idempotent poke.
        //   - `kill -INT <parent-pid>` from a script or supervisor: the
        //     signal arrives only at the parent. Without forwarding,
        //     tail would outlive us and be reparented to launchd.
        //
        // There is a narrow race between process.run() above and the
        // first signal() call below where the parent still has default
        // SIGINT/SIGTERM disposition. It's benign: in the tty case the
        // pgroup delivery kills both parent and child at once (same
        // observable result); in the direct-kill case the window is a
        // handful of instructions wide, no worse than the equivalent
        // gap in RunCommand.blockUntilSignal.
        //
        // Sources run on a background queue because waitUntilExit
        // blocks the calling thread (main for sync ParsableCommand).
        let signalQueue = DispatchQueue.global(qos: .userInitiated)
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { kill(childPID, sig) }
            src.resume()
            signalSources.append(src)
        }
        defer {
            // LogsCommand is a CLI leaf — no earlier code on this path
            // installs a SIGINT/SIGTERM handler — so restoring SIG_DFL
            // rather than the prior disposition is safe. If a future
            // pre-run hook at the app layer installs one, revisit this
            // and RunCommand.blockUntilSignal together.
            for src in signalSources { src.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
    }
}
