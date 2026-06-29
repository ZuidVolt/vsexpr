import vsexprLib

@inline(__always)
func hashSnakeKey(_ camelKey: String) -> UInt64 {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
        var count = 0
        for scalar in camelKey.unicodeScalars {
            guard count < 63 else { break }
            let val = UInt8(clamping: scalar.value)
            if val >= 0x41, val <= 0x5A {
                if count > 0 {
                    buffer[count] = 0x5F
                    count += 1
                }
                buffer[count] = val | 0x20
                count += 1
            } else {
                buffer[count] = val
                count += 1
            }
        }
        return fnv1a64(bytes: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count))
    }
}

public struct VsexprDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from payload: String) throws(VsexprError) -> T {
        let stream = try Vsexpr.tokenize(payload)
        let decoder = _VsexprDecoderImpl(stream: stream, payload: payload)
        do {
            return try T(from: decoder)
        } catch {
            throw .syntaxError(description: "\(error)")
        }
    }
}

// MARK: - Internal Decoder Implementation

final class _VsexprDecoderImpl: Decoder {
    var stream: SExprTokenStream
    var codingPath: [any CodingKey] = []
    let keyMap: [UInt64: Range<Int>]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let payload: String

    init(stream: SExprTokenStream, payload: String) {
        self.stream = stream
        self.payload = payload
        self.keyMap = stream.collectKeyMap()
    }

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_VsexprKeyedDecodingContainer<Key>(decoder: self))
    }

    func unkeyedContainer() -> any UnkeyedDecodingContainer {
        _VsexprUnkeyedDecoding(decoder: self)
    }

    func singleValueContainer() -> any SingleValueDecodingContainer {
        _VsexprSingleValueDecoding(decoder: self)
    }
}

// MARK: - Keyed Decoding

struct _VsexprKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: _VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [K] { [] }

    init(decoder: _VsexprDecoderImpl) {
        self.decoder = decoder
    }

    func contains(_ key: K) -> Bool {
        let h = hashSnakeKey(key.stringValue)
        return decoder.keyMap[h] != nil
    }

    func decodeNil(forKey key: K) -> Bool {
        !contains(key)
    }

    private func readAtomText(forKey key: String) throws -> String {
        let h = hashSnakeKey(key)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key)
        }
        let token = decoder.stream.token(at: range.lowerBound)
        guard s_expr_token_is_atom(token) else {
            let offset = decoder.stream.byteOffset(of: token)
            let loc = Vsexpr.location(in: decoder.payload, at: offset)
            throw VsexprError.typeMismatch(expected: "ATOM", got: "other", at: loc)
        }
        return tokenText(token)
    }

    func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        let str = try readAtomText(forKey: key.stringValue)
        switch str {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw VsexprError.typeMismatch(expected: "Bool", got: str)
        }
    }

    func decode(_ type: String.Type, forKey key: K) throws -> String {
        try readAtomText(forKey: key.stringValue)
    }

    func decode(_ type: Double.Type, forKey key: K) throws -> Double {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Double(str) else {
            throw VsexprError.typeMismatch(expected: "Double", got: str)
        }
        return value
    }

    func decode(_ type: Float.Type, forKey key: K) throws -> Float {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Float(str) else {
            throw VsexprError.typeMismatch(expected: "Float", got: str)
        }
        return value
    }

    func decode(_ type: Int.Type, forKey key: K) throws -> Int {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Int(str) else {
            throw VsexprError.typeMismatch(expected: "Int", got: str)
        }
        return value
    }

    func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Int8(str) else {
            throw VsexprError.typeMismatch(expected: "Int8", got: str)
        }
        return value
    }

    func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Int16(str) else {
            throw VsexprError.typeMismatch(expected: "Int16", got: str)
        }
        return value
    }

    func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Int32(str) else {
            throw VsexprError.typeMismatch(expected: "Int32", got: str)
        }
        return value
    }

    func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = Int64(str) else {
            throw VsexprError.typeMismatch(expected: "Int64", got: str)
        }
        return value
    }

    func decode(_ type: UInt.Type, forKey key: K) throws -> UInt {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = UInt(str) else {
            throw VsexprError.typeMismatch(expected: "UInt", got: str)
        }
        return value
    }

    func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = UInt8(str) else {
            throw VsexprError.typeMismatch(expected: "UInt8", got: str)
        }
        return value
    }

    func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = UInt16(str) else {
            throw VsexprError.typeMismatch(expected: "UInt16", got: str)
        }
        return value
    }

    func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = UInt32(str) else {
            throw VsexprError.typeMismatch(expected: "UInt32", got: str)
        }
        return value
    }

    func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 {
        let str = try readAtomText(forKey: key.stringValue)
        guard let value = UInt64(str) else {
            throw VsexprError.typeMismatch(expected: "UInt64", got: str)
        }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        if type == String.self {
            return try decode(String.self, forKey: key) as! T
        }
        let h = hashSnakeKey(key.stringValue)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage
        )
        let subDecoder = _VsexprDecoderImpl(stream: subStream, payload: decoder.payload)
        return try T(from: subDecoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: K
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let h = hashSnakeKey(key.stringValue)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage
        )
        let subDecoder = _VsexprDecoderImpl(stream: subStream, payload: decoder.payload)
        return KeyedDecodingContainer(
            _VsexprKeyedDecodingContainer<NestedKey>(decoder: subDecoder))
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer {
        let h = hashSnakeKey(key.stringValue)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage
        )
        let subDecoder = _VsexprDecoderImpl(stream: subStream, payload: decoder.payload)
        return _VsexprUnkeyedDecoding(decoder: subDecoder)
    }

    func superDecoder() -> any Decoder {
        decoder
    }

    func superDecoder(forKey key: K) -> any Decoder {
        decoder
    }
}

