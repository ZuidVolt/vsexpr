public import Foundation
import vsexprLib

/// The primary namespace for the vsexpr S-expression parsing library.
///
/// `Vsexpr` provides a unified entry point for tokenizing, parsing, and serializing
/// S-expressions. It bridges two serialization paradigms:
///
/// - **Codable (Runtime Reflection):** Uses `Decodable`/`Encodable` for automatic
///   key mapping and type conversion via Swift's reflection infrastructure.
/// - **VsexprDecodable/VsexprEncodable (Zero-Reflection):** Uses manual combinator
///   APIs for maximum throughput with no runtime reflection overhead.
///
/// Both paths share the same SIMD-accelerated tokenizer and are configured through
/// a single `VsexprDecoder` or `VsexprEncoder` instance.
///
/// ### Example
///
/// ```swift
/// // Codable path
/// let config = try Vsexpr.parse(MyConfig.self, from: "(host 0.0.0.0) (port 443)")
///
/// // Zero-reflection path
/// let config = try Vsexpr.parse(MyManualConfig.self, from: "(host 0.0.0.0) (port 443)")
///
/// // Tokenization only
/// let stream = try Vsexpr.tokenize("(host 0.0.0.0) (port 443)")
/// ```
public enum Vsexpr {

    /// Tokenizes an S-expression string into a stream of structured tokens.
    ///
    /// This is the primary entry point for the SIMD-accelerated tokenizer. The returned
    /// `SExprTokenStream` can be used directly with `VsexprDecodable` types, or passed
    /// to `VsexprDecoder` for Codable-based parsing.
    ///
    /// - Parameter payload: A string containing one or more S-expression pairs, such as
    ///   `"(host 0.0.0.0) (port 443)"`. The string is copied into a heap-allocated buffer
    ///   for the duration of the stream's lifetime.
    /// - Returns: A token stream positioned at the beginning of the token sequence.
    /// - Throws: `VsexprError.tokenLimitExceeded` if the input contains more than 256 tokens.
    ///
    /// - Note: The tokenizer processes input in 32-byte SIMD chunks. Trailing atoms that
    ///   span chunk boundaries are handled by a scalar tail pass.
    public static func tokenize(_ payload: String) throws(VsexprError) -> SExprTokenStream {
        let storage = TokenStorage(payload: payload)
        guard !storage.result.truncated else {
            throw .tokenLimitExceeded
        }
        return SExprTokenStream(
            startOffset: 0,
            count: Int(storage.result.count),
            storage: storage,
            truncated: false
        )
    }

    /// Tokenizes raw binary data into a stream of structured tokens.
    ///
    /// This overload accepts `Data` directly, bypassing UTF-8 validation and intermediate
    /// `String` allocation. Use this when parsing payloads from network sockets, memory-mapped
    /// files, or other binary sources.
    ///
    /// - Parameter data: Raw bytes containing an S-expression. The data is copied into a
    ///   heap-allocated buffer; no reference to the original `Data` is retained.
    /// - Returns: A token stream positioned at the beginning of the token sequence.
    /// - Throws: `VsexprError.tokenLimitExceeded` if the input contains more than 256 tokens.
    ///
    /// - Note: If `data` is empty, an empty token stream is returned without error.
    public static func tokenize(_ data: Data) throws(VsexprError) -> SExprTokenStream {
        var capturedError: VsexprError?
        var result: SExprTokenStream!
        data.withUnsafeBytes { rawBuffer in
            guard !rawBuffer.isEmpty else {
                result = SExprTokenStream(
                    startOffset: 0, count: 0,
                    storage: TokenStorage(payload: "")
                )
                return
            }
            let storage = TokenStorage(rawBytes: rawBuffer)
            guard !storage.result.truncated else {
                capturedError = .tokenLimitExceeded
                return
            }
            result = SExprTokenStream(
                startOffset: 0,
                count: Int(storage.result.count),
                storage: storage,
                truncated: false
            )
        }
        if let error = capturedError { throw error }
        return result
    }

