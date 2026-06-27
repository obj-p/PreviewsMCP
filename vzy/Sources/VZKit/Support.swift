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

/// Sendable holder for a value mutated inside a detached/concurrent closure
/// that we never actually share concurrently — it lives and dies within one
/// task. The `@unchecked Sendable` is the cost of that locality.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
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
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "vzkit-host", attributes: .concurrent)
    try process.run()
    let outDrain = drain(out, on: queue, group: group)
    let errDrain = drain(err, on: queue, group: group)
    process.waitUntilExit()
    group.wait()
    guard process.terminationStatus == 0 else {
        var stderr = String(decoding: errDrain.data.value, as: UTF8.self)
        if stderr.isEmpty, let readError = errDrain.error.value {
            stderr = "<stderr unavailable: \(readError.localizedDescription)>"
        }
        throw VMError(
            "host command failed (exit \(process.terminationStatus)): "
                + "\(args.joined(separator: " "))\n\(stderr)"
        )
    }
    if let readError = outDrain.error.value {
        throw VMError(
            "host command stdout read failed: \(args.joined(separator: " "))",
            underlying: readError
        )
    }
    return String(decoding: outDrain.data.value, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Drain a pipe to EOF on `queue`, capturing any read error rather than
/// discarding it — so a failed read surfaces instead of silently yielding
/// empty output. Both the stdout and stderr drains share this.
private func drain(
    _ pipe: Pipe, on queue: DispatchQueue, group: DispatchGroup
) -> (data: Box<Data>, error: Box<Error?>) {
    let dataBox = Box(Data())
    let errorBox = Box<Error?>(nil)
    queue.async(group: group) {
        do {
            dataBox.value = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            errorBox.value = error
        }
    }
    return (dataBox, errorBox)
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
