// ====================================================================================
// vsexpr — SIMD S-Expression Tokenizer
// ====================================================================================
//
// A zero-allocation, SIMD-accelerated tokenizer for S-expressions (Lisp-style
// parenthesized data). Designed for embedding in high-throughput configuration
// parsers, Lisp interpreters, and data serialization pipelines.
//
// Usage:
//   SExprParseState state{};
//   SExprToken tokens[256];
//   std::string_view input = "(host 0.0.0.0) (port 443)";
//   size_t count = tokenize(input, std::span<SExprToken>(tokens, 256), state);
//
// Memory model:
//   All tokenization is zero-copy. Returned SExprToken values point directly into
//   the caller's input buffer. No heap allocations occur during tokenization.
//
// Thread safety:
//   All functions are pure and reentrant. No global mutable state.
//
// ====================================================================================

#ifndef VSEXPR_HPP
#define VSEXPR_HPP

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>
#include <string_view>
#include <type_traits>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// --- Constants ---

static constexpr size_t BITMASK_WIDTH = 32;
static constexpr size_t MAX_TOKENS = 256;
static constexpr size_t SIMD_BLOCK_SIZE = 32;
static constexpr size_t MAX_TOKEN_LIMIT = 1024;
static constexpr size_t EXPECTED_TOKEN_SIZE = 24;
static constexpr size_t MAX_NESTING_DEPTH = 64;

// --- Static Assertions and Assumptions ---

static_assert(sizeof(char) == 1, "char must be 1 byte");
static_assert(sizeof(uint8_t) == 1, "uint8_t must be 1 byte");
static_assert(sizeof(uint32_t) == 4, "uint32_t must be 4 bytes");
static_assert(BITMASK_WIDTH == 32, "BITMASK_WIDTH must be 32 for uint32_t bitmask");
static_assert(MAX_TOKENS > 0, "MAX_TOKENS must be positive");
static_assert(MAX_TOKENS <= MAX_TOKEN_LIMIT, "MAX_TOKENS unreasonably large");
static_assert(SIMD_BLOCK_SIZE == 32, "SIMD block must be 32 bytes");
static_assert(SIMD_BLOCK_SIZE == BITMASK_WIDTH, "SIMD block size must match bitmask width");
static_assert(MAX_NESTING_DEPTH > 0 && MAX_NESTING_DEPTH <= 128, "MAX_NESTING_DEPTH must be reasonable");

// clang-format off
// Bits: 0x01 = whitespace, 0x02 = open paren, 0x04 = close paren, 0x08 = quote
static constexpr uint8_t CHAR_WS   = 0x01;
static constexpr uint8_t CHAR_OPEN = 0x02;
static constexpr uint8_t CHAR_CLS  = 0x04;
static constexpr uint8_t CHAR_QUOT = 0x08;
static constexpr uint8_t CHAR_ATOM_END = CHAR_WS | CHAR_OPEN | CHAR_CLS | CHAR_QUOT;

alignas(64) inline constexpr uint8_t CHAR_CLASS[256] = {
//   0    1    2    3    4    5    6    7    8    9    A    B    C    D    E    F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 00-0F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 10-1F
    CHAR_WS, 0, CHAR_QUOT, 0,   0,   0,   0,   0,   CHAR_OPEN, CHAR_CLS, 0,   0,   0,   0,   0,   0, // 20-2F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 30-3F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 40-4F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 50-5F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 60-6F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 70-7F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 80-8F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 90-9F
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // A0-AF
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // B0-BF
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // C0-CF
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // D0-DF
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // E0-EF
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // F0-FF
};
// clang-format on

static_assert(sizeof(CHAR_CLASS) == 256, "CHAR_CLASS must be exactly 256 bytes");

[[nodiscard]] inline bool is_atom_break(char c) noexcept {
    return (CHAR_CLASS[static_cast<uint8_t>(c)] & CHAR_ATOM_END) != 0;
}

