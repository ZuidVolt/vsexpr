import Foundation
import vsexprLib

// MARK: - Frame Tracker

/// A scalar state machine that detects complete S-expression frame boundaries.
///
/// The tracker is strategy-polymorphic: it dispatches to the appropriate detection
/// logic based on the `VsexprFramingStrategy` provided at initialization. It processes
/// bytes one at a time and is intentionally scalar (not SIMD) because it runs at
/// ~1 cycle/byte, which is faster than typical network ingestion rates.
struct VsexprFrameTracker {
    private let strategy: VsexprFramingStrategy

    // Running coordinate metrics preserved across the stream lifecycle
    private(set) var currentLine: Int = 1
    private(set) var currentColumn: Int = 1
    private(set) var totalBytesProcessed: Int = 0

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
        totalBytesProcessed += 1
        if byte == 0x0A {
            currentLine += 1
            currentColumn = 1
        } else {
            currentColumn += 1
        }

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
                isEscaped.toggle()
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
        if !hasContent, byte != 0x20, byte != 0x0D, byte != 0x09 {
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

// MARK: - AsyncIterator Private Helpers

extension VsexprAsyncSequence.AsyncIterator {
    @inline(always)
    mutating func decodeFrame() throws -> T {
        let headerOffset = caseLengthHeaderOffset(for: strategy)
        let totalFrameBytes = buffer.count
        guard totalFrameBytes >= headerOffset else {
            throw VsexprError.unexpectedEnd
        }
        let purePayloadBytes = totalFrameBytes - headerOffset
        let keyDecodingStrategy = decoder.keyDecodingStrategy
        let userInfo = decoder.userInfo
        let currentLine = tracker.currentLine
        let currentColumn = tracker.currentColumn
        let strategyName = Self.strategyNameFor(strategy)
        let storage = reusableStorage

        let instance: T = try buffer.withUnsafeMutableBufferPointer { mutableBuffer in
            guard let baseAddress = mutableBuffer.baseAddress else {
                throw VsexprError.unexpectedEnd
            }
            let payloadPointer = baseAddress.advanced(by: headerOffset)
            let cCharPointer = UnsafeMutableRawPointer(payloadPointer).assumingMemoryBound(to: CChar.self)

            let result = tokenize_to_result(cCharPointer, size_t(purePayloadBytes))
            guard !result.truncated else {
                throw VsexprError.tokenLimitExceeded
            }

            let borrowedBuffer = UnsafeBufferPointer(start: cCharPointer, count: purePayloadBytes)

            storage.result = result
            storage.buffer = borrowedBuffer

            let standaloneStream = SExprTokenStream(
                startOffset: 0,
                count: Int(result.count),
                storage: storage,
                strategy: keyDecodingStrategy
            )

            let internalDecoder = VsexprDecoderImpl(
                stream: standaloneStream,
                payload: "",
                strategy: keyDecodingStrategy,
                userInfo: userInfo
            )

            do {
                return try T(from: internalDecoder)
            } catch {
                let frameString = String(
                    decoding: UnsafeBufferPointer(start: baseAddress, count: totalFrameBytes), as: UTF8.self)
                let preview = frameString.count > 64 ? String(frameString.prefix(61)) + "..." : frameString
                throw VsexprError.framingError(
                    description:
                        "\(error) at line \(currentLine), column \(currentColumn) [strategy: \(strategyName), frame: \"\(preview)\"]"
                )
            }
        }

        // Compact memory: slide any trailing bytes forward to index 0
        if buffer.count > totalFrameBytes {
            let trailingBytesCount = buffer.count - totalFrameBytes
            buffer.withUnsafeMutableBufferPointer { ptr in
                let base = ptr.baseAddress!
                memmove(base, base.advanced(by: totalFrameBytes), trailingBytesCount)
            }
            buffer.removeLast(totalFrameBytes)
        } else {
            buffer.removeAll(keepingCapacity: true)
        }

        tracker.reset()
        return instance
    }

    @inline(always)
    func caseLengthHeaderOffset(for strategy: VsexprFramingStrategy) -> Int {
        if case .lengthPrefixed(let size) = strategy {
            return size == .uint16BigEndian ? 2 : 4
        }
        return 0
    }

    @inline(always)
    static func strategyNameFor(_ s: VsexprFramingStrategy) -> String {
        switch s {
        case .balancedParentheses: return "balancedParentheses"
        case .lineDelimited: return "lineDelimited"
        case .lengthPrefixed: return "lengthPrefixed"
        }
    }

    @inline(always)
    func wrapError(_ error: any Error, frame: String) -> VsexprError {
        let preview =
            frame.count > 64
            ? String(frame.prefix(61)) + "..."
            : frame
        let strategyName = Self.strategyNameFor(strategy)
        return .framingError(
            description:
                "\(error) at line \(tracker.currentLine), column \(tracker.currentColumn) [strategy: \(strategyName), frame: \"\(preview)\"]"
        )
    }

    @inline(always)
    func framingMismatchError() -> VsexprError {
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
