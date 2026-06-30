import vsexprLib

public enum Vsexpr {
    public static func tokenize(_ payload: String) throws(VsexprError) -> SExprTokenStream {
        let storage = _TokenStorage(payload: payload)
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
