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

public enum Log {
    public nonisolated(unsafe) static var prefix = "vz"

    public static func info(_ message: @autoclosure () -> String) {
        write("[\(prefix)] \(message())")
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["PREVIEWSVM_DEBUG"] != nil else { return }
        write("[\(prefix):debug] \(message())")
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
