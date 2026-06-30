import Testing
import vsexprLib

@testable import vsexpr

// MARK: - Manual Conformance Path

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

// MARK: - Out-of-Order Keys

@Test
func decodableExtractsKeysInAnyOrder() async {
    let config = try? Vsexpr.parse(TestConfig.self, from: "(port 8080) (host example.com)")
    #expect(config != nil)
    #expect(config?.host == "example.com")
    #expect(config?.port == 8080)
}
