public import Foundation
import vsexprLib

// MARK: - Optional Encoding Protocol

private protocol OptionalEncoding {
    var _isNil: Bool { get }
    func _encodeNil(to encoder: VsexprEncoderImpl)
    func _encodeWrapped(to encoder: VsexprEncoderImpl) throws
}

extension Optional: OptionalEncoding where Wrapped: Encodable {
    fileprivate var _isNil: Bool {
        switch self {
        case .none: return true
        case .some: return false
        }
    }

    fileprivate func _encodeNil(to encoder: VsexprEncoderImpl) {
        encoder.writeAscii("nil ")
    }

    fileprivate func _encodeWrapped(to encoder: VsexprEncoderImpl) throws {
        switch self {
        case .none: break
        case .some(let wrapped):
            try wrapped.encode(to: encoder)
        }
    }
}

@inline(always)
func snakeToCamel(_ snake: String) -> String {
    guard snake.contains("_") else { return snake }
    var result = ""
    var capitalizeNext = false
    for byte in snake.utf8 {
        if byte == 0x5F {
            capitalizeNext = true
        } else {
            if capitalizeNext {
                if byte >= 0x61, byte <= 0x7A {
                    result.append(Character(UnicodeScalar(byte - 0x20)))
                } else {
                    result.append(Character(UnicodeScalar(byte)))
                }
                capitalizeNext = false
            } else {
                result.append(Character(UnicodeScalar(byte)))
            }
        }
    }
    return result
}

@inline(always)
func hashSnakeKey(_ camelKey: String, strategy: VsexprDecoder.KeyDecodingStrategy = .convertFromSnakeCase) -> UInt64 {
    switch strategy {
    case .useDefaultKeys:
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
            var count = 0
            for byte in camelKey.utf8 {
                guard count < 63 else { break }
                buffer[count] = byte
                count += 1
            }
            return fnv1a64(bytes: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count))
        }
    case .convertFromSnakeCase:
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
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
}

// MARK: - VsexprDecoder (Unified)

public final class VsexprDecoder: @unchecked Sendable {
    public enum KeyDecodingStrategy: Sendable {
        case useDefaultKeys
        case convertFromSnakeCase
    }

    public var keyDecodingStrategy: KeyDecodingStrategy = .convertFromSnakeCase
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    // MARK: Codable (Runtime Reflection)

