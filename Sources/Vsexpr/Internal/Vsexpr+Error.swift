import VsexprLib

public struct FileLocation: Sendable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public var description: String { "line \(line), column \(column)" }
}

public enum VsexprError: Sendable, Error, CustomStringConvertible {
    case missingKey(String, at: FileLocation? = nil)
    case typeMismatch(expected: String, got: String, at: FileLocation? = nil)
    case syntaxError(description: String)
    case unexpectedEnd
    case unexpectedToken(String)
    case nestingDepthExceeded
    case tokenLimitExceeded
    case framingError(description: String)

    public var description: String {
        switch self {
        case .missingKey(let key, let loc):
            let suffix = loc.map { " at \($0)" } ?? ""
            return "Missing key: '\(key)'\(suffix)"
        case .typeMismatch(let expected, let got, let loc):
            let suffix = loc.map { " at \($0)" } ?? ""
            return "Type mismatch: expected \(expected), got '\(got)'\(suffix)"
        case .syntaxError(let description):
            return "Syntax error: \(description)"
        case .unexpectedEnd:
            return "Unexpected end of input"
        case .unexpectedToken(let token):
            return "Unexpected token: \(token)"
        case .nestingDepthExceeded:
            return "Nesting depth exceeded maximum"
        case .tokenLimitExceeded:
            return "Token limit exceeded (\(MAX_TOKENS) tokens)"
        case .framingError(let description):
            return "Framing error: \(description)"
        }
    }
}