    /// Tokenizes an raw buffer pointer into a stream of structured tokens.
    ///
    /// This is the lowest-level tokenization entry point, accepting an
    /// `UnsafeRawBufferPointer` directly. Use this when integrating with C APIs,
    /// memory-mapped regions, or custom allocators where copying into `Data` is
    /// undesirable.
    ///
    /// - Parameter bytes: A raw buffer pointer containing an S-expression. The caller
    ///   must ensure the buffer remains valid for the duration of this call.
    /// - Returns: A token stream positioned at the beginning of the token sequence.
    /// - Throws: `VsexprError.tokenLimitExceeded` if the input contains more than 256 tokens.
    ///
    /// - Warning: The buffer contents are copied into a heap-allocated token storage.
    ///   The original buffer is not retained and may be deallocated after this call returns.
    public static func tokenize(_ bytes: UnsafeRawBufferPointer) throws(VsexprError) -> SExprTokenStream {
        guard !bytes.isEmpty else {
            return SExprTokenStream(
                startOffset: 0, count: 0,
                storage: TokenStorage(payload: "")
            )
        }
        let storage = TokenStorage(rawBytes: bytes)
        guard !storage.result.truncated else {
            throw .tokenLimitExceeded
        }
        return SExprTokenStream(
            startOffset: 0,
            count: Int(storage.result.count),
            storage: storage,
            truncated: false
        )
    }

    /// Parses an S-expression string into a value conforming to `VsexprDecodable`.
    ///
    /// This overload routes through `VsexprDecoder` using the zero-reflection manual
    /// combinator path. The type's `init(from:)` implementation reads tokens sequentially
    /// from the stream, avoiding runtime reflection overhead.
    ///
    /// - Parameters:
    ///   - type: The `VsexprDecodable` type to decode.
    ///   - payload: An S-expression string, such as `"(host 0.0.0.0) (port 443)"`.
    /// - Returns: A fully initialized instance of `type`.
    /// - Throws: `VsexprError.missingKey` if a required key is not found,
    ///   `VsexprError.typeMismatch` if a value cannot be converted to the expected type,
    ///   or `VsexprError.tokenLimitExceeded` if the input exceeds 256 tokens.
    public static func parse<T: VsexprDecodable>(
        _ type: T.Type, from payload: String
    ) throws(VsexprError) -> T {
        try VsexprDecoder().decode(type, from: payload)
    }

    /// Parses an S-expression string into a value conforming to `Decodable`.
    ///
    /// This overload routes through `VsexprDecoder` using the runtime reflection path.
    /// Swift's compiler-synthesized `Decodable` conformance is used to automatically
    /// map snake_case S-expression keys to camelCase Swift properties.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode.
    ///   - payload: An S-expression string, such as `"(host 0.0.0.0) (port 443)"`.
    /// - Returns: A fully initialized instance of `type`.
    /// - Throws: `VsexprError.missingKey` if a required key is not found,
    ///   `VsexprError.typeMismatch` if a value cannot be converted to the expected type,
    ///   or `VsexprError.tokenLimitExceeded` if the input exceeds 256 tokens.
    ///
    /// - Note: By default, snake_case keys in the S-expression are automatically mapped
    ///   to camelCase Swift property names. Configure this behavior via
    ///   `VsexprDecoder.keyDecodingStrategy`.
    public static func parse<T: Decodable>(
        _ type: T.Type, from payload: String
    ) throws(VsexprError) -> T {
        try VsexprDecoder().decode(type, from: payload)
    }

    /// Parses raw binary data into a value conforming to `Decodable`.
    ///
    /// This overload accepts `Data` directly, avoiding intermediate `String` allocation.
    /// The data is tokenized in-place and decoded using the runtime reflection path.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode.
    ///   - data: Raw bytes containing an S-expression.
    /// - Returns: A fully initialized instance of `type`.
    /// - Throws: `VsexprError.missingKey` if a required key is not found,
    ///   `VsexprError.typeMismatch` if a value cannot be converted to the expected type,
    ///   or `VsexprError.tokenLimitExceeded` if the input exceeds 256 tokens.
    public static func parse<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(VsexprError) -> T {
        try VsexprDecoder().decode(type, from: data)
    }

    /// Serializes a value conforming to `Encodable` into an S-expression string.
    ///
    /// The value is encoded using the runtime reflection path. Property names are
    /// automatically converted from camelCase to snake_case in the output.
    ///
    /// - Parameter value: The `Encodable` value to serialize.
    /// - Returns: An S-expression string, such as `"(host 0.0.0.0) (port 443)"`.
    /// - Throws: Any error thrown during encoding. Unlike `VsexprEncoder.encodeToString`,
    ///   this method does not use typed throws.
    ///
    /// - Note: Use `VsexprEncoder` directly for finer control over key encoding strategies,
    ///   `userInfo`, or to obtain `Data` output instead of `String`.
    public static func serialize<T: Encodable>(_ value: T) throws -> String {
        try VsexprEncoder().encodeToString(value)
    }

