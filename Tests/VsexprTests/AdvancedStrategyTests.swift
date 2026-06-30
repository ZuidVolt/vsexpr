import Foundation
import Testing

@testable import Vsexpr

@Suite("Advanced Strategies Tests")
struct AdvancedStrategyTests {
    // MARK: - Kebab Case Tests

    struct KebabConfig: Codable, Equatable {
        let debugMode: Bool
        let apiToken: String
        let maxRetries: Int
    }

    @Test
    func testKebabCaseDecoding() throws {
        let input = "(debug-mode true) (api-token \"abcdef\") (max-retries 3)"
        let decoder = VsexprDecoder()
        decoder.keyDecodingStrategy = .convertFromKebabCase
        let config = try decoder.decode(KebabConfig.self, from: input)
        #expect(config.debugMode == true)
        #expect(config.apiToken == "abcdef")
        #expect(config.maxRetries == 3)
    }

    @Test
    func testKebabCaseEncoding() throws {
        let config = KebabConfig(debugMode: false, apiToken: "123", maxRetries: 5)
        let encoder = VsexprEncoder()
        encoder.keyEncodingStrategy = .convertToKebabCase
        let output = try encoder.encodeToString(config)
        #expect(output.contains("(debug-mode false)"))
        #expect(output.contains("(api-token 123)"))
        #expect(output.contains("(max-retries 5)"))
    }

    // MARK: - Custom Key Strategies

    @Test
    func testCustomKeyDecoding() throws {
        let input = "(DEBUG_MODE true) (TOKEN \"xyz\")"
        let decoder = VsexprDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let lastKey = path.last!.stringValue
            if lastKey == "DEBUG_MODE" {
                return AnyCodingKey(stringValue: "debugMode")
            }
            if lastKey == "TOKEN" {
                return AnyCodingKey(stringValue: "apiToken")
            }
            return AnyCodingKey(stringValue: lastKey)
        }

        struct CustomConfig: Decodable {
            let debugMode: Bool
            let apiToken: String
        }

        let config = try decoder.decode(CustomConfig.self, from: input)
        #expect(config.debugMode == true)
        #expect(config.apiToken == "xyz")
    }

    @Test
    func testCustomKeyEncoding() throws {
        struct CustomConfig: Encodable {
            let debugMode: Bool
            let apiToken: String
        }
        let config = CustomConfig(debugMode: true, apiToken: "xyz")
        let encoder = VsexprEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            let lastKey = path.last!.stringValue
            if lastKey == "debugMode" {
                return AnyCodingKey(stringValue: "DEBUG_MODE")
            }
            if lastKey == "apiToken" {
                return AnyCodingKey(stringValue: "TOKEN")
            }
            return AnyCodingKey(stringValue: lastKey)
        }
        let output = try encoder.encodeToString(config)
        #expect(output.contains("(DEBUG_MODE true)"))
        #expect(output.contains("(TOKEN xyz)"))
    }

    // MARK: - Null Delimited Streaming

    @Test
    func testNullDelimitedStreaming() async throws {
        let item1 = "(host a.com) (port 1)\u{00}"
        let item2 = "(host b.com) (port 2)\u{00}"
        let data = Data((item1 + item2).utf8)

        struct SimpleConfig: Decodable {
            let host: String
            let port: Int
        }

        let seq = Vsexpr.parseStream(SimpleConfig.self, from: DataBytes(data), strategy: .nullDelimited)
        var results: [SimpleConfig] = []
        for try await v in seq {
            results.append(v)
        }
        #expect(results.count == 2)
        #expect(results[0].host == "a.com")
        #expect(results[1].host == "b.com")
    }

    // MARK: - Netstring Streaming

    @Test
    func testNetstringStreaming() async throws {
        let payload1 = "(host a.com) (port 10)"
        let payload2 = "(host b.com) (port 20)"

        let frame1 = "\(payload1.utf8.count):\(payload1),"
        let frame2 = "\(payload2.utf8.count):\(payload2),"
        let data = Data((frame1 + frame2).utf8)

        struct SimpleConfig: Decodable {
            let host: String
            let port: Int
        }

        let seq = Vsexpr.parseStream(SimpleConfig.self, from: DataBytes(data), strategy: .netstring)
        var results: [SimpleConfig] = []
        for try await v in seq {
            results.append(v)
        }
        #expect(results.count == 2)
        #expect(results[0].host == "a.com")
        #expect(results[0].port == 10)
        #expect(results[1].host == "b.com")
        #expect(results[1].port == 20)
    }

    @Test
    func testNetstringValidationErrors() async throws {
        // Leading zero length is invalid in DJB netstrings unless it's exactly "0:,"
        let invalidLeadingZero = "05:hello,"
        let data1 = Data(invalidLeadingZero.utf8)
        let seq1 = Vsexpr.parseStream(String.self, from: DataBytes(data1), strategy: .netstring)
        do {
            for try await _ in seq1 {}
            Issue.record("Expected leading zero error")
        } catch {
            // Expected
        }

        // Missing trailing comma
        let missingComma = "5:helloX"
        let data2 = Data(missingComma.utf8)
        let seq2 = Vsexpr.parseStream(String.self, from: DataBytes(data2), strategy: .netstring)
        do {
            for try await _ in seq2 {}
            Issue.record("Expected missing comma error")
        } catch {
            // Expected
        }
    }

    // MARK: - Custom Closure Framing

    @Test
    func testCustomFraming() async throws {
        let payload = "(host custom.com)$(host another.com)$"
        let data = Data(payload.utf8)

        struct SimpleConfig: Decodable {
            let host: String
        }

        final class Box: @unchecked Sendable {
            var hasContent = false
        }
        let box = Box()
        let customStrategy = VsexprFramingStrategy.custom { byte, count in
            if byte == 0x24 {  // '$'
                let complete = box.hasContent
                box.hasContent = false
                return complete
            }
            box.hasContent = true
            return false
        }

        let seq = Vsexpr.parseStream(SimpleConfig.self, from: DataBytes(data), strategy: customStrategy)
        var results: [SimpleConfig] = []
        for try await v in seq {
            results.append(v)
        }
        #expect(results.count == 2)
        #expect(results[0].host == "custom.com")
        #expect(results[1].host == "another.com")
    }
}
