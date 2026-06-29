import vsexprLib

public protocol VsexprDecodable: Sendable {
    init(from stream: inout SExprTokenStream) throws(VsexprError)
}

extension String: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        guard let token = stream.peek(), s_expr_token_is_atom(token) else {
            throw .typeMismatch(expected: "ATOM", got: "other")
        }
        self = tokenText(token)
        stream.advance()
    }
}

extension UInt32: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        guard let value = UInt32(str) else {
            throw .typeMismatch(expected: "UInt32", got: str)
        }
        self = value
    }
}

extension UInt64: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        guard let value = UInt64(str) else {
            throw .typeMismatch(expected: "UInt64", got: str)
        }
        self = value
    }
}

extension Int32: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        guard let value = Int32(str) else {
            throw .typeMismatch(expected: "Int32", got: str)
        }
        self = value
    }
}

extension Int: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        guard let value = Int(str) else {
            throw .typeMismatch(expected: "Int", got: str)
        }
        self = value
    }
}

extension Double: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        guard let value = Double(str) else {
            throw .typeMismatch(expected: "Double", got: str)
        }
        self = value
    }
}

extension Bool: VsexprDecodable {
    public init(from stream: inout SExprTokenStream) throws(VsexprError) {
        let str = try String(from: &stream)
        switch str {
        case "true", "1", "yes", "on":
            self = true
        case "false", "0", "no", "off":
            self = false
        default:
            throw .typeMismatch(expected: "Bool", got: str)
        }
    }
}

// MARK: - Key-Value Extraction Helpers

extension SExprTokenStream {
    public mutating func extractString(for key: String) throws(VsexprError) -> String {
        guard let value = extractAtomValue(for: key) else {
            throw .missingKey(key)
        }
        return value
    }

    public mutating func extractUInt32(for key: String) throws(VsexprError) -> UInt32 {
        guard let value = extractUInt32Value(for: key) else {
            throw .missingKey(key)
        }
        return value
    }

    public mutating func extractBool(for key: String) throws(VsexprError) -> Bool {
        guard let value = extractBoolValue(for: key) else {
            throw .missingKey(key)
        }
        return value
    }

    public mutating func extractInt(for key: String) throws(VsexprError) -> Int {
        let str = try extractString(for: key)
        guard let value = Int(str) else {
            throw .typeMismatch(expected: "Int", got: str)
        }
        return value
    }

    public mutating func extractDouble(for key: String) throws(VsexprError) -> Double {
        let str = try extractString(for: key)
        guard let value = Double(str) else {
            throw .typeMismatch(expected: "Double", got: str)
        }
        return value
    }

    public mutating func extractGroup(for key: String) throws(VsexprError) -> SExprTokenStream {
        guard let group = extractGroup(for: key) else {
            throw .missingKey(key)
        }
        return group
    }
}
