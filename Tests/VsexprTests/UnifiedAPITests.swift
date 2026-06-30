import Foundation
import Testing

@testable import Vsexpr

// MARK: - VsexprDecodable via VsexprDecoder

private struct ManualConfig: VsexprDecodable, Equatable {
    let host: String
    let port: UInt32

    init(from stream: inout SExprTokenStream) throws(VsexprError) {
        host = try stream.extractString(for: "host")
        port = try stream.extractUInt32(for: "port")
    }
}

@Test
func decoderDecodeVsexprDecodableWithSnakeStrategy() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let config = try decoder.decode(ManualConfig.self, from: "(host 0.0.0.0) (port 443)")
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
}

@Test
func decoderDecodeVsexprDecodableWithDefaultKeys() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    let config = try decoder.decode(ManualConfig.self, from: "(host 0.0.0.0) (port 443)")
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
}

@Test
func decoderDecodeVsexprDecodableFromData() async throws {
    let decoder = VsexprDecoder()
    let data = "(host 0.0.0.0) (port 443)".data(using: .utf8)!
    let config = try decoder.decode(ManualConfig.self, from: data)
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
}

// MARK: - VsexprEncodable via VsexprEncoder

@Test
func encoderEncodeVsexprEncodableToString() async throws {
    let encoder = VsexprEncoder()
    let config = ManualEncodableConfig(host: "10.0.0.1", port: 8080)
    let output = try encoder.encodeToString(config)
    #expect(output.contains("10.0.0.1"))
    #expect(output.contains("8080"))
}

@Test
func encoderEncodeVsexprEncodableToData() async throws {
    let encoder = VsexprEncoder()
    let config = ManualEncodableConfig(host: "10.0.0.1", port: 8080)
    let data = try encoder.encode(config)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.contains("10.0.0.1"))
    #expect(str.contains("8080"))
}

// MARK: - Shared Strategy

@Test
func unifiedDecoderSharedStrategy() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let manual = try decoder.decode(ManualConfig.self, from: "(host 0.0.0.0) (port 443)")
    #expect(manual.host == "0.0.0.0")

    let codable = try decoder.decode(
        CodableConfig.self, from: "(host 127.0.0.1) (port 8080) (debug_mode true)")
    #expect(codable.host == "127.0.0.1")
    #expect(codable.port == 8080)
}

// MARK: - Strategy-Aware Manual Extraction

@Test
func manualExtractAtomValueStrategyAware() async throws {
    var stream = try Vsexpr.tokenize("(debug_mode true)")
    stream.keyDecodingStrategy = .convertFromSnakeCase
    let value = stream.extractAtomValue(for: "debugMode")
    #expect(value == "true")
}

@Test
func manualExtractGroupStrategyAware() async throws {
    var stream = try Vsexpr.tokenize("(tls (min_version 1.2) (enabled true))")
    stream.keyDecodingStrategy = .convertFromSnakeCase
    var group = stream.extractGroup(for: "tls")
    #expect(group != nil)
    let minVersion = group?.extractAtomValue(for: "minVersion")
    #expect(minVersion == "1.2")
}

// MARK: - Convenience Routing

@Test
func vsexprParseConvenienceRoutesThroughDecoder() async throws {
    let config = try Vsexpr.parse(
        CodableConfig.self, from: "(host example.com) (port 80) (debugMode false)")
    #expect(config.host == "example.com")
    #expect(config.port == 80)
    #expect(config.debugMode == false)
}

@Test
func vsexprSerializeVsexprEncodableConvenience() async throws {
    let config = ManualEncodableConfig(host: "example.com", port: 443)
    let output = try Vsexpr.serialize(config)
    #expect(output.contains("example.com"))
    #expect(output.contains("443"))
}