    /// Serializes a value conforming to `VsexprEncodable` into an S-expression string.
    ///
    /// The value is encoded using the zero-reflection manual path. The type's
    /// `encode(to:strategy:)` implementation writes tokens directly to the output string.
    ///
    /// - Parameter value: The `VsexprEncodable` value to serialize.
    /// - Returns: An S-expression string, such as `"(host 0.0.0.0) (port 443)"`.
    /// - Throws: `VsexprError` if encoding fails.
    public static func serialize<T: VsexprEncodable>(_ value: T) throws(VsexprError) -> String {
        try VsexprEncoder().encodeToString(value)
    }

    /// Creates a streaming decoder for progressive S-expression ingestion.
    ///
    /// This is a convenience entry point that creates a `VsexprDecoder` with default
    /// configuration and returns a `VsexprAsyncSequence` over the provided byte source.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode from each frame.
    ///   - bytes: An asynchronous byte source (e.g., `URLSession.bytes(from:)`).
    ///   - strategy: The framing strategy for detecting complete expressions.
    ///     Defaults to `.balancedParentheses`.
    /// - Returns: A `VsexprAsyncSequence` using default decoder configuration
    ///   (`.convertFromSnakeCase` key strategy).
    ///
    /// - Note: For custom key strategies, `userInfo`, or zero-reflection types,
    ///   create a `VsexprDecoder` instance and call `decodeStream(_:from:strategy:)` directly.
    public static func parseStream<T: Decodable, Base: AsyncSequence>(
        _ type: T.Type, from bytes: Base, strategy: VsexprFramingStrategy = .lineDelimited
    ) -> VsexprAsyncSequence<Base, T> where Base.Element == UInt8, Base.Failure == any Error {
        VsexprDecoder().decodeStream(type, from: bytes, strategy: strategy)
    }

    /// Computes the line and column location for a byte offset within a payload string.
    ///
    /// This is an internal utility used for lazy error diagnostics. Location computation
    /// is deferred to error paths only, avoiding overhead on the happy path.
    ///
    /// - Parameters:
    ///   - payload: The original S-expression string.
    ///   - at: The byte offset (UTF-8) into `payload`.
    /// - Returns: A `FileLocation` containing the 1-indexed line and column numbers.
    static func location(in payload: String, at byteOffset: Int) -> FileLocation {
        var line = 1
        var col = 1
        for (i, byte) in payload.utf8.enumerated() {
            if i >= byteOffset { break }
            if byte == 0x0A {
                line += 1
                col = 1
            } else {
                col += 1
            }
        }
        return FileLocation(line: line, column: col)
    }
}

// MARK: - Framing Strategy

/// Determines how complete S-expression frames are detected in a byte stream.
///
/// The framing strategy decouples I/O boundary detection from syntax parsing.
/// Each strategy implements a different trade-off between structure enforcement
/// and flexibility for various deployment profiles (configuration files, Unix
/// pipelines, network protocols).
public enum VsexprFramingStrategy: Sendable {
    /// Each expression must be enclosed in top-level matching parentheses.
    /// Frame is detected when paren depth returns to 0 after positive excursion.
    /// Best for structured command envelopes and configuration blocks.
    case balancedParentheses

    /// Each expression is terminated by a newline (`0x0A`).
    /// Allows raw atoms at the root level. CRLF (`\r\n`) is handled transparently.
    /// Standard for Unix pipeline integrations.
    case lineDelimited

    /// Each payload is prefixed by a fixed-size big-endian byte count header.
    /// The framing layer reads the header, then extracts exactly that many payload bytes.
    /// Eliminates streaming scan overhead over raw network TCP sockets.
    case lengthPrefixed(headerSize: LengthHeaderSize)

    public enum LengthHeaderSize: Sendable {
        case uint16BigEndian
        case uint32BigEndian
    }
}

// MARK: - Async Sequence