    public func decode<T: Decodable>(_ type: T.Type, from payload: String) throws(VsexprError) -> T {
        let stream = try Vsexpr.tokenize(payload)
        let decoder = VsexprDecoderImpl(
            stream: stream, payload: payload, strategy: keyDecodingStrategy, userInfo: userInfo)
        do {
            return try T(from: decoder)
        } catch {
            throw .syntaxError(description: "\(error)")
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(VsexprError) -> T {
        let stream = try Vsexpr.tokenize(data)
        let decoder = VsexprDecoderImpl(
            stream: stream, payload: "", strategy: keyDecodingStrategy, userInfo: userInfo)
        do {
            return try T(from: decoder)
        } catch {
            throw .syntaxError(description: "\(error)")
        }
    }

    // MARK: VsexprDecodable (Zero-Reflection Manual)

    public func decode<T: VsexprDecodable>(_ type: T.Type, from payload: String) throws(VsexprError) -> T {
        var stream = try Vsexpr.tokenize(payload)
        stream.keyDecodingStrategy = keyDecodingStrategy
        return try T(from: &stream)
    }

    public func decode<T: VsexprDecodable>(_ type: T.Type, from data: Data) throws(VsexprError) -> T {
        var stream = try Vsexpr.tokenize(data)
        stream.keyDecodingStrategy = keyDecodingStrategy
        return try T(from: &stream)
    }

    // MARK: Streaming (Progressive Ingestion)

    /// Progressively decodes a sequence of values from an asynchronous byte stream.
    ///
    /// Each top-level S-expression in the stream is independently framed, tokenized,
    /// and decoded. Memory usage is bounded by the size of the largest single frame,
    /// regardless of total stream length.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode from each frame.
    ///   - bytes: An asynchronous byte source (e.g., `URLSession.bytes(from:)`).
    ///   - strategy: The framing strategy for detecting complete expressions.
    ///     Defaults to `.balancedParentheses`.
    /// - Returns: A `VsexprAsyncSequence` that yields decoded values as complete
    ///   S-expression frames are detected in the stream.
    ///
    /// - Note: Both `Decodable` and `VsexprDecodable` types are supported via
    ///   Swift's overload resolution. This method accepts `Decodable`; for
    ///   zero-reflection types, the compiler selects the `VsexprDecodable` overload.
    public func decodeStream<T: Decodable, Base: AsyncSequence>(
        _ type: T.Type, from bytes: Base, strategy: VsexprFramingStrategy = .lineDelimited
    ) -> VsexprAsyncSequence<Base, T> where Base.Element == UInt8, Base.Failure == any Error {
        VsexprAsyncSequence<Base, T>(bytes, decoder: self, strategy: strategy)
    }
}

// MARK: - VsexprEncoder (Unified)

public final class VsexprEncoder: @unchecked Sendable {
    public enum KeyEncodingStrategy: Sendable {
        case useDefaultKeys
        case convertToSnakeCase
    }

    public var keyEncodingStrategy: KeyEncodingStrategy = .convertToSnakeCase
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    // MARK: Codable (Runtime Reflection)

    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let encoder = VsexprEncoderImpl(strategy: keyEncodingStrategy, userInfo: userInfo)
        try value.encode(to: encoder)
        if encoder.buffer.last == 0x20 {
            encoder.buffer.removeLast()
        }
        return String(decoding: encoder.buffer, as: UTF8.self)
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        Data(try encodeToString(value).utf8)
    }

    // MARK: VsexprEncodable (Zero-Reflection Manual)

    public func encodeToString<T: VsexprEncodable>(_ value: T) throws(VsexprError) -> String {
        var result = ""
        try value.encode(to: &result, strategy: keyEncodingStrategy)
        if result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }

    public func encode<T: VsexprEncodable>(_ value: T) throws(VsexprError) -> Data {
        Data(try encodeToString(value).utf8)
    }
}

// MARK: - Internal Decoder Implementation

final class VsexprDecoderImpl: Decoder {
    var stream: SExprTokenStream
    var codingPath: [any CodingKey] = []
    let keyMap: [UInt64: Range<Int>]
    let keyStrings: [String]
    let userInfo: [CodingUserInfoKey: Any]
    let payload: String
    let keyDecodingStrategy: VsexprDecoder.KeyDecodingStrategy

    init(
        stream: SExprTokenStream, payload: String,
        strategy: VsexprDecoder.KeyDecodingStrategy = .convertFromSnakeCase,
        userInfo: [CodingUserInfoKey: Any] = [:]
    ) {
        self.stream = stream
        self.payload = payload
        self.keyDecodingStrategy = strategy
        self.userInfo = userInfo
        let result = stream.collectKeyMapAndStrings()
        self.keyMap = result.map
        if strategy == .convertFromSnakeCase {
            self.keyStrings = result.strings.map { snakeToCamel($0) }
        } else {
            self.keyStrings = result.strings
        }
    }

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(VsexprKeyedDecodingContainer<Key>(decoder: self))
    }

    func unkeyedContainer() -> any UnkeyedDecodingContainer {
        VsexprUnkeyedDecodingContainer(decoder: self)
    }

    func singleValueContainer() -> any SingleValueDecodingContainer {
        VsexprSingleValueDecodingContainer(decoder: self)
    }
}

// MARK: - Keyed Decoding

