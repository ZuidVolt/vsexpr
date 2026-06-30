import Foundation
import Testing

@testable import Vsexpr

// MARK: - Balanced Parentheses: Frame Tracker

@Test
func frameTrackerSingleExpression() throws {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    let input = "(node_id \"server-1\")"
    var count = 0
    for byte in input.utf8 {
        count += 1
        let done = try tracker.feed(byte, bufferCount: count)
        if done { return }
    }
    Issue.record("Frame not detected")
}

@Test
func frameTrackerMultipleExpressions() throws {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    let input = "(a 1) (b 2) (c 3)"
    var frames = 0
    var count = 0
    for byte in input.utf8 {
        count += 1
        if try tracker.feed(byte, bufferCount: count) {
            frames += 1
        }
    }
    #expect(frames == 3)
}

@Test
func frameTrackerStringWithParens() throws {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    let input = #"(name "foo (bar) baz")"#
    var count = 0
    for byte in input.utf8 {
        count += 1
        let done = try tracker.feed(byte, bufferCount: count)
        if done { return }
    }
    Issue.record("Frame not detected — string parens confused tracker")
}

@Test
func frameTrackerEscapedQuotes() throws {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    let input = #"(msg "she said \"hi\"")"#
    var count = 0
    for byte in input.utf8 {
        count += 1
        let done = try tracker.feed(byte, bufferCount: count)
        if done { return }
    }
    Issue.record("Frame not detected — escaped quotes confused tracker")
}

@Test
func frameTrackerNestingDepthExceeded() {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    let input = "(" + String(repeating: "(", count: 64) + "a" + String(repeating: ")", count: 64) + ")"
    #expect(throws: (any Error).self) {
        var count = 0
        for byte in input.utf8 {
            count += 1
            _ = try tracker.feed(byte, bufferCount: count)
        }
    }
}

@Test
func frameTrackerUnexpectedCloseParen() {
    var tracker = VsexprFrameTracker(strategy: .balancedParentheses)
    #expect(throws: VsexprError.self) {
        _ = try tracker.feed(0x29, bufferCount: 1)
    }
}

// MARK: - Balanced Parentheses: Integration

@Test
func streamingSingleFrame() async throws {
    let input = "((host example.com) (port 80) (debugMode false))"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var results: [CodableConfig] = []
    for try await value in seq { results.append(value) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
    #expect(results[0].port == 80)
}

@Test
func streamingMultipleFrames() async throws {
    let input =
        "((host a.com) (port 1) (debugMode true))"
        + "((host b.com) (port 2) (debugMode false))"
        + "((host c.com) (port 3) (debugMode true))"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var results: [CodableConfig] = []
    for try await value in seq { results.append(value) }
    #expect(results.count == 3)
    #expect(results[0].host == "a.com")
    #expect(results[1].host == "b.com")
    #expect(results[2].host == "c.com")
}

@Test
func streamingNestedStruct() async throws {
    // swiftlint:disable:next GroupNumericLiterals
    let input = "((nodeId server-1) (metrics (cpuUtilization 85.2) (memoryUsedBytes 12345678)))"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        NodeMetrics.self, from: DataBytes(data), strategy: .balancedParentheses)
    for try await metric in seq {
        #expect(metric.nodeId == "server-1")
        #expect(metric.metrics.cpuUtilization == 85.2)
        #expect(metric.metrics.memoryUsedBytes == 12_345_678)
    }
}

@Test
func streamingEmptyStream() async throws {
    let data = Data()
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var count = 0
    for try await _ in seq { count += 1 }
    #expect(count == 0)
}

@Test
func streamingSnakeStrategy() async throws {
    let input = "((node_id server-1))((node_id server-2))"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let seq = decoder.decodeStream(
        SnakeTestConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var results: [SnakeTestConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 2)
    #expect(results[0].nodeId == "server-1")
    #expect(results[1].nodeId == "server-2")
}

@Test
func streamingPartialFrameAtEOF() async throws {
    let input = "((host example.com) (port 80) (debugMode true))"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
}

@Test
func streamingParseConvenience() async throws {
    let input = "((host example.com) (port 80) (debugMode false))"
    let data = Data(input.utf8)
    let seq = Vsexpr.parseStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
}

// MARK: - Line-Delimited Framing: Tracker

@Test
func frameTrackerLineDelimitedSingle() throws {
    var tracker = VsexprFrameTracker(strategy: .lineDelimited)
    let input = "hello world\n"
    var count = 0
    for byte in input.utf8 {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { return }
    }
    Issue.record("Frame not detected")
}

@Test
func frameTrackerLineDelimitedMultiple() throws {
    var tracker = VsexprFrameTracker(strategy: .lineDelimited)
    let input = "a\nb\nc\n"
    var frames = 0
    var count = 0
    for byte in input.utf8 {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { frames += 1 }
    }
    #expect(frames == 3)
}

@Test
func frameTrackerLineDelimitedCRLF() throws {
    var tracker = VsexprFrameTracker(strategy: .lineDelimited)
    let input = "a\r\nb\r\n"
    var frames = 0
    var count = 0
    for byte in input.utf8 {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { frames += 1 }
    }
    #expect(frames == 2)
}

@Test
func frameTrackerLineDelimitedEmptyLines() throws {
    var tracker = VsexprFrameTracker(strategy: .lineDelimited)
    let input = "\n\na\n\n"
    var frames = 0
    var count = 0
    for byte in input.utf8 {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { frames += 1 }
    }
    #expect(frames == 1)
}

@Test
func frameTrackerLineDelimitedNoTrailingNewline() throws {
    var tracker = VsexprFrameTracker(strategy: .lineDelimited)
    let input = "hello"
    var count = 0
    for byte in input.utf8 {
        count += 1
        _ = try tracker.feed(byte, bufferCount: count)
    }
    #expect(tracker.hasPartialData)
}

// MARK: - Line-Delimited Integration

@Test
func streamingLineDelimitedSingle() async throws {
    let input = "(host example.com) (port 80) (debugMode false)\n"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
}

@Test
func streamingLineDelimitedMultiple() async throws {
    let input =
        "(host a.com) (port 1) (debugMode true)\n"
        + "(host b.com) (port 2) (debugMode false)\n"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 2)
    #expect(results[0].host == "a.com")
    #expect(results[1].host == "b.com")
}

