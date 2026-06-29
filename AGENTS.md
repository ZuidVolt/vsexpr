# vsexpr

A high-performance S-expression parser built on Clang SIMD vector extensions
with a Swift 6.3+ wrapper using seamless C++ interoperability.

## Architecture

- **`vsexprLib/`** — C++23 single-header SIMD S-expression tokenizer and schema extraction engine
- **`vsexpr/`** — Swift 6 wrapper providing `SExprParser` and `VsexprDecodable` APIs
- **`vsexprTests/`** — Property-based fuzz tests using `swift-property-based`

## Build & Test

```sh
swift build        # Build all targets
swift test         # Run tests
just check         # Build, format, and lint
```

## Code Conventions

- **C++ target (`vsexprLib`)**: C++23, no exceptions, no OOP — plain structs and free functions
- **Swift target (`vsexpr`)**: Swift 6 language mode, strict memory safety, `Sendable` types
- **Naming**: `CamelCase` for types and enum constants, `camelBack` for functions and variables
- **Testing**: Property-based fuzz testing via `PropertyBased` framework; avoid brittle hardcoded assertions

## Compiler Safety Flags

All C++ compilation uses the flags defined in `Package.swift` under `cxxSettings`. Key flags
include `-Wconversion`, `-Wsign-conversion`, `-Werror=dangling`, and `-Werror=switch` to
catch common classes of bugs at compile time.