[[nodiscard]] inline bool is_open_paren(char c) noexcept {
    return c == '(';
}

[[nodiscard]] inline bool is_close_paren(char c) noexcept {
    return c == ')';
}

// --- Data Types ---

// SExprTokenType — Structural class of an S-expression token.
//
// OPEN_PAREN  (0) — An opening parenthesis '('
// CLOSE_PAREN (1) — A closing parenthesis ')'
// ATOM        (2) — A bare symbol, number, or quoted string literal
//
// This enum is exposed to Swift via C++ interoperability.
enum class SExprTokenType : uint8_t {
    OPEN_PAREN = 0,
    CLOSE_PAREN = 1,
    ATOM = 2,
};

// SExprToken — A single token produced by the tokenizer.
//
// Fields:
//   type   — The structural class of this token (OPEN_PAREN, CLOSE_PAREN, ATOM)
//   ptr    — Pointer to the first byte of this token's text within the input buffer
//   length — Number of bytes in the token's text (excluding surrounding quotes for strings)
//
// The pointer `ptr` is valid for the lifetime of the input buffer passed to the
// tokenizer. For string atoms, the quotes are excluded from the text range, but
// escape sequences (e.g. \n, \") are NOT unescaped — use unescape_in_place() for that.
//
// sizeof(SExprToken) == 24 bytes, standard layout, 8-byte aligned.
struct SExprToken {
    SExprTokenType type;
    const char* _Nonnull ptr;
    size_t length;
};

static_assert(sizeof(SExprToken) == EXPECTED_TOKEN_SIZE, "SExprToken must have fixed layout for Swift interop");
static_assert(std::is_standard_layout_v<SExprToken>, "SExprToken must be standard layout");

// s_expr_token_is_open_paren — Test if a token is an opening parenthesis.
[[nodiscard]] inline bool s_expr_token_is_open_paren(SExprToken t) noexcept {
    return t.type == SExprTokenType::OPEN_PAREN;
}

// s_expr_token_is_close_paren — Test if a token is a closing parenthesis.
[[nodiscard]] inline bool s_expr_token_is_close_paren(SExprToken t) noexcept {
    return t.type == SExprTokenType::CLOSE_PAREN;
}

// s_expr_token_is_atom — Test if a token is an atom (symbol, number, or string).
[[nodiscard]] inline bool s_expr_token_is_atom(SExprToken t) noexcept {
    return t.type == SExprTokenType::ATOM;
}

// SExprParseState — Mutable state maintained across tokenization calls.
//
// Fields:
//   depth     — Current nesting depth of open parentheses (capped at MAX_NESTING_DEPTH)
//   in_string — Whether the tokenizer is currently inside an unclosed quoted string
//
// Cache-line aligned (64 bytes) to avoid false sharing in concurrent scenarios.
struct alignas(64) SExprParseState {
    uint32_t depth = 0;
    bool in_string = false;
};

static_assert(sizeof(SExprParseState) <= 64, "SExprParseState must fit in one cache line");
static_assert(std::is_standard_layout_v<SExprParseState>, "SExprParseState must be standard layout");

// --- SIMD Processing Foundations ---

template <size_t Width> using SimdCharVector = char __attribute__((vector_size(Width)));

template <size_t Width>
    requires(Width > 0 && Width <= BITMASK_WIDTH)
