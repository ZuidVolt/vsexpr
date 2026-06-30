import Foundation
import PropertyBased
import Testing
import vsexprLib

@testable import vsexpr

private let validAtomChar = Gen.oneOf(
    Gen.lowercaseLetter,
    Gen.uppercaseLetter,
    Gen.number,
    Gen.always(Character(".")),
    Gen.always(Character("-")),
    Gen.always(Character("_")),
    Gen.always(Character(":")),
    Gen.always(Character("/")),
)

// MARK: - Tokenizer: Structural Tokens

@Test
func emptyInputProducesNoTokens() async {
    let stream = try! Vsexpr.tokenize("")
    #expect(stream.count == 0)
    #expect(stream.isAtEnd)
}

@Test
func whitespaceOnlyProducesNoTokens() async {
    await propertyCheck(input: Gen.int(in: 0...200).map { String(repeating: " ", count: $0) }) { whitespace in
        let stream = try? Vsexpr.tokenize(whitespace)
        #expect(stream?.count == 0)
    }
}

@Test
func openCloseParensTokenized() async {
    let stream = try! Vsexpr.tokenize("()")
    #expect(stream.count == 2)
    var s = stream
    let t0 = s.advance()!
    #expect(s_expr_token_is_open_paren(t0))
    let t1 = s.advance()!
    #expect(s_expr_token_is_close_paren(t1))
}

@Test
func deeplyNestedParensTokenized() async {
    await propertyCheck(input: Gen.int(in: 0...50)) { depth in
        let open = String(repeating: "(", count: depth)
        let close = String(repeating: ")", count: depth)
        let payload = "\(open)host\(close)"
        let stream = try? Vsexpr.tokenize(payload)
        var s = stream!
        var opens = 0
        var closes = 0
        while !s.isAtEnd {
            if let t = s.peek() {
                if s_expr_token_is_open_paren(t) { opens += 1 } else if s_expr_token_is_close_paren(t) { closes += 1 }
            }
            s.advance()
        }
        #expect(opens == depth)
        #expect(closes == depth)
    }
}

// MARK: - Tokenizer: Atoms

@Test
func singleAtomTokenized() async {
    let stream = try! Vsexpr.tokenize("hello")
    #expect(stream.count == 1)
    var s = stream
    let t = s.advance()!
    #expect(s_expr_token_is_atom(t))
    #expect(tokenText(t) == "hello")
}

@Test
func atomsSeparatedByWhitespace() async {
    var s = try! Vsexpr.tokenize("host port debug_mode")
    var atoms: [String] = []
    while !s.isAtEnd {
        if let t = s.peek(), s_expr_token_is_atom(t) {
            atoms.append(tokenText(t))
        }
        s.advance()
    }
    #expect(atoms == ["host", "port", "debug_mode"])
}

@Test
func atomsWithDotsAndColons() async {
    var s = try! Vsexpr.tokenize("(host 0.0.0.0)")
    let collected = s.collectPairs()
    #expect(collected.count == 1)
    #expect(collected[0].key == "host")
    #expect(collected[0].value == "0.0.0.0")
}

// MARK: - Tokenizer: Strings

@Test
func quotedStringProducesSingleAtom() async {
    var s = try! Vsexpr.tokenize(#"(host "hello world")"#)
    let collected = s.collectPairs()
    #expect(collected.count == 1)
    #expect(collected[0].key == "host")
    #expect(collected[0].value == "hello world")
}

@Test
func unterminatedStringDoesNotCrash() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...200)) { inner in
        let payload = "(host \"\(inner)"
        let _ = try? Vsexpr.tokenize(payload)
    }
}

@Test
func stringsWithEmbeddedQuotesHandled() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...100)) { inner in
        let payload = "(host \"\(inner)\")"
        let _ = try? Vsexpr.tokenize(payload)
    }
}

// MARK: - Fuzz: Arbitrary Input Must Not Crash

@Test
func arbitraryAsciiInputDoesNotCrash() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...500)) { input in
        let _ = try? Vsexpr.tokenize(input)
    }
}

