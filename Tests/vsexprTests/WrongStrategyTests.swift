import Foundation
import Testing

@testable import vsexpr

// MARK: - Wrong Strategy Failure Mode Tests

/// lineDelimited on flat S-expr that contains ALL required keys.
/// No newlines means one frame at EOF. Decoder sees all keys → success.
@Test
func wrongStrategyFlatInputLineDelimited() async throws {
    let input = "(host example.com) (port 80) (debug_mode false)"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    var count = 0
    for try await _ in seq { count += 1 }
    #expect(count == 1)
}

/// balancedParentheses on newline-delimited data where each line contains
/// an incomplete set of keys.
/// Each "(key value)" is a separate frame → decode fails with wrapped error.
@Test
func wrongStrategyNewlineDelimitedBalanced() async throws {
    let input =
        "(host a.com) (port 1) (debug_mode true)\n"
        + "(host b.com) (port 2) (debug_mode false)\n"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    do {
        for try await _ in seq {}
        Issue.record("Expected error")
    } catch let error as VsexprError {
        let desc = "\(error)"
        #expect(desc.contains("Framing error"))
        #expect(desc.contains("balancedParentheses"))
        #expect(desc.contains("(host a.com)") || desc.contains("(host b.com)"))
    }
}

/// lengthPrefixed header followed by payload, decoded with lineDelimited.
/// The header bytes become part of the expression. May succeed or fail
/// depending on whether the tokenizer can make sense of the header bytes.
@Test
func wrongStrategyLengthPrefixedLineDelimited() async throws {
    let expr = "(host example.com) (port 443) (debug_mode true)"
    let utf8 = Array(expr.utf8)
    var data = Data()
    data.append(contentsOf: [0x00, UInt8(utf8.count)])
    data.append(contentsOf: utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .lineDelimited)
    do {
        for try await _ in seq {}
    } catch let error as VsexprError {
        let desc = "\(error)"
        #expect(desc.contains("Framing error"))
    }
}

/// Empty stream — no error regardless of strategy.
@Test
func wrongStrategyEmptyStream() async throws {
    let data = Data()
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    var count = 0
    for try await _ in seq { count += 1 }
    #expect(count == 0)
}

/// Flat atoms without parens using balancedParentheses.
/// parenDepth never > 0, so tracker never emits a frame.
/// Post-EOF: frameCount is 0, so framingMismatchError() is thrown.
@Test
func wrongStrategyFlatAtomsBalanced() async throws {
    let input = "host example.com port 80 debug_mode false"
    let data = Data(input.utf8)
    let decoder = VsexprDecoder()
    let seq = decoder.decodeStream(
        CodableConfig.self, from: DataBytes(data), strategy: .balancedParentheses)
    do {
        for try await _ in seq {}
        Issue.record("Expected framing error")
    } catch let error as VsexprError {
        let desc = "\(error)"
        #expect(desc.contains("Framing error"))
        #expect(desc.contains("produced no frames"))
        #expect(desc.contains("balancedParentheses"))
    }
}
