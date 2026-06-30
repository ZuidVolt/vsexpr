import PropertyBased
import Testing
import VsexprLib

@testable import Vsexpr

// MARK: - Structural Tokens

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

// MARK: - Atoms

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

// MARK: - Strings

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

// MARK: - Truncation Error

@Test
func tokenizerThrowsOnTruncation() async {
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

// MARK: - Escaped Quotes

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
    let input = #"(host "my\"host") (port 443) (debugMode true)"#
    let decoded = try Vsexpr.parse(CodableConfig.self, from: input)
    #expect(decoded.host == "my\"host")
    #expect(decoded.port == 443)
    #expect(decoded.debugMode == true)
}
