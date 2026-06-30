import Foundation
import PropertyBased
import Testing

@testable import vsexpr

// MARK: - Out-of-Order Keys

@Test
func codableDecodesKeysInAnyOrder() async throws {
    let input = "(port 443) (host 0.0.0.0) (debugMode true)"
    let config = try Vsexpr.parse(CodableConfig.self, from: input)
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
    #expect(config.debugMode == true)
}

@Test
func codableDecodesReverseOrder() async throws {
    let input = "(debugMode false) (port 9090) (host 10.0.0.1)"
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

// MARK: - Nested Struct Decoding

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
    let input = "(host 0.0.0.0) (port 443) (tls (minVersion 1.2) (enabled true))"
    let config = try Vsexpr.parse(NestedConfig.self, from: input)
    #expect(config.host == "0.0.0.0")
    #expect(config.port == 443)
    #expect(config.tls.minVersion == "1.2")
    #expect(config.tls.enabled == true)
}

@Test
func codableDecodesNestedStructReverseOrder() async throws {
    let input = "(tls (enabled false) (minVersion 1.1)) (port 8443) (host 127.0.0.1)"
    let config = try Vsexpr.parse(NestedConfig.self, from: input)
    #expect(config.host == "127.0.0.1")
    #expect(config.port == 8443)
    #expect(config.tls.minVersion == "1.1")
    #expect(config.tls.enabled == false)
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