/// An asynchronous sequence that progressively yields decoded instances from a
/// streaming byte source.
///
/// `VsexprAsyncSequence` wraps any `AsyncSequence` of bytes and detects complete
/// top-level S-expression frames using a configurable scalar framing state machine.
/// Each complete frame is tokenized using the SIMD engine and decoded using the
/// provided `VsexprDecoder` configuration.
///
/// Memory usage is bounded by the size of the largest single top-level expression,
/// regardless of the total stream length.
///
/// ### Example
///
/// ```swift
/// let decoder = VsexprDecoder()
/// decoder.keyDecodingStrategy = .convertFromSnakeCase
///
/// let (bytes, _) = try await URLSession.shared.bytes(from: url)
/// let sequence = decoder.decodeStream(NodeMetrics.self, from: bytes)
///
/// for try await metric in sequence {
///     print("Node \(metric.nodeId): \(metric.cpuUtilization)%")
/// }
/// ```
///
/// - Note: Both `Decodable` and `VsexprDecodable` types are supported. Swift's
///   overload resolution selects the correct decode path based on the generic
///   constraint at the call site.
public struct VsexprAsyncSequence<Base: AsyncSequence, T: Decodable>: AsyncSequence
where Base.Element == UInt8, Base.Failure == any Error {
    public typealias Element = T

    private let base: Base
    private let decoder: VsexprDecoder
    private let strategy: VsexprFramingStrategy

    /// Creates an asynchronous sequence from a byte source and decoder configuration.
    ///
    /// - Parameters:
    ///   - base: An asynchronous sequence of bytes (e.g., `URLSession.AsyncBytes`).
    ///   - decoder: The decoder to use for each frame. Defaults to a fresh
    ///     `VsexprDecoder` with `.convertFromSnakeCase` strategy.
    ///   - strategy: The framing strategy for detecting complete expressions.
    ///     Defaults to `.lineDelimited`.
    public init(
        _ base: Base, decoder: VsexprDecoder = VsexprDecoder(),
        strategy: VsexprFramingStrategy = .lineDelimited
    ) {
        self.base = base
        self.decoder = decoder
        self.strategy = strategy
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            baseIterator: base.makeAsyncIterator(), decoder: decoder, strategy: strategy)
    }
    public struct AsyncIterator: AsyncIteratorProtocol, @unchecked Sendable {
        var baseIterator: Base.AsyncIterator
        let decoder: VsexprDecoder
        let strategy: VsexprFramingStrategy
        var buffer: ContiguousArray<UInt8>
        var tracker: VsexprFrameTracker
        var frameCount: Int = 0
        let reusableStorage = TokenStorage()

        init(baseIterator: Base.AsyncIterator, decoder: VsexprDecoder, strategy: VsexprFramingStrategy) {
            self.baseIterator = baseIterator
            self.decoder = decoder
            self.strategy = strategy
            self.buffer = ContiguousArray<UInt8>()
            self.buffer.reserveCapacity(4_096)
            self.tracker = VsexprFrameTracker(strategy: strategy)
        }

        public mutating func next() async throws -> T? {
            while let byte = try await baseIterator.next() {
                buffer.append(byte)
                let frameComplete = try tracker.feed(byte, bufferCount: buffer.count)

                if frameComplete {
                    frameCount += 1
                    return try decodeFrame()
                }
            }

            // EOF boundary verification
            guard tracker.hasPartialData else {
                if frameCount == 0, !buffer.isEmpty {
                    throw framingMismatchError()
                }
                return nil
            }

            // Strategy-specific EOF handling
            switch strategy {
            case .lengthPrefixed:
                throw VsexprError.unexpectedEnd
            case .balancedParentheses:
                throw VsexprError.syntaxError(
                    description: "Stream ended with unterminated expression")
            case .lineDelimited:
                // Line-delimited inputs can safely process trailing non-newline data at EOF
                frameCount += 1
                return try decodeFrame()
            }
        }
    }
}

// MARK: - URLSession.AsyncBytes Convenience

extension VsexprAsyncSequence where Base == URLSession.AsyncBytes {
    /// Creates an asynchronous sequence from a `URLSession` byte stream.
    ///
    /// - Parameters:
    ///   - bytes: An asynchronous byte source from `URLSession.bytes(from:)`.
    ///   - decoder: The decoder to use for each frame.
    ///   - strategy: The framing strategy for detecting complete expressions.
    public init(
        _ bytes: URLSession.AsyncBytes, decoder: VsexprDecoder = VsexprDecoder(),
        strategy: VsexprFramingStrategy = .lineDelimited
    ) {
        self.base = bytes
        self.decoder = decoder
        self.strategy = strategy
    }
}