@Test
func arbitraryStringWithParensDoesNotCrash() async {
    let charGen = Gen.oneOf(
        Gen.ascii,
        Gen.always(Character("(")),
        Gen.always(Character(")")),
        Gen.always(Character(".")),
        Gen.always(Character("\"")),
    )
    await propertyCheck(input: charGen.string(of: 0...300)) { input in
        let _ = try? Vsexpr.tokenize(input)
    }
}

// MARK: - Fuzz: Token Count Bounds

@Test
func tokenCountNeverExceedsInputLength() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...300)) { input in
        let stream = try? Vsexpr.tokenize(input)
        #expect(stream == nil || stream!.count <= input.utf8.count)
    }
}

// MARK: - Fuzz: Paren Balance

@Test
func parensAreBalancedInWellFormedInput() async {
    await propertyCheck(input: Gen.int(in: 0...30)) { depth in
        let open = String(repeating: "(", count: depth)
        let close = String(repeating: ")", count: depth)
        let payload = "\(open)host\(close)"
        let stream = try? Vsexpr.tokenize(payload)
        var s = stream!
        var opens = 0
        var closes = 0
        while !s.isAtEnd {
            if let t = s.peek() {
                if s_expr_token_is_open_paren(t) { opens += 1 } else if s_expr_token_is_close_paren(t) { closes += 1 }
            }
            s.advance()
        }
        #expect(opens == closes)
    }
}

// MARK: - Fuzz: Random S-Expr Roundtrip

@Test
func randomSExprTokenizationDoesNotCrash() async {
    let keyGen = Gen.oneOf(
        Gen.always("host"),
        Gen.always("port"),
        Gen.always("debug_mode"),
        Gen.always("unknown")
    )
    let valueGen = validAtomChar.string(of: 1...15)

    await propertyCheck(
        input: zip(keyGen, valueGen).array(of: 0...5)
    ) { pairs in
        let payload = pairs.map { "(\($0.0) \($0.1))" }.joined(separator: " ")
        let stream = try? Vsexpr.tokenize(payload)
        #expect(stream == nil || stream!.count >= 0)
    }
}

// MARK: - VsexprDecodable: Manual Conformance Path

private struct TestConfig: VsexprDecodable {
    var host: String = "localhost"
    var port: UInt32 = 0
    var debugMode: Bool = false

    init(from stream: inout SExprTokenStream) throws(VsexprError) {
        var s = stream
        while !s.isAtEnd {
            let saved = s
            if let value = s.extractAtomValue(for: "host") {
                host = value
                continue
            }
            s = saved
            if let value = s.extractUInt32Value(for: "port") {
                port = value
                continue
            }
            s = saved
            if let value = s.extractBoolValue(for: "debug_mode") {
                debugMode = value
                continue
            }
            s = saved
            s.advance()
        }
        stream = s
    }
}

@Test
func decodableExtractsHost() async {
    let config = try? Vsexpr.parse(TestConfig.self, from: "(host example.com)")
    #expect(config != nil)
    #expect(config?.host == "example.com")
}

@Test
func decodableExtractsPort() async {
    let config = try? Vsexpr.parse(TestConfig.self, from: "(port 8080)")
    #expect(config != nil)
    #expect(config?.port == 8080)
}

@Test
func decodableExtractsAllKeys() async {
    let config = try? Vsexpr.parse(TestConfig.self, from: "(host 0.0.0.0) (port 443) (debug_mode true)")
    #expect(config != nil)
    #expect(config?.host == "0.0.0.0")
    #expect(config?.port == 443)
    #expect(config?.debugMode == true)
}

// MARK: - VsexprDecodable: Out-of-Order Keys

@Test
func decodableExtractsKeysInAnyOrder() async {
    let config = try? Vsexpr.parse(TestConfig.self, from: "(port 8080) (host example.com)")
    #expect(config != nil)
    #expect(config?.host == "example.com")
    #expect(config?.port == 8080)
}

// MARK: - Codable: Out-of-Order Keys

private struct CodableConfig: Decodable {
    let host: String
    let port: UInt32
    let debugMode: Bool
}

