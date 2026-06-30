public import Foundation
import vsexprLib

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

// MARK: - Frame Tracker

/// A scalar state machine that detects complete S-expression frame boundaries.
///
/// The tracker is strategy-polymorphic: it dispatches to the appropriate detection
/// logic based on the `VsexprFramingStrategy` provided at initialization. It processes
/// bytes one at a time and is intentionally scalar (not SIMD) because it runs at
/// ~1 cycle/byte, which is faster than typical network ingestion rates.
struct VsexprFrameTracker {
    private let strategy: VsexprFramingStrategy

    // Balanced-parentheses state
    private var parenDepth: Int = 0
    private var inString: Bool = false
    private var isEscaped: Bool = false
    private var hasContent: Bool = false

    // Length-prefixed state
    private var expectedPayloadSize: Int?
    private var headerBytesAccumulated: Int = 0
    private var headerValue: UInt32 = 0

    /// Creates a frame tracker for the given framing strategy.
    ///
    /// - Parameter strategy: The framing strategy to use for frame detection.
    init(strategy: VsexprFramingStrategy) {
        self.strategy = strategy
    }

    /// Feeds a single byte into the framing state machine.
    ///
    /// - Parameters:
    ///   - byte: The next byte from the input stream.
    ///   - bufferCount: The total number of bytes accumulated in the buffer so far
    ///     (including this byte). Used by `.lengthPrefixed` to track payload consumption.
    /// - Returns: `true` the exact moment a complete structural expression frame is bounded.
    /// - Throws: Strategy-specific errors for malformed input (e.g., nesting depth exceeded,
    ///   unexpected close paren).
    mutating func feed(_ byte: UInt8, bufferCount: Int) throws -> Bool {
        switch strategy {
        case .balancedParentheses:
            return try feedBalancedParentheses(byte)

        case .lineDelimited:
            return feedLineDelimited(byte)

        case .lengthPrefixed(let headerSize):
            return feedLengthPrefixed(byte, bufferCount: bufferCount, headerSize: headerSize)
        }
    }

    /// Resets the tracker to its initial state for reuse.
    mutating func reset() {
        parenDepth = 0
        inString = false
        isEscaped = false
        hasContent = false
        expectedPayloadSize = nil
        headerBytesAccumulated = 0
        headerValue = 0
    }

    /// Whether the tracker has accumulated partial data since the last reset.
    var hasPartialData: Bool {
        switch strategy {
        case .balancedParentheses:
            return hasContent || parenDepth > 0 || inString
        case .lineDelimited:
            return hasContent
        case .lengthPrefixed:
            return expectedPayloadSize != nil || headerBytesAccumulated > 0
        }
    }

    // MARK: - Balanced Parentheses

    private mutating func feedBalancedParentheses(_ byte: UInt8) throws -> Bool {
        if inString {
            if byte == 0x5C {
                isEscaped = !isEscaped
            } else if byte == 0x22 {
                if !isEscaped {
                    inString = false
                }
                isEscaped = false
            } else {
                isEscaped = false
            }
        } else {
            switch byte {
            case 0x22:
                inString = true
                isEscaped = false
            case 0x28:
                parenDepth += 1
                hasContent = true
                if parenDepth > 64 {
                    throw VsexprError.nestingDepthExceeded
                }
            case 0x29:
                parenDepth -= 1
                if parenDepth < 0 {
                    throw VsexprError.syntaxError(description: "unexpected close paren")
                }
            default:
                break
            }
        }
        let frameComplete = parenDepth == 0 && hasContent && !inString
        if frameComplete {
            hasContent = false
        }
        return frameComplete
    }

    // MARK: - Line Delimited

    private mutating func feedLineDelimited(_ byte: UInt8) -> Bool {
        if byte == 0x0A {
            let frameComplete = hasContent
            hasContent = false
            return frameComplete
        }
        if !hasContent && byte != 0x20 && byte != 0x0D && byte != 0x09 {
            hasContent = true
        }
        return false
    }

    // MARK: - Length Prefixed

    private mutating func feedLengthPrefixed(
        _ byte: UInt8, bufferCount: Int, headerSize: VsexprFramingStrategy.LengthHeaderSize
    ) -> Bool {
        if let expectedSize = expectedPayloadSize {
            let headerBytes = headerSize == .uint16BigEndian ? 2 : 4
            let payloadBytesRead = bufferCount - headerBytes
            return payloadBytesRead >= expectedSize
        }

        headerBytesAccumulated += 1
        headerValue = (headerValue << 8) | UInt32(byte)

        let targetHeaderBytes = headerSize == .uint16BigEndian ? 2 : 4
        if headerBytesAccumulated == targetHeaderBytes {
            expectedPayloadSize = Int(headerValue)
            if headerValue == 0 {
                reset()
                return true
            }
        }
        return false
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
        private var baseIterator: Base.AsyncIterator
        private let decoder: VsexprDecoder
        private let strategy: VsexprFramingStrategy
        private var buffer: ContiguousArray<UInt8>
        private var tracker: VsexprFrameTracker
        private var frameCount: Int = 0

        init(baseIterator: Base.AsyncIterator, decoder: VsexprDecoder, strategy: VsexprFramingStrategy) {
            self.baseIterator = baseIterator
            self.decoder = decoder
            self.strategy = strategy
            self.buffer = ContiguousArray<UInt8>()
            self.buffer.reserveCapacity(2048)
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
                if frameCount == 0 && !buffer.isEmpty {
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

        private mutating func decodeFrame() throws -> T {
            let frameString = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            tracker.reset()
            do {
                return try decoder.decode(T.self, from: frameString)
            } catch {
                throw wrapError(error, frame: frameString)
            }
        }

        private static func strategyNameFor(_ s: VsexprFramingStrategy) -> String {
            switch s {
            case .balancedParentheses: return "balancedParentheses"
            case .lineDelimited: return "lineDelimited"
            case .lengthPrefixed: return "lengthPrefixed"
            }
        }

        private func wrapError(_ error: VsexprError, frame: String) -> VsexprError {
            let preview =
                frame.count > 64
                ? String(frame.prefix(61)) + "..."
                : frame
            let strategyName = Self.strategyNameFor(strategy)
            return .framingError(
                description:
                    "\(error) [strategy: \(strategyName), frame: \"\(preview)\"]"
            )
        }

        private func framingMismatchError() -> VsexprError {
            let strategyName = Self.strategyNameFor(strategy)
            let hint: String
            if buffer.isEmpty {
                hint = "Input produced no frames"
            } else {
                let p = buffer.prefix(64)
                let preview = String(p.map { UnicodeScalar($0) }.map(String.init).joined())
                hint = """
                    Input (\(buffer.count) bytes) produced no \
                    frames — "\(preview)"
                    """
            }
            return .framingError(
                description:
                    "\(hint). [strategy: \(strategyName)."
                    + " If your input uses a different format, try a"
                    + " different VsexprFramingStrategy.]"
            )
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
