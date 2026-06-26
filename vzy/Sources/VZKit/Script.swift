import Foundation

public struct Script {
    public let args: [String]

    public init(usage: String, min: Int, args: [String] = CommandLine.arguments) {
        guard args.count >= min else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(2)
        }
        self.args = args
    }

    public func bundle(_ index: Int = 1) throws -> VMBundle {
        try VMBundle(directory: URL(filePath: args[index]))
    }

    public subscript(arg index: Int) -> String {
        args[index]
    }

    public subscript<T: LosslessStringConvertible>(arg index: Int, default fallback: T) -> T {
        args.count > index ? (T(args[index]) ?? fallback) : fallback
    }
}