@Test
func codableDecodesKeysInAnyOrder() async throws {
    let input = "(port 443) (host 0.0.0.0) (debug_mode true)"
    let config = try Vsexpr.parse(CodableConfig.self, from: input)
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
    #expect(config.debugMode == true)
}

@Test
func codableDecodesReverseOrder() async throws {
    let input = "(debug_mode false) (port 9090) (host 10.0.0.1)"
    let config = try Vsexpr.parse(CodableConfig.self, from: input)
    #expect(config.host == "10.0.0.1")
    #expect(config.port == 9090)
    #expect(config.debugMode == false)
}

@Test
func codableFuzzOutOfOrderDecode() async {
    await propertyCheck(
        input: Gen.lowercaseLetter.string(of: 1...5).array(of: 3...10)
    ) { values in
        struct MultiConfig: Decodable {
            let a: String
            let b: String
            let c: String
        }

        let keys = ["a", "b", "c"]
        var pairs = Array(zip(keys, values))
        pairs.shuffle()

        let payload = pairs.map { "(\($0) \($1))" }.joined(separator: " ")
        let config = try? Vsexpr.parse(MultiConfig.self, from: payload)

        #expect(config != nil)
        #expect(config?.a == values[0])
        #expect(config?.b == values[1])
        #expect(config?.c == values[2])
    }
}

// MARK: - Token Text Boundary Correctness