[[nodiscard]] inline uint32_t reduce_vector_to_bitmask(SimdCharVector<Width> vec_mask) noexcept {
#if defined(__AVX2__)
    static_assert(Width == 32, "AVX2 requires 32-byte vectors");
    return static_cast<uint32_t>(__builtin_ia32_pmovmskb256(reinterpret_cast<__v32qi>(vec_mask)));
#elif defined(__ARM_NEON)
    auto reduce_neon16 = [](uint8x16_t raw) -> uint32_t {
        uint8x16_t bits = vshrq_n_u8(raw, 7);
        const uint16x8_t weights = {1, 2, 4, 8, 16, 32, 64, 128};
        uint8x8_t lo8 = vget_low_u8(bits);
        uint8x8_t hi8 = vget_high_u8(bits);
        uint16x8_t lo16 = vmulq_u16(vmovl_u8(lo8), weights);
        uint16x8_t hi16 = vmulq_u16(vmovl_u8(hi8), weights);
        uint16_t lo = vaddvq_u16(lo16);
        uint16_t hi = vaddvq_u16(hi16);
        return static_cast<uint32_t>(lo | (static_cast<uint32_t>(hi) << 8));
    };
    if constexpr(Width == 16) {
        return reduce_neon16(vreinterpretq_u8_s8(vec_mask));
    } else if constexpr(Width == 32) {
        const auto* raw = reinterpret_cast<const uint8_t*>(&vec_mask);
        uint32_t lo = reduce_neon16(vld1q_u8(raw));
        uint32_t hi = reduce_neon16(vld1q_u8(raw + 16));
        return lo | (hi << 16);
    } else {
        uint32_t mask = 0;
#pragma clang loop unroll(full)
        for(size_t i = 0; i < Width; ++i) {
            mask |= (static_cast<uint8_t>(vec_mask[i]) >> 7) << i;
        }
        return mask;
    }
#else
    uint32_t mask = 0;
#pragma clang loop unroll(full)
    for(size_t i = 0; i < Width; ++i) {
        mask |= (static_cast<uint8_t>(vec_mask[i]) >> 7) << i;
    }
    return mask;
#endif
}

[[nodiscard]] inline uint32_t mask_quoted_regions(uint32_t quote_mask, bool& in_string) noexcept {
    // Branchless parallel prefix-XOR scan (simdjson technique)
    // Converts raw quote positions into a mask of which byte positions are inside strings
    uint32_t mask = quote_mask;
    mask ^= mask << 1;
    mask ^= mask << 2;
    mask ^= mask << 4;
    mask ^= mask << 8;
    mask ^= mask << 16;

    // If we started inside a string, invert the entire mask
    if(in_string) {
        mask = ~mask;
    }

    // Update carry-out state for the next 32-byte block
    in_string = (static_cast<int32_t>(mask) < 0);
    return mask;
}

// --- Scalar Tokenizer (full buffer) ---

inline size_t tokenize_scalar_fallback(std::string_view input, std::span<SExprToken> tokens,
                                       SExprParseState& state) noexcept {
    assert(!tokens.empty());

    const char* _Nonnull buffer = input.data();
    const size_t length = input.size();
    const size_t max_tokens = tokens.size();
    size_t count = 0;
    size_t i = 0;

    while(i < length && count < max_tokens) {
        char c = buffer[i];

        if(__builtin_expect(c == ' ' || c == '\t' || c == '\n' || c == '\r', 0)) {
            ++i;
            continue;
        }

        if(__builtin_expect(c == '"', 0)) {
            if(state.in_string) {
                state.in_string = false;
                ++i;
                continue;
            }
            state.in_string = true;
            size_t start = i + 1;
            ++i;
            while(i < length && buffer[i] != '"') {
                if(buffer[i] == '\\' && (i + 1) < length) {
                    i += 2;
                } else {
                    ++i;
                }
            }
            if(i < length) {
                state.in_string = false;
                ++i;
            }
            SExprToken& t = tokens[count++];
            t.type = SExprTokenType::ATOM;
            t.ptr = buffer + start;
            t.length = (!state.in_string) ? (i - 1 - start) : (length - start);
            continue;
        }

        if(__builtin_expect(state.in_string, 0)) {
            ++i;
            continue;
        }

        if(__builtin_expect(c == '(', 1)) {
            SExprToken& t = tokens[count++];
            t.type = SExprTokenType::OPEN_PAREN;
            t.ptr = buffer + i;
            t.length = 1;
            if(state.depth < MAX_NESTING_DEPTH) {
                state.depth++;
            }
            ++i;
        } else if(__builtin_expect(c == ')', 1)) {
            SExprToken& t = tokens[count++];
            t.type = SExprTokenType::CLOSE_PAREN;
            t.ptr = buffer + i;
            t.length = 1;
            if(state.depth > 0) {
                state.depth--;
            }
            ++i;
        } else {
            size_t start = i;
            while(i < length) {
                if(__builtin_expect(is_atom_break(buffer[i]), 0)) {
                    break;
                }
                ++i;
            }
            SExprToken& t = tokens[count++];
            t.type = SExprTokenType::ATOM;
            t.ptr = buffer + start;
            t.length = i - start;
        }
    }

    return count;
}

