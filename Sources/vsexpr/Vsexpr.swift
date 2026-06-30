public import Foundation
import vsexprLib

public enum Vsexpr {
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

    public static func tokenize(_ data: Data) throws(VsexprError) -> SExprTokenStream {
        var capturedError: VsexprError?
        var result: SExprTokenStream!
        data.withUnsafeBytes { rawBuffer in
            guard rawBuffer.count > 0 else {
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

    public static func tokenize(_ bytes: UnsafeRawBufferPointer) throws(VsexprError) -> SExprTokenStream {
        guard bytes.count > 0 else {
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

    public static func parse<T: VsexprDecodable>(
        _ type: T.Type, from payload: String
    ) throws(VsexprError) -> T {
        var stream = try tokenize(payload)
        return try T(from: &stream)
    }

    public static func parse<T: Decodable>(
        _ type: T.Type, from payload: String
    ) throws(VsexprError) -> T {
        try VsexprDecoder().decode(type, from: payload)
    }

    public static func parse<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(VsexprError) -> T {
        try VsexprDecoder().decode(type, from: data)
    }

    public static func serialize<T: Encodable>(_ value: T) throws -> String {
        try VsexprEncoder().encode(value)
    }

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
