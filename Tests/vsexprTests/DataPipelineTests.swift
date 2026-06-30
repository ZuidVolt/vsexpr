import Foundation
import Testing

@testable import vsexpr

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
