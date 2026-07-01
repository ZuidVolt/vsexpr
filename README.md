# Vsexpr

A high-performance S-expression parser built on Clang SIMD vector extensions with a Swift 6.0+ wrapper using seamless C++ interoperability.

[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-orange.svg?style=flat)](https://github.com/apple/swift-package-manager)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-blue.svg?style=flat)](https://swift.org)
[![LICENSE](https://img.shields.io/badge/license-MIT-green.svg?style=flat)](LICENSE)

## Features

- **SIMD-Accelerated Tokenizer:** Leverages Clang vector extensions (`vector_size`) to scan 32-byte chunks in a single pass using ARM NEON or x86 AVX2 instructions.
- **Zero-Reflection Path:** Use `VsexprDecodable` and `VsexprEncodable` to bypass runtime reflection entirely for maximum decoding and encoding throughput.
- **Unified Codable Support:** Native `VsexprDecoder` and `VsexprEncoder` support Swift `Codable` with automatic `snake_case` key translation.
- **High-Throughput Streaming:** `AsyncSequence` and `AsyncBytes` integration with customizable framing strategies (`balancedParentheses`, `lineDelimited`, `netstring`, `lengthPrefixed`, `nullDelimited`).

---

## Installation

### Swift Package Manager

Add `Vsexpr` as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ZuidVolt/vsexpr.git", from: "1.0.0")
]
```

Then add the product target dependency to your targets:

```swift
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "Vsexpr", package: "vsexpr")
        ]
    )
]
```

---

## Usage

`Vsexpr` provides three distinct groups of serialization and parsing APIs to balance convenience and raw throughput.

### 1. `Codable` Types (Reflection-Based)
Use compiler-synthesized `Codable` conformance for automatic mapping. Property names are automatically converted between camelCase (Swift) and snake_case (S-expression).

```swift
import Foundation
import Vsexpr

struct Config: Codable {
    var host: String
    var port: UInt32
    var debugMode: Bool
}

let payload = "(host \"0.0.0.0\") (port 443) (debug_mode true)"

// Decoding
let config = try Vsexpr.parse(Config.self, from: payload)
print(config.host) // -> "0.0.0.0"
print(config.port) // -> 443

// Encoding
let serialized = try Vsexpr.serialize(config)
print(serialized) // -> (host "0.0.0.0") (port 443) (debug_mode true)
```

---

### 2. `VsexprDecodable` & `VsexprEncodable` (Zero-Reflection)
For maximum throughput and low-latency environments, conform your types to `VsexprDecodable` and `VsexprEncodable`. These use manual combinators on the token stream, avoiding any runtime reflection overhead.

```swift
import Vsexpr

struct ManualConfig: VsexprDecodable, VsexprEncodable {
    var host: String
    var port: UInt32
    var debugMode: Bool

    // Zero-Reflection Decoding
    init(from stream: inout SExprTokenStream) throws(VsexprError) {
        self.host = try stream.extractString(for: "host")
        self.port = try stream.extractUInt32(for: "port")
        self.debugMode = try stream.extractBool(for: "debugMode")
    }

    // Zero-Reflection Encoding
    func encode(to string: inout String, strategy: VsexprEncoder.KeyEncodingStrategy) throws(VsexprError) {
        let hostKey = strategy.transform("host")
        let portKey = strategy.transform("port")
        let debugKey = strategy.transform("debugMode")

        string += "(\(hostKey) \"\(host)\") "
        string += "(\(portKey) \(port)) "
        string += "(\(debugKey) \(debugMode))"
    }
}

let payload = "(host \"127.0.0.1\") (port 8080) (debug_mode false)"

// Parse from string payload
let config = try Vsexpr.parse(ManualConfig.self, from: payload)

// Serialize back to S-expression
let serialized = try Vsexpr.serialize(config)
```

---

### 3. Progressive Streaming & Framing
For large files, IPC pipes, or socket streams, use asynchronous streaming. `Vsexpr` handles incoming chunks progressively and parses complete frames using one of the predefined framing strategies:

- `.balancedParentheses`: Scans and slices complete, balanced parenthesized S-expressions.
- `.lineDelimited`: Splits incoming bytes by line boundaries.
- `.netstring`: Decodes length-prefixed netstrings (`[len]:[payload],`).
- `.lengthPrefixed`: Decodes binary payloads prefixed with a `UInt16` or `UInt32` byte length.
- `.nullDelimited`: Splits payloads by null bytes.

```swift
import Foundation
import Vsexpr

func handleSocketStream(bytes: URLSession.AsyncBytes) async throws {
    // Parse objects on-the-fly as they arrive on the socket
    let stream = Vsexpr.parseStream(Config.self, from: bytes, strategy: .balancedParentheses)
    
    for try await config in stream {
        print("Received configuration update: \(config.host):\(config.port)")
    }
}
```

---

### 4. Low-Level Tokenization
If you need to implement custom compiler frontends or custom AST parsers, you can access the SIMD-accelerated token sequence directly:

```swift
import Vsexpr

let payload = "(host \"0.0.0.0\")"
var tokenStream = try Vsexpr.tokenize(payload)

while let token = tokenStream.peek() {
    print("Token type: \(token.type), Value: \(tokenStream.tokenText(token))")
    tokenStream.advance()
}
```

---

## Architecture

`Vsexpr` is built in two layers:
1. **`VsexprLib` (C++23 Engine):** A single-header S-expression tokenizing engine designed without exceptions or OOP structures. It uses raw 32-byte SIMD vector scans to extract tokens at high speeds, falling back to a scalar pass for tail chunks.
2. **`Vsexpr` (Swift 6 Wrapper):** Leverages Swift-C++ Interoperability to bridge C++ tokenizer structs directly to `SExprTokenStream` and exports high-level Swift APIs with full `Sendable` guarantees.

## License

`Vsexpr` is released under the MIT license. See [LICENSE](LICENSE) for details.