// --- Stage 1: SIMD Structural Discovery + Scalar Atom Scan ---

inline size_t tokenize(std::string_view input, std::span<SExprToken> tokens, SExprParseState& state) noexcept {
    assert(!tokens.empty());

    const char* _Nonnull buffer = input.data();
    const size_t length = input.size();
    const size_t max_tokens = tokens.size();
    size_t count = 0;
    size_t i = 0;

    // Helper: emit atom from scalar region [start, end)
    auto emit_atoms_in_range = [&](size_t start, size_t end) -> void {
        size_t j = start;
        while(j < end && count < max_tokens) {
            char c = buffer[j];
            if(__builtin_expect(c == ' ' || c == '\t' || c == '\n' || c == '\r', 0)) {
                ++j;
                continue;
            }
            if(__builtin_expect(c == '"', 0)) {
                if(state.in_string) {
                    state.in_string = false;
                    ++j;
                    continue;
                }
                state.in_string = true;
                size_t str_start = j + 1;
                ++j;
                while(j < end && buffer[j] != '"') {
                    if(buffer[j] == '\\' && (j + 1) < end) {
                        j += 2;
                    } else {
                        ++j;
                    }
                }
                if(j < end) {
                    state.in_string = false;
                    ++j;
                }
                SExprToken& t = tokens[count++];
                t.type = SExprTokenType::ATOM;
                t.ptr = buffer + str_start;
                t.length = (!state.in_string) ? (j - 1 - str_start) : (end - str_start);
                continue;
            }
            if(__builtin_expect(state.in_string, 0)) {
                ++j;
                continue;
            }
            // Atom: consume until whitespace or structural
            size_t atom_start = j;
            while(j < end) {
                char c2 = buffer[j];
                if(c2 == ' ' || c2 == '\t' || c2 == '\n' || c2 == '\r' || c2 == '(' || c2 == ')' || c2 == '"') {
                    break;
                }
                ++j;
            }
            if(j > atom_start) {
                SExprToken& t = tokens[count++];
                t.type = SExprTokenType::ATOM;
                t.ptr = buffer + atom_start;
                t.length = j - atom_start;
            } else {
                // Skip structural/quote character that isn't part of an atom
                ++j;
            }
        }
    };

    // Phase 1: SIMD structural discovery (32-byte blocks)
    // seg_start is GLOBAL — persists across chunks so trailing atoms from one chunk
    // are correctly included in the gap before the first marker of the next chunk.
    size_t seg_start = 0;
    size_t scalar_start = 0;
    while(i + SIMD_BLOCK_SIZE <= length && count < max_tokens) {
        SimdCharVector<SIMD_BLOCK_SIZE> chunk;
        __builtin_memcpy(&chunk, buffer + i, SIMD_BLOCK_SIZE);

        uint32_t opens = reduce_vector_to_bitmask<SIMD_BLOCK_SIZE>(chunk == '(');
        uint32_t closes = reduce_vector_to_bitmask<SIMD_BLOCK_SIZE>(chunk == ')');
        uint32_t quotes = reduce_vector_to_bitmask<SIMD_BLOCK_SIZE>(chunk == '"');

        // Filter out escaped quotes: a quote preceded by an odd number of
        // consecutive backslashes is escaped and should not toggle string state.
        {
            uint32_t q = quotes;
            while(q) {
                int qi = __builtin_ctz(q);
                int backslashes = 0;
                for(int p = qi - 1; p >= 0 && buffer[i + p] == '\\'; --p) {
                    ++backslashes;
                }
                if(backslashes & 1) {
                    quotes &= ~(1U << qi);
                }
                q &= q - 1;
            }
        }

        uint32_t string_mask = mask_quoted_regions(quotes, state.in_string);
        opens &= ~string_mask;
        closes &= ~string_mask;

        uint32_t structural_mask = opens | closes;

        // Process segments between structural markers
        uint32_t remaining = structural_mask;
        while(remaining != 0 && count < max_tokens) {
            int index = __builtin_ctz(remaining);

            // Emit atoms in the gap before this structural marker
            size_t seg_end = i + index;
            if(seg_end > seg_start && !state.in_string) {
                emit_atoms_in_range(seg_start, seg_end);
            }

            // Emit the structural token
            uint32_t bit = (1U << index);
            if(count < max_tokens) {
                SExprToken& t = tokens[count++];
                if((opens & bit) != 0) {
                    t.type = SExprTokenType::OPEN_PAREN;
                    if(state.depth < MAX_NESTING_DEPTH) {
                        state.depth++;
                    }
                } else {
                    t.type = SExprTokenType::CLOSE_PAREN;
                    if(state.depth > 0) {
                        state.depth--;
                    }
                }
                t.ptr = buffer + i + index;
                t.length = 1;
            }

            seg_start = i + index + 1;
            remaining &= (remaining - 1);
        }

        // Don't emit trailing atoms — they may span chunk boundaries.
        // Only advance scalar_start when this chunk had structural markers,
        // so atoms spanning multiple marker-less chunks are handled by scalar tail.
        if(structural_mask != 0) {
            scalar_start = seg_start;
        }

        i += SIMD_BLOCK_SIZE;
    }

    // Phase 2: Scalar tail — starts from the last structural marker position
    // to handle any partial atoms spanning chunk boundaries
    if(scalar_start < length && count < max_tokens) {
        std::string_view tail(buffer + scalar_start, length - scalar_start);
        count += tokenize_scalar_fallback(tail, tokens.subspan(count), state);
    }

    return count;
}