struct VsexprKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [K] { decoder.keyStrings.compactMap { K(stringValue: $0) } }

    init(decoder: VsexprDecoderImpl) {
        self.decoder = decoder
    }

    func contains(_ key: K) -> Bool {
        let h = hashSnakeKey(key.stringValue, strategy: decoder.keyDecodingStrategy)
        return decoder.keyMap[h] != nil
    }

    func decodeNil(forKey key: K) -> Bool {
        !contains(key)
    }

    private func readAtomText(forKey key: String) throws -> String {
        let h = hashSnakeKey(key, strategy: decoder.keyDecodingStrategy)
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
        let h = hashSnakeKey(key.stringValue, strategy: decoder.keyDecodingStrategy)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let subDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        return try T(from: subDecoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: K
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let h = hashSnakeKey(key.stringValue, strategy: decoder.keyDecodingStrategy)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let subDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        return KeyedDecodingContainer(
            VsexprKeyedDecodingContainer<NestedKey>(decoder: subDecoder))
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer {
        let h = hashSnakeKey(key.stringValue, strategy: decoder.keyDecodingStrategy)
        guard let range = decoder.keyMap[h] else {
            throw VsexprError.missingKey(key.stringValue)
        }
        let subStream = SExprTokenStream(
            startOffset: decoder.stream.startOffset + range.lowerBound,
            count: range.count,
            storage: decoder.stream._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let subDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        return VsexprUnkeyedDecodingContainer(decoder: subDecoder)
    }

    func superDecoder() -> any Decoder {
        decoder
    }

    func superDecoder(forKey key: K) -> any Decoder {
        decoder
    }
}

// MARK: - Unkeyed Decoding

struct VsexprUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { nil }
    var isAtEnd: Bool { decoder.stream.isAtEnd }
    var currentIndex: Int { 0 }

    init(decoder: VsexprDecoderImpl) {
        self.decoder = decoder
    }

    mutating func decodeNil() -> Bool {
        if decoder.stream.isAtEnd { return true }
        if let token = decoder.stream.peek(), s_expr_token_is_atom(token),
            tokenText(token) == "nil"
        {
            decoder.stream.advance()
            return true
        }
        return false
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
        var s = decoder.stream

        guard let openToken = s.peek(), s_expr_token_is_open_paren(openToken) else {
            let subDecoder = VsexprDecoderImpl(
                stream: s, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
            let value = try T(from: subDecoder)
            decoder.stream = subDecoder.stream
            return value
        }

        let startPos = s.position
        s.skipGroup()
        let endPos = s.position

        let subStream = SExprTokenStream(
            startOffset: s.startOffset + startPos,
            count: endPos - startPos,
            storage: s._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let subDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        let value = try T(from: subDecoder)

        decoder.stream = s
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) -> KeyedDecodingContainer<NestedKey> {
        var s = decoder.stream
        let startPos = s.position
        s.skipGroup()
        let endPos = s.position

        let subStream = SExprTokenStream(
            startOffset: s.startOffset + startPos,
            count: endPos - startPos,
            storage: s._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let nestedDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        decoder.stream = s
        return KeyedDecodingContainer(
            VsexprKeyedDecodingContainer<NestedKey>(decoder: nestedDecoder))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedDecodingContainer {
        var s = decoder.stream
        let startPos = s.position
        s.skipGroup()
        let endPos = s.position

        let subStream = SExprTokenStream(
            startOffset: s.startOffset + startPos,
            count: endPos - startPos,
            storage: s._storage,
            strategy: decoder.keyDecodingStrategy
        )
        let nestedDecoder = VsexprDecoderImpl(
            stream: subStream, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        decoder.stream = s
        return Self(decoder: nestedDecoder)
    }

    mutating func superDecoder() -> any Decoder {
        decoder
    }
}

// MARK: - Single Value Decoding

struct VsexprSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: VsexprDecoderImpl
    var codingPath: [any CodingKey] { decoder.codingPath }

    init(decoder: VsexprDecoderImpl) {
        self.decoder = decoder
    }

    func decodeNil() -> Bool {
        if decoder.stream.isAtEnd { return true }
        if let token = decoder.stream.peek(), s_expr_token_is_atom(token),
            tokenText(token) == "nil"
        {
            var s = decoder.stream
            s.advance()
            decoder.stream = s
            return true
        }
        return false
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
        let subDecoder = VsexprDecoderImpl(stream: s, payload: decoder.payload, strategy: decoder.keyDecodingStrategy)
        let value = try T(from: subDecoder)
        decoder.stream = subDecoder.stream
        return value
    }
}

// MARK: - Encoder Core

final class VsexprEncoderImpl: Encoder {
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any]
    var buffer: ContiguousArray<UInt8>
    let keyEncodingStrategy: VsexprEncoder.KeyEncodingStrategy

    init(
        strategy: VsexprEncoder.KeyEncodingStrategy = .convertToSnakeCase,
        userInfo: [CodingUserInfoKey: Any] = [:]
    ) {
        self.keyEncodingStrategy = strategy
        self.userInfo = userInfo
        self.buffer = ContiguousArray<UInt8>()
        self.buffer.reserveCapacity(4_096)
    }

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            VsexprKeyedEncodingContainer<Key>(encoder: self, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        VsexprUnkeyedEncodingContainer(encoder: self, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        VsexprSingleValueEncodingContainer(encoder: self, codingPath: codingPath)
    }
}

// MARK: - Encoder Buffer Primitives

extension VsexprEncoderImpl {
    @inline(always)
    func writeByte(_ byte: UInt8) {
        buffer.append(byte)
    }

    @inline(always)
    func writeBytes(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
    }

    @inline(always)
    func writeAscii(_ string: StaticString) {
        string.withUTF8Buffer { ptr in
            buffer.append(contentsOf: ptr)
        }
    }

    @inline(always)
    func writeString(_ value: String) {
        buffer.append(contentsOf: value.utf8)
    }

    @inline(always)
    func writeSnakeKey(_ camelKey: String) {
        switch keyEncodingStrategy {
        case .useDefaultKeys:
            writeString(camelKey)
        case .convertToSnakeCase:
            var isFirst = true
            for scalar in camelKey.unicodeScalars {
                let val = UInt8(clamping: scalar.value)
                if val >= 0x41, val <= 0x5A {
                    if !isFirst {
                        writeByte(0x5F)
                    }
                    writeByte(val | 0x20)
                } else {
                    writeByte(val)
                }
                isFirst = false
            }
        }
    }

    @inline(always)
    func writeQuotedString(_ value: String) {
        var needsQuote = false
        if value.isEmpty {
            needsQuote = true
        } else {
            for byte in value.utf8 {
                if byte == 0x20 || byte == 0x28 || byte == 0x29 || byte == 0x22 || byte == 0x5C || byte == 0x0A
                    || byte == 0x09 || byte == 0x0D
                {
                    needsQuote = true
                    break
                }
            }
        }

        if needsQuote {
            writeByte(0x22)
            for byte in value.utf8 {
                switch byte {
                case 0x0A:
                    writeByte(0x5C)
                    writeByte(0x6E)
                case 0x09:
                    writeByte(0x5C)
                    writeByte(0x74)
                case 0x0D:
                    writeByte(0x5C)
                    writeByte(0x72)
                case 0x22:
                    writeByte(0x5C)
                    writeByte(0x22)
                case 0x5C:
                    writeByte(0x5C)
                    writeByte(0x5C)
                default:
                    writeByte(byte)
                }
            }
            writeByte(0x22)
        } else {
            writeString(value)
        }
    }

    @inline(always)
    func writeInt<T: FixedWidthInteger>(_ value: T) {
        writeString(String(value))
    }

    @inline(always)
    func writeBool(_ value: Bool) {
        if value {
            writeAscii("true")
        } else {
            writeAscii("false")
        }
    }

    @inline(__always)
    func writeDouble(_ value: Double) {
        let str = String(value)
        writeString(str)
    }
}

// MARK: - Keyed Encoding Container

struct VsexprKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: VsexprEncoderImpl
    var codingPath: [any CodingKey]

    // MARK: Primitive Hot Paths

    mutating func encode(_ value: String, forKey key: K) {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        encoder.writeQuotedString(value)
        encoder.writeAscii(") ")
    }

    mutating func encode(_ value: Bool, forKey key: K) {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        encoder.writeBool(value)
        encoder.writeAscii(") ")
    }

    mutating func encode(_ value: Double, forKey key: K) {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        encoder.writeDouble(value)
        encoder.writeAscii(") ")
    }

    mutating func encode(_ value: Float, forKey key: K) {
        encode(Double(value), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: K) {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        encoder.writeInt(value)
        encoder.writeAscii(") ")
    }

    mutating func encode(_ value: Int8, forKey key: K) {
        encode(Int(value), forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: K) {
        encode(Int(value), forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: K) {
        encode(Int(value), forKey: key)
    }

    mutating func encode(_ value: Int64, forKey key: K) {
        encode(Int(value), forKey: key)
    }

    mutating func encode(_ value: UInt, forKey key: K) {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        encoder.writeInt(value)
        encoder.writeAscii(") ")
    }

    mutating func encode(_ value: UInt8, forKey key: K) {
        encode(UInt(value), forKey: key)
    }

    mutating func encode(_ value: UInt16, forKey key: K) {
        encode(UInt(value), forKey: key)
    }

    mutating func encode(_ value: UInt32, forKey key: K) {
        encode(UInt(value), forKey: key)
    }

    mutating func encode(_ value: UInt64, forKey key: K) {
        encode(UInt(value), forKey: key)
    }

    // MARK: Generic Fallback

    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        try value.encode(to: encoder)
        encoder.writeAscii(") ")
    }

    // MARK: Nil Encoding

    mutating func encodeNil(forKey key: K) {}

    // MARK: Encode If Present

    mutating func encodeIfPresent(_ value: String?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Bool?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Double?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Float?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Int?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Int8?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Int16?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Int32?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: Int64?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: UInt?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: UInt8?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: UInt16?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: UInt32?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent(_ value: UInt64?, forKey key: K) {
        if let v = value { encode(v, forKey: key) }
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: K) throws {
        if let v = value { try encode(v, forKey: key) }
    }

    // MARK: Nested Containers

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: K
    ) -> KeyedEncodingContainer<NestedKey> {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        return KeyedEncodingContainer(
            VsexprKeyedEncodingContainer<NestedKey>(encoder: encoder, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: K) -> any UnkeyedEncodingContainer {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        return VsexprUnkeyedEncodingContainer(encoder: encoder, codingPath: codingPath + [key])
    }

    // MARK: Super Encoder

    mutating func superEncoder() -> any Encoder {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey("super")
        encoder.writeByte(0x20)
        return encoder
    }

    mutating func superEncoder(forKey key: K) -> any Encoder {
        encoder.writeByte(0x28)
        encoder.writeSnakeKey(key.stringValue)
        encoder.writeByte(0x20)
        return encoder
    }
}

// MARK: - Unkeyed Encoding Container

struct VsexprUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: VsexprEncoderImpl
    var codingPath: [any CodingKey]
    var count: Int = 0

    // MARK: Primitive Hot Paths

    mutating func encode(_ value: String) {
        encoder.writeQuotedString(value)
        encoder.writeByte(0x20)
        count += 1
    }

    mutating func encode(_ value: Bool) {
        encoder.writeBool(value)
        encoder.writeByte(0x20)
        count += 1
    }

    mutating func encode(_ value: Double) {
        encoder.writeDouble(value)
        encoder.writeByte(0x20)
        count += 1
    }

    mutating func encode(_ value: Float) {
        encode(Double(value))
    }

    mutating func encode(_ value: Int) {
        encoder.writeInt(value)
        encoder.writeByte(0x20)
        count += 1
    }

    mutating func encode(_ value: Int8) { encode(Int(value)) }
    mutating func encode(_ value: Int16) { encode(Int(value)) }
    mutating func encode(_ value: Int32) { encode(Int(value)) }
    mutating func encode(_ value: Int64) { encode(Int(value)) }

    mutating func encode(_ value: UInt) {
        encoder.writeInt(value)
        encoder.writeByte(0x20)
        count += 1
    }

    mutating func encode(_ value: UInt8) { encode(UInt(value)) }
    mutating func encode(_ value: UInt16) { encode(UInt(value)) }
    mutating func encode(_ value: UInt32) { encode(UInt(value)) }
    mutating func encode(_ value: UInt64) { encode(UInt(value)) }

    // MARK: Generic Fallback

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let v = value as? String {
            encode(v)
            return
        }
        if let v = value as? Bool {
            encode(v)
            return
        }
        if let v = value as? Double {
            encode(v)
            return
        }
        if let v = value as? Float {
            encode(v)
            return
        }
        if let v = value as? Int {
            encode(v)
            return
        }
        if let v = value as? Int8 {
            encode(v)
            return
        }
        if let v = value as? Int16 {
            encode(v)
            return
        }
        if let v = value as? Int32 {
            encode(v)
            return
        }
        if let v = value as? Int64 {
            encode(v)
            return
        }
        if let v = value as? UInt {
            encode(v)
            return
        }
        if let v = value as? UInt8 {
            encode(v)
            return
        }
        if let v = value as? UInt16 {
            encode(v)
            return
        }
        if let v = value as? UInt32 {
            encode(v)
            return
        }
        if let v = value as? UInt64 {
            encode(v)
            return
        }
        if let opt = value as? any OptionalEncoding {
            if opt._isNil {
                opt._encodeNil(to: encoder)
                count += 1
                return
            }
            try opt._encodeWrapped(to: encoder)
            count += 1
            return
        }
        encoder.writeByte(0x28)
        try value.encode(to: encoder)
        encoder.writeAscii(") ")
        count += 1
    }

    // MARK: Nil Encoding

    mutating func encodeNil() {
        encoder.writeAscii("nil ")
        count += 1
    }

    // MARK: Encode If Present

    mutating func encodeIfPresent(_ value: String?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Bool?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Double?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Float?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Int?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Int8?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Int16?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Int32?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: Int64?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: UInt?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: UInt8?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: UInt16?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: UInt32?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent(_ value: UInt64?) {
        if let v = value { encode(v) } else { encodeNil() }
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?) throws {
        if let v = value { try encode(v) } else { encodeNil() }
    }

    // MARK: Nested Containers

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        encoder.writeByte(0x28)
        return KeyedEncodingContainer(
            VsexprKeyedEncodingContainer<NestedKey>(encoder: encoder, codingPath: codingPath))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        encoder.writeByte(0x28)
        return Self(encoder: encoder, codingPath: codingPath)
    }

    // MARK: Super Encoder

    mutating func superEncoder() -> any Encoder {
        encoder
    }
}

// MARK: - Single Value Encoding Container

struct VsexprSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: VsexprEncoderImpl
    var codingPath: [any CodingKey]

    // MARK: Primitive Hot Paths

    mutating func encode(_ value: String) {
        encoder.writeQuotedString(value)
    }

    mutating func encode(_ value: Bool) {
        encoder.writeBool(value)
    }

    mutating func encode(_ value: Double) {
        encoder.writeDouble(value)
    }

    mutating func encode(_ value: Float) {
        encode(Double(value))
    }

    mutating func encode(_ value: Int) {
        encoder.writeInt(value)
    }

    mutating func encode(_ value: Int8) { encode(Int(value)) }
    mutating func encode(_ value: Int16) { encode(Int(value)) }
    mutating func encode(_ value: Int32) { encode(Int(value)) }
    mutating func encode(_ value: Int64) { encode(Int(value)) }

    mutating func encode(_ value: UInt) {
        encoder.writeInt(value)
    }

    mutating func encode(_ value: UInt8) { encode(UInt(value)) }
    mutating func encode(_ value: UInt16) { encode(UInt(value)) }
    mutating func encode(_ value: UInt32) { encode(UInt(value)) }
    mutating func encode(_ value: UInt64) { encode(UInt(value)) }

    // MARK: Generic Fallback

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: encoder)
    }

    // MARK: Nil Encoding

    mutating func encodeNil() {}
}
