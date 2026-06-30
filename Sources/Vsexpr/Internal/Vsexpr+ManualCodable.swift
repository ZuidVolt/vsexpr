import VsexprLib

// MARK: - Key Transformation Helper

@inline(always)
func camelToSnake(_ camelKey: String) -> String {
    var result = ""
    var isFirst = true
    for scalar in camelKey.unicodeScalars {
        let val = UInt8(clamping: scalar.value)
        if val >= 0x41, val <= 0x5A {
            if !isFirst {
                result.append("_")
            }
            result.append(Character(UnicodeScalar(val | 0x20)))
        } else {
            result.append(Character(scalar))
        }
        isFirst = false
    }
    return result
}

// MARK: - Manual Decoding Protocol

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

// MARK: - Manual Encoding Protocol

public protocol VsexprEncodable: Sendable {
    func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) throws(VsexprError)
}

extension VsexprEncodable {
    public func encode(to string: inout String) throws(VsexprError) {
        try encode(to: &string, strategy: .convertToSnakeCase)
    }
}

extension String: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        var needsQuote = false
        if isEmpty {
            needsQuote = true
        } else {
            for byte in utf8 {
                if byte == 0x20 || byte == 0x28 || byte == 0x29 || byte == 0x22 || byte == 0x5C || byte == 0x0A
                    || byte == 0x09 || byte == 0x0D {
                    needsQuote = true
                    break
                }
            }
        }

        if needsQuote {
            string.append("\"")
            for byte in utf8 {
                switch byte {
                case 0x0A: string.append("\\n")
                case 0x09: string.append("\\t")
                case 0x0D: string.append("\\r")
                case 0x22: string.append("\\\"")
                case 0x5C: string.append("\\\\")
                default: string.append(Character(UnicodeScalar(byte)))
                }
            }
            string.append("\"")
        } else {
            string.append(self)
        }
    }
}

extension UInt32: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(String(self))
    }
}

extension UInt64: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(String(self))
    }
}

extension Int32: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(String(self))
    }
}

extension Int: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(String(self))
    }
}

extension Double: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(String(self))
    }
}

extension Bool: VsexprEncodable {
    public func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) {
        string.append(self ? "true" : "false")
    }
}

// MARK: - Strategy-Aware Key Comparison Helper

@inline(always)
func matchFileKey(_ tokenKey: String, expectedSwiftKey: String, strategy: VsexprDecoder.KeyDecodingStrategy) -> Bool {
    switch strategy {
    case .useDefaultKeys:
        return tokenKey == expectedSwiftKey
    case .convertFromSnakeCase:
        return snakeToCamel(tokenKey) == expectedSwiftKey
    case .convertFromKebabCase:
        return kebabToCamel(tokenKey) == expectedSwiftKey
    case .custom(let closure):
        return closure([AnyCodingKey(stringValue: tokenKey)]).stringValue == expectedSwiftKey
    }
}

// MARK: - SExprTokenStream Key-Value Extraction Helpers

extension SExprTokenStream {
    public mutating func extractAtomValue(for key: String) -> String? {
        skipToNextPair()
        guard !isAtEnd else { return nil }

        guard let openToken = peek(), s_expr_token_is_open_paren(openToken) else { return nil }
        advance()

        guard let keyToken = peek(), s_expr_token_is_atom(keyToken) else {
            skipPastClose()
            return nil
        }
        let tokenKey = tokenText(keyToken)
        guard matchFileKey(tokenKey, expectedSwiftKey: key, strategy: keyDecodingStrategy) else {
            skipPastClose()
            return nil
        }
        advance()

        guard let valToken = peek(), s_expr_token_is_atom(valToken) else {
            skipPastClose()
            return nil
        }
        let value = tokenText(valToken)
        advance()

        skipPastClose()
        return value
    }

    public mutating func extractUInt32Value(for key: String) -> UInt32? {
        guard let str = extractAtomValue(for: key) else { return nil }
        return UInt32(str)
    }

    public mutating func extractBoolValue(for key: String) -> Bool? {
        guard let str = extractAtomValue(for: key) else { return nil }
        switch str {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }
}

// MARK: - SExprTokenStream Key-Value Typed Extraction Helpers

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

    public mutating func requireGroup(for key: String) throws(VsexprError) -> SExprTokenStream {
        guard let group = extractGroup(for: key) else {
            throw .missingKey(key)
        }
        return group
    }
}

// MARK: - SExprTokenStream Key-Value Insertion Helpers

extension SExprTokenStream {
    public static func serialize<T: VsexprEncodable>(_ value: T) throws(VsexprError) -> String {
        var string = ""
        try value.encode(to: &string, strategy: .convertToSnakeCase)
        return string
    }
}
