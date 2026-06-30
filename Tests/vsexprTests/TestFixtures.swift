import Foundation
import PropertyBased
import Testing

@testable import vsexpr

internal let validAtomChar = Gen.oneOf(
    Gen.lowercaseLetter,
    Gen.uppercaseLetter,
    Gen.number,
    Gen.always(Character(".")),
    Gen.always(Character("-")),
    Gen.always(Character("_")),
    Gen.always(Character(":")),
    Gen.always(Character("/")),
)

internal struct CodableConfig: Decodable {
    let host: String
    let port: UInt32
    let debugMode: Bool
}

internal struct ManualEncodableConfig: VsexprEncodable, Equatable {
    let host: String
    let port: UInt32

    func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) throws(VsexprError) {
        string.append("(host ")
        host.encode(to: &string, strategy: strategy)
        string.append(") (port ")
        port.encode(to: &string, strategy: strategy)
        string.append(")")
    }
}

internal struct SnakeTestConfig: Decodable {
    let nodeId: String
}

internal struct NodeMetrics: Decodable {
    let nodeId: String
    let metrics: Metrics

    struct Metrics: Decodable {
        let cpuUtilization: Double
        let memoryUsedBytes: Int
    }
}

internal struct DataBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    private let data: Data

    init(_ data: Data) { self.data = data }

    func makeAsyncIterator() -> DataBytesIterator {
        DataBytesIterator(data: data)
    }
}

internal struct DataBytesIterator: AsyncIteratorProtocol, Sendable {
    let data: Data
    private var index: Data.Index

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func next() async throws -> UInt8? {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        data.formIndex(after: &index)
        return byte
    }
}