// --- Tokenizer Result ---

// TokenizerResult — Complete tokenization output, returned by tokenize_to_result().
//
// Contains a fixed-capacity inline array of up to MAX_TOKENS (256) tokens.
// If the input requires more tokens than the capacity, the `truncated` flag
// is set to true and tokenization stops.
//
// Fields:
//   tokens    — Inline array of SExprToken values (256 × 24 = 6KB, fits in L1 cache)
//   count     — Number of valid tokens written to `tokens`
//   truncated — True if the input was truncated due to exceeding MAX_TOKENS
//
// Methods:
//   data()       — Returns a pointer to the raw token array
//   span()       — Returns a std::span of the valid token range [0, count)
//   full_span()  — Returns a std::span of the entire array [0, MAX_TOKENS)
struct TokenizerResult {
    SExprToken tokens[MAX_TOKENS]{};
    size_t count = 0;
    bool truncated = false;

    [[nodiscard]] const SExprToken* _Nonnull data() const noexcept {
        return tokens;
    }

    [[nodiscard]] SExprToken* _Nonnull mutable_data() noexcept {
        return tokens;
    }

    [[nodiscard]] std::span<const SExprToken> span() const noexcept {
        return std::span<const SExprToken>(tokens, count);
    }

    [[nodiscard]] std::span<const SExprToken, MAX_TOKENS> full_span() const noexcept {
        return std::span<const SExprToken, MAX_TOKENS>(tokens);
    }
};

static_assert(std::is_standard_layout_v<TokenizerResult>, "TokenizerResult must be standard layout");