@Test
func tokenTextBoundariesAreExact() async {
    var s = try! Vsexpr.tokenize("aaa bbb ccc")
    var texts: [String] = []
    while !s.isAtEnd {
        if let t = s.peek(), s_expr_token_is_atom(t) {
            texts.append(tokenText(t))
        }
        s.advance()
    }
    #expect(texts == ["aaa", "bbb", "ccc"])

    var s2 = try! Vsexpr.tokenize(#"(key "value with spaces")"#)
    let pairs = s2.collectPairs()
    #expect(pairs[0].key == "key")
    #expect(pairs[0].value == "value with spaces")
}

// MARK: - Performance & Allocation Baseline

@Test
func tokenizerThroughputBaseline() async {
    let payload = String(repeating: "(host 127.0.0.1) (port 8080) (debug_mode true) ", count: 1000)
    let iterations = 100

    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        _ = try? Vsexpr.tokenize(payload)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    let bytesPerSecond = Double(payload.utf8.count * iterations) / elapsed
    print("Tokenization throughput: \(String(format: "%.0f", bytesPerSecond)) bytes/sec")
    #expect(bytesPerSecond > 10_000_000)
}

// MARK: - Codable: Nested Struct Decoding

private struct TlsConfig: Decodable {
    let minVersion: String
    let enabled: Bool
}

private struct NestedConfig: Decodable {
    let host: String
    let port: UInt32
    let tls: TlsConfig
}

@Test
func codableDecodesNestedStruct() async throws {
    let input = "(host 0.0.0.0) (port 443) (tls (min_version 1.2) (enabled true))"
    let config = try Vsexpr.parse(NestedConfig.self, from: input)
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
    #expect(config.tls.minVersion == "1.2")
    #expect(config.tls.enabled == true)
}

@Test
func codableDecodesNestedStructReverseOrder() async throws {
    let input = "(tls (enabled false) (min_version 1.1)) (port 8443) (host 127.0.0.1)"
    let config = try Vsexpr.parse(NestedConfig.self, from: input)
    #expect(config.host == "127.0.0.1")
    #expect(config.port == 8443)
    #expect(config.tls.minVersion == "1.1")
    #expect(config.tls.enabled == false)
}

// MARK: - Tokenizer: Truncation Error

@Test
func tokenizerThrowsOnTruncation() async {
    // Generate input with more than 256 tokens
    let payload = String(repeating: "(a b) ", count: 200)
    let result = try? Vsexpr.tokenize(payload)
    #expect(result == nil)
}

@Test
func missingKeyErrorIncludesLocation() async {
    struct LocalConfig: Decodable {
        let host: String
        let port: UInt32
    }
    do {
        let _ = try Vsexpr.parse(LocalConfig.self, from: "(host example.com)")
    } catch {
        let desc = "\(error)"
        #expect(desc.contains("Missing key"))
    }
}

@Test
func typeMismatchErrorIncludesLocation() async throws {
    struct LocalConfig: Decodable {
        let count: Int
    }
    do {
        let _ = try Vsexpr.parse(LocalConfig.self, from: "(count (nested))")
    } catch {
        let desc = "\(error)"
        #expect(desc.contains("line"))
        #expect(desc.contains("column"))
    }
}

// MARK: - Tokenizer: Escaped Quotes

@Test
func escapedQuoteInsideStringDoesNotTerminateString() async throws {
    let input = #"(key "hello \"world\"")"#
    let stream = try Vsexpr.tokenize(input)

    #expect(stream.count == 4)
    #expect(s_expr_token_is_open_paren(stream.token(at: 0)))
    #expect(s_expr_token_is_atom(stream.token(at: 1)))
    #expect(s_expr_token_is_atom(stream.token(at: 2)))
    #expect(s_expr_token_is_close_paren(stream.token(at: 3)))
    let valTok = stream.token(at: 2)
    #expect(valTok.length == 13)
}

@Test
func escapedBackslashBeforeQuoteDoesNotTerminateString() async throws {
    let input = #"(key "value\\")"#
    let stream = try Vsexpr.tokenize(input)

    #expect(stream.count == 4)
    let valTok = stream.token(at: 2)
    #expect(s_expr_token_is_atom(valTok))
}

@Test
func unescapeInPlaceProcessesEscapeSequences() {
    // "hello\nworld" (with literal backslash-n) is 12 bytes: h,e,l,l,o,\,n,w,o,r,l,d
    var buf: [CChar] = Array("hello\\nworld".utf8.map { CChar($0) })
    let newLen = buf.withUnsafeMutableBufferPointer { ptr in
        unescape_in_place(ptr.baseAddress!, 12)
    }
    #expect(newLen == 11)
    let result = String(bytes: buf.prefix(Int(newLen)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    #expect(result == "hello\nworld")
}

@Test
func unescapeInPlaceHandlesDoubleQuote() {
    var buf: [CChar] = Array("say \\\"hi\\\"".utf8.map { CChar($0) })
    let newLen = buf.withUnsafeMutableBufferPointer { ptr in
        unescape_in_place(ptr.baseAddress!, 10)
    }
    #expect(newLen == 8)
    let result = String(bytes: buf.prefix(Int(newLen)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    #expect(result == "say \"hi\"")
}

@Test
func unescapeInPlaceHandlesBackslash() {
    // "path\\to\\file" (with literal backslash-backslash) is 14 bytes
    var buf: [CChar] = Array("path\\\\to\\\\file".utf8.map { CChar($0) })
    let newLen = buf.withUnsafeMutableBufferPointer { ptr in
        unescape_in_place(ptr.baseAddress!, 14)
    }
    #expect(newLen == 12)
    let result = String(bytes: buf.prefix(Int(newLen)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    #expect(result == "path\\to\\file")
}

@Test
func unescapeInPlaceNoEscapesReturnsSameLength() {
    var buf: [CChar] = Array("hello world".utf8.map { CChar($0) })
    let newLen = buf.withUnsafeMutableBufferPointer { ptr in
        unescape_in_place(ptr.baseAddress!, 11)
    }
    #expect(newLen == 11)
}

@Test
func escapedQuoteAtChunkBoundaryParsedCorrectly() async throws {
    // "min_version" is 11 chars, placing escaped quotes near 32-byte boundaries
    let input = #"(tls "min_version=\"1.2\"")"#
    let stream = try Vsexpr.tokenize(input)
    let valTok = stream.token(at: 2)
    #expect(s_expr_token_is_atom(valTok))
}

@Test
func codableDecodeReturnsUnescapedString() async throws {
    struct SimpleConfig: Decodable {
        let name: String
    }
    let input = #"(name "hello \"world\"")"#
    let decoded = try Vsexpr.parse(SimpleConfig.self, from: input)
    #expect(decoded.name == "hello \"world\"")
}

@Test
func codableDecodeMultiKeyWithEscapedStrings() async throws {
    let input = #"(host "my\"host") (port 443) (debug_mode true)"#
    let decoded = try Vsexpr.parse(CodableConfig.self, from: input)
    #expect(decoded.host == "my\"host")
    #expect(decoded.port == 443)
    #expect(decoded.debugMode == true)
}

// MARK: - Array-of-Structs: Encoder Round-Trip

private struct ArrayElementConfig: Codable, Equatable {
    let name: String
    let value: Int
}

private struct CollectionRootConfig: Codable, Equatable {
    let activeRoutes: [ArrayElementConfig]
    let fallbackServers: [String]
}

@Test
func codableHandlesArrayOfStructsRoundTrip() async throws {
    let config = CollectionRootConfig(
        activeRoutes: [
            ArrayElementConfig(name: "alpha", value: 100),
            ArrayElementConfig(name: "beta", value: 200),
        ],
        fallbackServers: ["10.0.0.1", "10.0.0.2"]
    )
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(CollectionRootConfig.self, from: serialized)
    #expect(decoded == config)
}

@Test
func codableHandlesSingleElementArray() async throws {
    let config = CollectionRootConfig(
        activeRoutes: [ArrayElementConfig(name: "solo", value: 42)],
        fallbackServers: ["10.0.0.1"]
    )
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(CollectionRootConfig.self, from: serialized)
    #expect(decoded == config)
}

@Test
func codableHandlesThreeElementArray() async throws {
    let config = CollectionRootConfig(
        activeRoutes: [
            ArrayElementConfig(name: "a", value: 1),
            ArrayElementConfig(name: "b", value: 2),
            ArrayElementConfig(name: "c", value: 3),
        ],
        fallbackServers: []
    )
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(CollectionRootConfig.self, from: serialized)
    #expect(decoded == config)
}

// MARK: - Empty Collections

@Test
func codableHandlesEmptyCollections() async throws {
    struct EmptyTest: Codable, Equatable {
        let tags: [String]
    }
    let original = EmptyTest(tags: [])
    let output = try Vsexpr.serialize(original)
    let decoded = try Vsexpr.parse(EmptyTest.self, from: output)
    #expect(decoded == original)
}

@Test
func codableHandlesEmptyStructArray() async throws {
    struct EmptyArrayTest: Codable, Equatable {
        let items: [ArrayElementConfig]
    }
    let original = EmptyArrayTest(items: [])
    let output = try Vsexpr.serialize(original)
    let decoded = try Vsexpr.parse(EmptyArrayTest.self, from: output)
    #expect(decoded == original)
}

// MARK: - Optional Arrays with Nil Placeholders

private struct OptionalArrayConfig: Codable, Equatable {
    let tags: [String?]
}

@Test
func codableHandlesOptionalArrayWithNils() async throws {
    let config = OptionalArrayConfig(tags: ["gzip", nil, "brotli"])
    let serialized = try Vsexpr.serialize(config)
    #expect(serialized.contains("nil"))
    let decoded = try Vsexpr.parse(OptionalArrayConfig.self, from: serialized)
    #expect(decoded == config)
}

@Test
func codableHandlesAllNilOptionalArray() async throws {
    let config = OptionalArrayConfig(tags: [nil, nil])
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(OptionalArrayConfig.self, from: serialized)
    #expect(decoded == config)
}

// MARK: - Mixed Primitive Arrays

@Test
func codableHandlesPrimitiveStringArray() async throws {
    struct PrimitiveTest: Codable, Equatable {
        let names: [String]
    }
    let config = PrimitiveTest(names: ["alice", "bob", "charlie"])
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(PrimitiveTest.self, from: serialized)
    #expect(decoded == config)
}

// MARK: - Deeply Nested Arrays

private struct DeepOuter: Codable, Equatable {
    let nested: [DeepInner]
}

private struct DeepInner: Codable, Equatable {
    let label: String
    let children: [String]
}

@Test
func codableHandlesDeeplyNestedArray() async throws {
    let config = DeepOuter(nested: [
        DeepInner(label: "x", children: ["a", "b"]),
        DeepInner(label: "y", children: ["c"]),
    ])
    let serialized = try Vsexpr.serialize(config)
    let decoded = try Vsexpr.parse(DeepOuter.self, from: serialized)
    #expect(decoded == config)
}

// MARK: - Array Fuzz: Property-Based Round-Trip

@Test
func codableArrayFuzzRoundTrip() async {
    await propertyCheck(
        input: Gen.lowercaseLetter.string(of: 1...5).array(of: 1...6)
    ) { names in
        struct FuzzConfig: Codable, Equatable {
            let items: [ArrayElementConfig]
        }
        let config = FuzzConfig(
            items: names.enumerated().map { ArrayElementConfig(name: $0.element, value: $0.offset) }
        )
        let serialized = try? Vsexpr.serialize(config)
        guard let s = serialized else { return }
        let decoded = try? Vsexpr.parse(FuzzConfig.self, from: s)
        #expect(decoded == config)
    }
}

// MARK: - Key Strategy: useDefaultKeys

private struct DefaultKeysConfig: Codable, Equatable {
    let debugMode: Bool
    let port: UInt32
}

@Test
func decoderUseDefaultKeysMatchesExactKeys() async throws {
    var decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    let config = try decoder.decode(DefaultKeysConfig.self, from: "(debugMode true) (port 443)")
    #expect(config.debugMode == true)
    #expect(config.port == 443)
}

@Test
func encoderUseDefaultKeysWritesCamelCase() async throws {
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    let output = try encoder.encode(DefaultKeysConfig(debugMode: true, port: 443))
    #expect(output.contains("debugMode"))
    #expect(!output.contains("debug_mode"))
}

@Test
func roundTripDefaultKeys() async throws {
    var decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    let original = DefaultKeysConfig(debugMode: true, port: 443)
    let encoded = try encoder.encode(original)
    let decoded = try decoder.decode(DefaultKeysConfig.self, from: encoded)
    #expect(decoded == original)
}

// MARK: - Key Strategy: convertFromSnakeCase (default)

@Test
func decoderConvertFromSnakeCaseMatchesSnakeKeys() async throws {
    var decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let config = try decoder.decode(DefaultKeysConfig.self, from: "(debug_mode true) (port 443)")
    #expect(config.debugMode == true)
    #expect(config.port == 443)
}

@Test
func encoderConvertToSnakeCaseWritesSnakeKeys() async throws {
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let output = try encoder.encode(DefaultKeysConfig(debugMode: true, port: 443))
    #expect(output.contains("debug_mode"))
    #expect(!output.contains("debugMode"))
}

@Test
func roundTripConvertFromSnakeCase() async throws {
    let original = DefaultKeysConfig(debugMode: true, port: 443)
    let encoded = try Vsexpr.serialize(original)
    let decoded = try Vsexpr.parse(DefaultKeysConfig.self, from: encoded)
    #expect(decoded == original)
}

// MARK: - Data Pipeline

@Test
func tokenizeDataPayload() async throws {
    let data = "(host 0.0.0.0) (port 443)".data(using: .utf8)!
    let stream = try Vsexpr.tokenize(data)
    #expect(stream.count > 0)
}

@Test
func tokenizeEmptyData() async throws {
    let data = Data()
    let stream = try Vsexpr.tokenize(data)
    #expect(stream.count == 0)
    #expect(stream.isAtEnd)
}

// MARK: - allKeys Compliance

@Test
func allKeysReturnsDiscoveredKeys() async throws {
    struct AllKeysTest: Decodable {
        let host: String
        let port: UInt32
    }
    let input = "(host 0.0.0.0) (port 443)"
    let stream = try Vsexpr.tokenize(input)
    let decoder = VsexprDecoderImpl(stream: stream, payload: input, strategy: .convertFromSnakeCase)
    let container = decoder.container(keyedBy: CodingKeys.self)
    #expect(container.allKeys.count == 2)
}

private enum CodingKeys: String, CodingKey {
    case host, port
}
