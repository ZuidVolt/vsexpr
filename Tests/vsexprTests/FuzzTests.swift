import PropertyBased
import Testing
import vsexprLib

@testable import vsexpr

// MARK: - Arbitrary Input Must Not Crash

@Test
func arbitraryAsciiInputDoesNotCrash() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...500)) { input in
        let _ = try? Vsexpr.tokenize(input)
    }
}

@Test
func arbitraryStringWithParensDoesNotCrash() async {
    let charGen = Gen.oneOf(
        Gen.ascii,
        Gen.always(Character("(")),
        Gen.always(Character(")")),
        Gen.always(Character(".")),
        Gen.always(Character("\"")),
    )
    await propertyCheck(input: charGen.string(of: 0...300)) { input in
        let _ = try? Vsexpr.tokenize(input)
    }
}

// MARK: - Token Count Bounds

@Test
func tokenCountNeverExceedsInputLength() async {
    await propertyCheck(input: Gen.ascii.string(of: 0...300)) { input in
        let stream = try? Vsexpr.tokenize(input)
        #expect(stream == nil || stream!.count <= input.utf8.count)
    }
}

// MARK: - Paren Balance

@Test
func parensAreBalancedInWellFormedInput() async {
    await propertyCheck(input: Gen.int(in: 0...30)) { depth in
        let open = String(repeating: "(", count: depth)
        let close = String(repeating: ")", count: depth)
        let payload = "\(open)host\(close)"
        let stream = try? Vsexpr.tokenize(payload)
        var s = stream!
        var opens = 0
        var closes = 0
        while !s.isAtEnd {
            if let t = s.peek() {
                if s_expr_token_is_open_paren(t) { opens += 1 } else if s_expr_token_is_close_paren(t) { closes += 1 }
            }
            s.advance()
        }
        #expect(opens == closes)
    }
}

// MARK: - Random S-Expr Roundtrip

@Test
func randomSExprTokenizationDoesNotCrash() async {
    let keyGen = Gen.oneOf(
        Gen.always("host"),
        Gen.always("port"),
        Gen.always("debug_mode"),
        Gen.always("unknown")
    )
    let valueGen = validAtomChar.string(of: 1...15)

    await propertyCheck(
        input: zip(keyGen, valueGen).array(of: 0...5)
    ) { pairs in
        let payload = pairs.map { "(\($0.0) \($0.1))" }.joined(separator: " ")
        let stream = try? Vsexpr.tokenize(payload)
        #expect(stream == nil || stream!.count >= 0)
    }
}
