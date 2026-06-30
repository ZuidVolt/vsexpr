# ``vsexpr``

A high-performance S-expression parser built on Clang SIMD vector extensions with a Swift 6 wrappers using seamless C++ interoperability.

## Overview

`vsexpr` is designed for ultra-high throughput and allocation-invariant serialization of S-expression data. It targets low-latency networking, config ingestion, and pipeline utility tools in Swift.

The library provides two distinct paradigms for parsing S-expressions:

1. **Codable (Reflection-Based):** Uses compiler-synthesized `Decodable` conformances to automatically map S-expression keys into Swift types, supporting advanced strategies like snake_case, kebab-case, or custom converters.
2. **VsexprDecodable (Zero-Reflection):** A custom manual extraction protocol that avoids runtime reflection, string copies, and intermediate dictionaries, achieving maximum throughput.

## Usage

### 1. Unified Parser API

Use the `Vsexpr` struct to parse standard Swift types directly from string payloads:

```swift
import vsexpr

struct Config: Codable {
    let debugMode: Bool
    let apiToken: String
}

let payload = "(debug_mode true) (api_token \"abcdef\")"
let config = try Vsexpr.parse(Config.self, from: payload)
```

### 2. Streaming Deserialization

For network socket buffers or large logs, use `VsexprAsyncSequence` to progressive stream instances over an async byte sequence:

```swift
let sequence = Vsexpr.parseStream(
    Config.self, 
    from: networkStream, 
    strategy: .netstring
)

for try await item in sequence {
    // Process progressively framed items
}
```

## Topics

### Core Operations

- ``Vsexpr``
- ``VsexprDecoder``
- ``VsexprEncoder``

### Streaming Integration

- ``VsexprAsyncSequence``
- ``VsexprFramingStrategy``

### Custom Parsing Protocols

- ``VsexprDecodable``
- ``VsexprEncodable``
- ``SExprTokenStream``
- ``VsexprError``