// Forward declaration for unescape_in_place (defined after tokenize_to_result).
[[nodiscard]] inline size_t unescape_in_place(char* _Nonnull ptr, size_t length) noexcept;

// tokenize_to_result — Pure tokenization path (immutable-safe).
//
// This is the recommended entry point for read-only workloads. It performs
// SIMD-driven structural scanning and produces a complete TokenizerResult
// without modifying the input buffer.
//
// Example:
//   auto result = tokenize_to_result("(host 0.0.0.0) (port 443)");
//   if (result.truncated) { /* handle overflow */ }
//   for (auto& tok : result.span()) { /* process tokens */ }
[[nodiscard]] inline TokenizerResult tokenize_to_result(std::string_view input) noexcept {
    TokenizerResult result{};
    SExprParseState state{};
    std::span<SExprToken> token_span(result.tokens);
    result.count = tokenize(input, token_span, state);
    result.truncated = (result.count >= MAX_TOKENS && result.count < input.size());
    return result;
}

// tokenize_to_result — Mutable buffer path with in-situ unescaping.
//
// Accepts a non-const char* so the compiler knows the buffer may be modified.
// After tokenization, string atoms are unescaped in place (e.g. \" → ").
// The buffer must remain valid for the lifetime of the returned TokenizerResult.
[[nodiscard]] inline TokenizerResult tokenize_to_result(char* _Nonnull buffer, size_t length) noexcept {
    assert(buffer != nullptr || length == 0);
    TokenizerResult result = tokenize_to_result(std::string_view(buffer, length));

    for(size_t i = 0; i < result.count; ++i) {
        SExprToken& tok = result.tokens[i];
        if(tok.type != SExprTokenType::ATOM || tok.length == 0)
            continue;
        ptrdiff_t offset = tok.ptr - buffer;
        if(offset <= 0)
            continue;
        if(buffer[offset - 1] != '"')
            continue;
        tok.length = unescape_in_place(buffer + offset, tok.length);
    }

    return result;
}

// --- String Utilities ---

// unescape_in_place — Process escape sequences in a quoted string's content in place.
//
// Parameters:
//   ptr    — Pointer to the first byte of the string content (after opening quote)
//   length — Number of bytes in the string content (excluding surrounding quotes)
//
// Returns the new (shortened) length of the string after escape processing.
//
// Recognized escape sequences:
//   \n  → newline (0x0A)     \t  → tab (0x09)
//   \r  → carriage return    \"  → double quote
//   \\  → backslash          \0  → null byte
//   \x  → literal 'x' for any unrecognized character after backslash
//
// Since unescaped strings are always shorter than or equal to their escaped form,
// this function writes forward only and never reads beyond the original `length`.
// The caller must update the token's length field to the returned value.
[[nodiscard]] inline size_t unescape_in_place(char* _Nonnull ptr, size_t length) noexcept {
    size_t write = 0;
    for(size_t read = 0; read < length; ++read) {
        if(ptr[read] == '\\' && (read + 1) < length) {
            ++read;
            switch(ptr[read]) {
            case 'n':
                ptr[write++] = '\n';
                break;
            case 't':
                ptr[write++] = '\t';
                break;
            case 'r':
                ptr[write++] = '\r';
                break;
            case '"':
                ptr[write++] = '"';
                break;
            case '\\':
                ptr[write++] = '\\';
                break;
            case '0':
                ptr[write++] = '\0';
                break;
            default:
                ptr[write++] = ptr[read];
                break;
            }
        } else {
            ptr[write++] = ptr[read];
        }
    }
    return write;
}

// tokenize_to_result — Convenience wrapper accepting a read-only buffer pointer.
// Delegates to the immutable string_view overload (no in-situ unescaping).
[[nodiscard]] inline TokenizerResult tokenize_to_result(const char* _Nonnull buffer, size_t length) noexcept {
    assert(buffer != nullptr || length == 0);
    return tokenize_to_result(std::string_view(buffer, length));
}

#endif // VSEXPR_HPP
