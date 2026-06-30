public import vsexprLib

@inline(always)
func fnv1a64(bytes: UnsafeRawBufferPointer) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

func tokenText(_ token: SExprToken) -> String {
    let ptr = UnsafeRawPointer(token.ptr).bindMemory(to: UInt8.self, capacity: token.length)
    return String(decoding: UnsafeBufferPointer(start: ptr, count: token.length), as: UTF8.self)
}

final class TokenStorage: @unchecked Sendable {
    var buffer: UnsafeBufferPointer<CChar>
    var result: TokenizerResult
    var payloadString: String
    var owned: Bool

    init(payload: String) {
        self.payloadString = payload
        let length = payload.utf8.count
        let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        payload.withCString { cStr in
            ptr.initialize(from: cStr, count: length)
        }
        ptr[length] = 0
        self.buffer = UnsafeBufferPointer(start: ptr, count: length + 1)
        self.result = tokenize_to_result(ptr, size_t(length))
        self.owned = true
    }

    init(rawBytes: UnsafeRawBufferPointer) {
        self.payloadString = ""
        let length = rawBytes.count
        let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        if length > 0 {
            rawBytes.baseAddress?.withMemoryRebound(to: CChar.self, capacity: length) { src in
                ptr.initialize(from: src, count: length)
            }
        }
        ptr[length] = 0
        self.buffer = UnsafeBufferPointer(start: ptr, count: length + 1)
        self.result = tokenize_to_result(ptr, size_t(length))
        self.owned = true
    }

    init(borrowing result: TokenizerResult, buffer: UnsafeBufferPointer<CChar>) {
        self.payloadString = ""
        self.buffer = buffer
        self.result = result
        self.owned = false
    }

    init() {
        self.payloadString = ""
        self.buffer = UnsafeBufferPointer(start: nil, count: 0)
        self.result = TokenizerResult()
        self.owned = false
    }

    deinit {
        if owned {
            buffer.baseAddress?.deallocate()
        }
    }
}

public struct SExprTokenStream: @unchecked Sendable {
    let _storage: TokenStorage
    public let count: Int
    public let startOffset: Int
    public let truncated: Bool
    public var position: Int
    public var keyDecodingStrategy: VsexprDecoder.KeyDecodingStrategy

    init(
        startOffset: Int, count: Int, storage: TokenStorage, truncated: Bool = false,
        strategy: VsexprDecoder.KeyDecodingStrategy = .convertFromSnakeCase
    ) {
        self._storage = storage
        self.startOffset = startOffset
        self.count = count
        self.truncated = truncated
        self.position = 0
        self.keyDecodingStrategy = strategy
    }

    public var isAtEnd: Bool {
        position >= count
    }

    func token(at index: Int) -> SExprToken {
        _storage.result.data()[startOffset + index]
    }

    func byteOffset(of token: SExprToken) -> Int {
        token.ptr - _storage.buffer.baseAddress!
    }

    public mutating func peek() -> SExprToken? {
        guard position < count else { return nil }
        return token(at: position)
    }

    @discardableResult
    public mutating func advance() -> SExprToken? {
        guard position < count else { return nil }
        let t = token(at: position)
        position += 1
        return t
    }

    public mutating func skipGroup() {
        guard let token = peek(), s_expr_token_is_open_paren(token) else { return }
        var depth = 1
        advance()
        while depth > 0, !isAtEnd {
            if let t = peek() {
                if s_expr_token_is_open_paren(t) { depth += 1 } else if s_expr_token_is_close_paren(t) { depth -= 1 }
            }
            advance()
        }
    }

    public mutating func skipToNextPair() {
        while !isAtEnd {
            if let t = peek(), s_expr_token_is_open_paren(t) {
                return
            }
            advance()
        }
    }

    public mutating func extractGroup(for key: String) -> Self? {
        skipToNextPair()
        guard !isAtEnd else { return nil }

        guard let openToken = peek(), s_expr_token_is_open_paren(openToken) else { return nil }
        advance()

        guard let keyToken = peek(), s_expr_token_is_atom(keyToken) else {
            skipPastClose()
            return nil
        }
        let expected = resolveFileKey(key, strategy: keyDecodingStrategy)
        let tokenKey = tokenText(keyToken)
        guard tokenKey == expected else {
            skipPastClose()
            return nil
        }
        advance()

        guard let groupOpen = peek(), s_expr_token_is_open_paren(groupOpen) else {
            skipPastClose()
            return nil
        }
        let groupStart = position
        skipGroup()
        let groupEnd = position

        return Self(
            startOffset: groupStart,
            count: groupEnd - groupStart,
            storage: _storage,
            strategy: keyDecodingStrategy
        )
    }

    public mutating func collectPairs() -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        while !isAtEnd {
            guard let openToken = peek(), s_expr_token_is_open_paren(openToken) else {
                advance()
                continue
            }
            advance()

            guard let keyToken = peek(), s_expr_token_is_atom(keyToken) else {
                skipPastClose()
                continue
            }
            let key = tokenText(keyToken)
            advance()

            if let valToken = peek(), s_expr_token_is_atom(valToken) {
                let value = tokenText(valToken)
                result.append((key: key, value: value))
                advance()
            }

            skipPastClose()
        }
        return result
    }

    public mutating func collectAllGroups() -> [String: Self] {
        var result: [String: Self] = [:]
        while !isAtEnd {
            guard let openToken = peek(), s_expr_token_is_open_paren(openToken) else {
                advance()
                continue
            }
            advance()

            guard let keyToken = peek(), s_expr_token_is_atom(keyToken) else {
                skipPastClose()
                continue
            }
            let key = tokenText(keyToken)
            advance()

            if let groupOpen = peek(), s_expr_token_is_open_paren(groupOpen) {
                let groupStart = position
                skipGroup()
                let groupEnd = position
                result[key] = Self(
                    startOffset: groupStart,
                    count: groupEnd - groupStart,
                    storage: _storage,
                    strategy: keyDecodingStrategy
                )
            }

            skipPastClose()
        }
        return result
    }

    public mutating func skipPastClose() {
        while !isAtEnd {
            if let t = peek(), s_expr_token_is_close_paren(t) {
                advance()
                return
            }
            if let t = peek(), s_expr_token_is_open_paren(t) {
                skipGroup()
            } else {
                advance()
            }
        }
    }

    func collectKeyMapAndStrings() -> (map: [UInt64: Range<Int>], strings: [String]) {
        var map: [UInt64: Range<Int>] = [:]
        var strings: [String] = []
        var pos = 0
        while pos < count {
            guard token(at: pos).type == .OPEN_PAREN else {
                pos += 1
                continue
            }
            pos += 1
            guard pos < count, token(at: pos).type == .ATOM else {
                continue
            }
            let keyToken = token(at: pos)
            let rawPtr = UnsafeRawPointer(keyToken.ptr)
            let keyHash = fnv1a64(bytes: UnsafeRawBufferPointer(start: rawPtr, count: keyToken.length))
            strings.append(tokenText(keyToken))
            pos += 1

            guard pos < count else { break }

            let valueStart = pos
            var outerDepth = 1
            while pos < count, outerDepth > 0 {
                let t = token(at: pos)
                if t.type == .OPEN_PAREN { outerDepth += 1 } else if t.type == .CLOSE_PAREN { outerDepth -= 1 }
                pos += 1
            }
            map[keyHash] = valueStart..<(pos > 0 ? pos - 1 : pos)
        }
        return (map, strings)
    }
}
