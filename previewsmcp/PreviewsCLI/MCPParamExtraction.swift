import Foundation
import MCP

enum ParamError: Error, LocalizedError {
    case missing(String)
    case wrongType(key: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .missing(let key): return "Missing \(key) parameter"
        case .wrongType(let key, let expected): return "Parameter \(key) must be \(expected)"
        }
    }
}

func extractString(_ key: String, from params: CallTool.Parameters) throws -> String {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    guard case .string(let str) = value else {
        throw ParamError.wrongType(key: key, expected: "a string")
    }
    return str
}

func extractOptionalString(_ key: String, from params: CallTool.Parameters) -> String? {
    if case .string(let value) = params.arguments?[key] { return value }
    return nil
}

func extractInt(_ key: String, from params: CallTool.Parameters) throws -> Int {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    if case .int(let n) = value { return n }
    if case .double(let n) = value, let int = Int(exactly: n) { return int }
    throw ParamError.wrongType(key: key, expected: "an integer")
}

func extractOptionalInt(_ key: String, from params: CallTool.Parameters) -> Int? {
    if case .int(let value) = params.arguments?[key] { return value }
    if case .double(let value) = params.arguments?[key], let int = Int(exactly: value) { return int }
    return nil
}

func extractDouble(_ key: String, from params: CallTool.Parameters) throws -> Double {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    if case .double(let n) = value { return n }
    if case .int(let n) = value { return Double(n) }
    throw ParamError.wrongType(key: key, expected: "a number")
}

func extractOptionalDouble(_ key: String, from params: CallTool.Parameters) -> Double? {
    if case .double(let value) = params.arguments?[key] { return value }
    if case .int(let value) = params.arguments?[key] { return Double(value) }
    return nil
}

func extractOptionalBool(_ key: String, from params: CallTool.Parameters) -> Bool? {
    if case .bool(let value) = params.arguments?[key] { return value }
    return nil
}

func extractArray(_ key: String, from params: CallTool.Parameters) throws -> [Value] {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    guard case .array(let arr) = value else {
        throw ParamError.wrongType(key: key, expected: "an array")
    }
    return arr
}