@Test
func streamingLineDelimitedNoTrailingNewline() async throws {
    let input = "(host example.com) (port 80) (debugMode false)"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
}

// MARK: - Length-Prefixed Framing: Tracker

@Test
func frameTrackerLengthPrefixedUint16() throws {
    var tracker = VsexprFrameTracker(strategy: .lengthPrefixed(headerSize: .uint16BigEndian))
    let input: [UInt8] = [0x00, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
    var frames = 0
    var count = 0
    for byte in input {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { frames += 1 }
    }
    #expect(frames == 1)
}

@Test
func frameTrackerLengthPrefixedUint32() throws {
    var tracker = VsexprFrameTracker(strategy: .lengthPrefixed(headerSize: .uint32BigEndian))
    let input: [UInt8] = [0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63]
    var frames = 0
    var count = 0
    for byte in input {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { frames += 1 }
    }
    #expect(frames == 1)
}

@Test
func frameTrackerLengthPrefixedZeroLength() throws {
    var tracker = VsexprFrameTracker(strategy: .lengthPrefixed(headerSize: .uint16BigEndian))
    let input: [UInt8] = [0x00, 0x00]
    var count = 0
    for byte in input {
        count += 1
        if try tracker.feed(byte, bufferCount: count) { return }
    }
    Issue.record("Zero-length frame not detected")
}

// MARK: - Length-Prefixed Integration

@Test
func streamingLengthPrefixedUint16() async throws {
    let expr1 = "(host a.com) (port 1) (debugMode true)"
    let expr2 = "(host b.com) (port 2) (debugMode false)"
    let utf8First = Array(expr1.utf8)
    let utf8Second = Array(expr2.utf8)
    var data = Data()
    data.append(contentsOf: [UInt8(utf8First.count >> 8), UInt8(utf8First.count & 0xFF)])
    data.append(contentsOf: utf8First)
    data.append(contentsOf: [UInt8(utf8Second.count >> 8), UInt8(utf8Second.count & 0xFF)])
    data.append(contentsOf: utf8Second)

    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data),
        strategy: .lengthPrefixed(headerSize: .uint16BigEndian))
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 2)
    #expect(results[0].host == "a.com")
    #expect(results[1].host == "b.com")
}

@Test
func streamingLengthPrefixedUint32() async throws {
    let expr = "(host example.com) (port 443) (debugMode true)"
    let utf8 = Array(expr.utf8)
    var data = Data()
    data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(utf8.count)])
    data.append(contentsOf: utf8)

    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data),
        strategy: .lengthPrefixed(headerSize: .uint32BigEndian))
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
    #expect(results[0].port == 443)
}

// MARK: - EOF / Truncation

@Test
func streamingBalancedEOFTruncation() async throws {
    let input = "(host example.com"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    do {
        for try await _ in seq {}
        Issue.record("Expected error for unterminated expression")
    } catch is VsexprError {
        // Expected
    }
}

@Test
func streamingLengthPrefixedEOFTruncation() async throws {
    let input: [UInt8] = [0x00, 0x0A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
    let data = Data(input)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data),
        strategy: .lengthPrefixed(headerSize: .uint16BigEndian))
    do {
        for try await _ in seq {}
        Issue.record("Expected error for truncated length-prefixed frame")
    } catch is VsexprError {
        // Expected
    }
}

// MARK: - Strategy Convenience

@Test
func streamingParseStreamWithStrategy() async throws {
    let input = "(host example.com) (port 80) (debugMode false)\n"
    let data = Data(input.utf8)
    let seq = Vsexpr.parseStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    var results: [CodableConfig] = []
    for try await v in seq { results.append(v) }
    #expect(results.count == 1)
    #expect(results[0].host == "example.com")
}
