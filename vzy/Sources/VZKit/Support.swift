import Foundation

public struct VMError: LocalizedError, Sendable {
    public let message: String
    public let underlying: String?

    public init(_ message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying.map { String(describing: $0) }
    }

    public var errorDescription: String? {
        if let underlying {
            return "\(message): \(underlying)"
        }
        return message
    }
}

public func step(_ message: String) {
    FileHandle.standardError.write(Data("==> \(message)\n".utf8))
}

private final class DataBox: @unchecked Sendable {
    var value = Data()
}

/// Run a host-side command via `/usr/bin/env`, draining stdout and stderr
/// concurrently (so large output can't deadlock the pipe), and return trimmed
/// stdout. Throws `VMError` with stderr on a non-zero exit.
@discardableResult
public func host(_ args: [String], cwd: String? = nil) throws -> String {
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
    let queue = DispatchQueue(label: "vzkit-host", attributes: .concurrent)
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

public enum Log {
    public nonisolated(unsafe) static var prefix = "vzy"

    public static func info(_ message: @autoclosure () -> String) {
        write("[\(prefix)] \(message())")
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["VZY_DEBUG"] != nil else { return }
        write("[\(prefix):debug] \(message())")
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