// MARK: - Unkeyed Decoding

struct _VsexprUnkeyedDecoding: UnkeyedDecodingContainer {
    let decoder: _VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { nil }
    var isAtEnd: Bool { decoder.stream.isAtEnd }
    var currentIndex: Int { 0 }

    init(decoder: _VsexprDecoderImpl) {
        self.decoder = decoder
    }

    mutating func decodeNil() -> Bool {
        decoder.stream.isAtEnd
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        var s = decoder.stream
        guard let token = s.peek(), s_expr_token_is_atom(token) else {
            throw VsexprError.typeMismatch(expected: "Bool atom", got: "other")
        }
        let str = tokenText(token)
        s.advance()
        decoder.stream = s
        switch str {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw VsexprError.typeMismatch(expected: "Bool", got: str)
        }
    }

    mutating func decode(_ type: String.Type) throws -> String {
        var s = decoder.stream
        guard let token = s.peek(), s_expr_token_is_atom(token) else {
            throw VsexprError.typeMismatch(expected: "ATOM", got: "other")
        }
        let str = tokenText(token)
        s.advance()
        decoder.stream = s
        return str
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let str = try decode(String.self)
        guard let value = Double(str) else {
            throw VsexprError.typeMismatch(expected: "Double", got: str)
        }
        return value
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let d = try decode(Double.self)
        return Float(d)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let str = try decode(String.self)
        guard let value = Int(str) else {
            throw VsexprError.typeMismatch(expected: "Int", got: str)
        }
        return value
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let i = try decode(Int.self)
        return Int8(i)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let i = try decode(Int.self)
        return Int16(i)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let i = try decode(Int.self)
        return Int32(i)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let i = try decode(Int.self)
        return Int64(i)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let i = try decode(Int.self)
        return UInt(i)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let i = try decode(Int.self)
        return UInt8(i)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let i = try decode(Int.self)
        return UInt16(i)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let str = try decode(String.self)
        guard let value = UInt32(str) else {
            throw VsexprError.typeMismatch(expected: "UInt32", got: str)
        }
        return value
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let str = try decode(String.self)
        guard let value = UInt64(str) else {
            throw VsexprError.typeMismatch(expected: "UInt64", got: str)
        }
        return value
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let s = decoder.stream
        let subDecoder = _VsexprDecoderImpl(stream: s, payload: decoder.payload)
        let value = try T(from: subDecoder)
        decoder.stream = subDecoder.stream
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) -> KeyedDecodingContainer<NestedKey> {
        let s = decoder.stream
        let nestedDecoder = _VsexprDecoderImpl(stream: s, payload: decoder.payload)
        decoder.stream = nestedDecoder.stream
        return KeyedDecodingContainer(
            _VsexprKeyedDecodingContainer<NestedKey>(decoder: nestedDecoder))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedDecodingContainer {
        let s = decoder.stream
        let nestedDecoder = _VsexprDecoderImpl(stream: s, payload: decoder.payload)
        decoder.stream = nestedDecoder.stream
        return Self(decoder: nestedDecoder)
    }

    mutating func superDecoder() -> any Decoder {
        decoder
    }
}

// MARK: - Single Value Decoding

struct _VsexprSingleValueDecoding: SingleValueDecodingContainer {
    let decoder: _VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }

    init(decoder: _VsexprDecoderImpl) {
        self.decoder = decoder
    }

    func decodeNil() -> Bool {
        decoder.stream.isAtEnd
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        var s = decoder.stream
        guard let token = s.peek(), s_expr_token_is_atom(token) else {
            throw VsexprError.typeMismatch(expected: "Bool atom", got: "other")
        }
        let str = tokenText(token)
        s.advance()
        decoder.stream = s
        switch str {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw VsexprError.typeMismatch(expected: "Bool", got: str)
        }
    }

    func decode(_ type: String.Type) throws -> String {
        var s = decoder.stream
        guard let token = s.peek(), s_expr_token_is_atom(token) else {
            throw VsexprError.typeMismatch(expected: "ATOM", got: "other")
        }
        let str = tokenText(token)
        s.advance()
        decoder.stream = s
        return str
    }

    func decode(_ type: Double.Type) throws -> Double {
        let str = try decode(String.self)
        guard let value = Double(str) else {
            throw VsexprError.typeMismatch(expected: "Double", got: str)
        }
        return value
    }

    func decode(_ type: Float.Type) throws -> Float {
        let d = try decode(Double.self)
        return Float(d)
    }

    func decode(_ type: Int.Type) throws -> Int {
        let str = try decode(String.self)
        guard let value = Int(str) else {
            throw VsexprError.typeMismatch(expected: "Int", got: str)
        }
        return value
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        let i = try decode(Int.self)
        return Int8(i)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        let i = try decode(Int.self)
        return Int16(i)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        let i = try decode(Int.self)
        return Int32(i)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        let i = try decode(Int.self)
        return Int64(i)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        let i = try decode(Int.self)
        return UInt(i)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        let i = try decode(Int.self)
        return UInt8(i)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        let i = try decode(Int.self)
        return UInt16(i)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        let str = try decode(String.self)
        guard let value = UInt32(str) else {
            throw VsexprError.typeMismatch(expected: "UInt32", got: str)
        }
        return value
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        let str = try decode(String.self)
        guard let value = UInt64(str) else {
            throw VsexprError.typeMismatch(expected: "UInt64", got: str)
        }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let s = decoder.stream
        let subDecoder = _VsexprDecoderImpl(stream: s, payload: decoder.payload)
        let value = try T(from: subDecoder)
        decoder.stream = subDecoder.stream
        return value
    }
}
