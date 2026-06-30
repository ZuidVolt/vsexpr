import Testing

@testable import vsexpr

// MARK: - useDefaultKeys

private struct DefaultKeysConfig: Codable, Equatable {
    let debugMode: Bool
    let port: UInt32
}

@Test
func decoderUseDefaultKeysMatchesExactKeys() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    let config = try decoder.decode(DefaultKeysConfig.self, from: "(debugMode true) (port 443)")
    #expect(config.debugMode == true)
    #expect(config.port == 443)
}

@Test
func encoderUseDefaultKeysWritesCamelCase() async throws {
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    let output = try encoder.encodeToString(DefaultKeysConfig(debugMode: true, port: 443))
    #expect(output.contains("debugMode"))
    #expect(!output.contains("debug_mode"))
}

@Test
func roundTripDefaultKeys() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    let original = DefaultKeysConfig(debugMode: true, port: 443)
    let encoded = try encoder.encodeToString(original)
    let decoded = try decoder.decode(DefaultKeysConfig.self, from: encoded)
    #expect(decoded == original)
}

// MARK: - convertFromSnakeCase (default)

@Test
func decoderConvertFromSnakeCaseMatchesSnakeKeys() async throws {
    let decoder = VsexprDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let config = try decoder.decode(DefaultKeysConfig.self, from: "(debug_mode true) (port 443)")
    #expect(config.debugMode == true)
    #expect(config.port == 443)
}

@Test
func encoderConvertToSnakeCaseWritesSnakeKeys() async throws {
    let encoder = VsexprEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let output = try encoder.encodeToString(DefaultKeysConfig(debugMode: true, port: 443))
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
