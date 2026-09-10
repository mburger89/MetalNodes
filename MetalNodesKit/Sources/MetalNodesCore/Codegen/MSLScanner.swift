import Foundation
import Synchronization

/// A token scan over user-written MSL (spec §24.4). Deliberately *not* a parser: it answers
/// questions that tokens can answer — which identifiers are free, whether the text breaks out of
/// its scope, where the loops are — and nothing else. Where a question needs real grammar
/// ("does this loop terminate?") the answer is that we do not ask; §24.4 caps loops in codegen.
public enum MSLScanner {
    public struct Violation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case preprocessor(String)
            case unbalancedBrace
            case bareReturn
            case unbracedLoopBody
        }
        public let kind: Kind
        /// 0-based line within the user's own text.
        public let line: Int

        public init(kind: Kind, line: Int) {
            self.kind = kind
            self.line = line
        }
    }

    struct Token: Equatable, Sendable {
        enum Kind: Equatable { case identifier, number, punctuation }
        let kind: Kind
        let text: String
        let line: Int
        /// True when the previous non-space token was `.`, so this is a member or swizzle.
        let afterDot: Bool
        /// This token's start, as an index into the `Character` array `tokenise` walks — lets a
        /// caller splice the original source losslessly (`rewritingIdentifiers`) instead of
        /// re-deriving formatting the scanner never tried to preserve.
        let start: Int
    }

    /// MSL keywords, type names, qualifiers and the stdlib functions a formula may call.
    /// An identifier in this set is never a socket.
    public static let reservedNames: Set<String> = [
        // keywords and qualifiers
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case",
        "default", "const", "constexpr", "static", "struct", "using", "namespace", "true", "false",
        "thread", "device", "constant", "threadgroup", "inline", "auto", "void",
        // scalar and vector types
        "bool", "char", "short", "int", "uint", "long", "half", "float", "double",
        "bool2", "bool3", "bool4", "int2", "int3", "int4", "uint2", "uint3", "uint4",
        "half2", "half3", "half4", "float2", "float3", "float4",
        "float2x2", "float3x3", "float4x4", "half2x2", "half3x3", "half4x4",
        "texture2d", "sampler",
        // the stdlib subset a shader author reaches for
        "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp", "cos", "cosh", "cross",
        "degrees", "distance", "dot", "exp", "exp2", "faceforward", "floor", "fma", "fract",
        "length", "log", "log2", "max", "min", "mix", "mod", "modf", "normalize", "pow",
        "radians", "reflect", "refract", "round", "rsqrt", "saturate", "sign", "sin", "sinh",
        "smoothstep", "sqrt", "step", "tan", "tanh", "trunc", "isnan", "isinf", "select",
        // stdlib functions a one-liner reaches for (spec §27.3)
        "fmod", "fmin", "fmax", "fabs", "fwidth", "dfdx", "dfdy", "any", "all", "powr", "exp10",
        "log10", "rint", "sincos", "mad", "transpose", "determinant", "as_type", "ldexp", "frexp",
        "copysign", "nextafter", "fdim", "hypot", "precise", "fast",
        // constants and packed types
        "M_PI_F", "M_PI_2_F", "M_PI_4_F", "M_1_PI_F", "M_2_PI_F", "M_E_F", "M_LN2_F", "M_LN10_F",
        "M_SQRT2_F", "INFINITY", "NAN", "MAXFLOAT", "packed_float2", "packed_float3", "packed_float4",
        "packed_half2", "packed_half3", "packed_half4",
    ]

    /// `\r\n` and `\r` become `\n` before any scan. Swift folds `\r\n` into one `Character`, so a
    /// Windows-pasted body would otherwise be one giant line to `tokenise` and `stripComments`
    /// alike — every `Token.line` and `Violation.line` 0 (spec §25.2, handoff §15.5 item 6). Every
    /// entry point below scans the normalised copy; `LoopHardening.hardened` normalises its own
    /// copy the same way, because it splices by `Token.start` into *its* text and the two must
    /// agree. Cheap when there is nothing to do, which is the usual case.
    static func normalisedLineEndings(_ source: String) -> String {
        // `utf8`, not `contains("\r")`: a `\r\n` pair is *one* `Character`, so a `Character`-level
        // search for "\r" would miss exactly the input this function exists for.
        guard source.utf8.contains(0x0D) else { return source }
        return source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// A socket is never called: an identifier immediately followed by `(` is a function call,
    /// whatever its name — a builtin the list does not know, an `mn_` helper, a user's own function
    /// (spec §27.3). Comments and whitespace never produce tokens, so "immediately" is the next token.
    private static func isCall(_ tokens: [Token], at i: Int) -> Bool {
        i + 1 < tokens.count && tokens[i + 1].kind == .punctuation && tokens[i + 1].text == "("
    }

    /// A token is a free identifier — a socket, not a keyword/type/stdlib call, a swizzle/member,
    /// a name bound earlier in the same text, or itself a call — under exactly this rule.
    /// `identifiers(in:)` and `rewritingIdentifiers(in:with:)` both call this so the two can never
    /// disagree about which occurrences are free.
    private static func isFreeIdentifier(_ tokens: [Token], at i: Int, declared: Set<String>) -> Bool {
        let t = tokens[i]
        return t.kind == .identifier && !t.afterDot && !reservedNames.contains(t.text)
            && !declared.contains(t.text) && !isCall(tokens, at: i)
    }

    /// Free identifiers in first-appearance order: not reserved, not a member after `.`, not
    /// bound by a declaration earlier in the same text, and not called.
    public static func identifiers(in source: String) -> [String] {
        let tokens = tokenise(source)
        let declared = declaredLocals(tokens)
        var seen = Set<String>(), out: [String] = []
        for i in tokens.indices where isFreeIdentifier(tokens, at: i, declared: declared) {
            let t = tokens[i]
            if seen.insert(t.text).inserted { out.append(t.text) }
        }
        return out
    }

    /// The 0-based line each free identifier *first* appears on, keyed by name — the same
    /// occurrences `identifiers(in:)` names, by the same `isFreeIdentifier` rule, so a diagnostic
    /// about one of them can point at the user's own line rather than at no line at all.
    public static func identifierLines(in source: String) -> [String: Int] {
        let tokens = tokenise(source)
        let declared = declaredLocals(tokens)
        var out: [String: Int] = [:]
        for i in tokens.indices where isFreeIdentifier(tokens, at: i, declared: declared) {
            let t = tokens[i]
            if out[t.text] == nil { out[t.text] = t.line }
        }
        return out
    }

    /// Rewrites `source`, replacing every occurrence of a free identifier — exactly the token
    /// occurrences `identifiers(in:)` would name, by the same rule — with `replacement(name)`.
    /// Everything else passes through unchanged: punctuation, numbers, whitespace, comments, and
    /// crucially a member/swizzle access after `.` (`col.rgb` keeps its `.rgb`; only a *free*
    /// `col` before the dot is ever a candidate). Splicing the original characters around each
    /// substituted span — rather than re-joining tokens with synthesized spacing — is what keeps
    /// the untouched text byte-for-byte, which a whole-token regex on `\b` cannot do: `\b` is a
    /// Unicode word boundary, and `.` between two letters is *not* a break there, so `\bcol\b`
    /// never matches inside `col.rgb` at all (spec §24.2).
    /// The result uses `\n` line endings whatever the input used.
    static func rewritingIdentifiers(in source: String, with replacement: (String) -> String) -> String {
        let source = normalisedLineEndings(source)
        let chars = Array(source)
        let tokens = tokenise(source)
        let declared = declaredLocals(tokens)
        var out = ""
        var cursor = 0
        for i in tokens.indices where isFreeIdentifier(tokens, at: i, declared: declared) {
            let t = tokens[i]
            if t.start > cursor { out += String(chars[cursor..<t.start]) }
            out += replacement(t.text)
            cursor = t.start + t.text.count
        }
        if cursor < chars.count { out += String(chars[cursor...]) }
        return out
    }

    /// Dotted call chains rooted at a free identifier — `params.geometry().normal()` — the shape
    /// hand-written MSL uses to name an environment accessor (spec §24.5), read textually rather
    /// than through a `{sys.…}` placeholder. Each returned chain extends through every trailing
    /// `.name()` call and stops at the first `.name` that is not itself a call, so
    /// `params.geometry().normal().x` reports `params.geometry().normal()` — `.x` is a swizzle on
    /// the result, not another accessor segment. A bare identifier with no call at all (`in_a`) is
    /// not an accessor and is not reported.
    public static func accessorCalls(in source: String) -> [String] {
        accessorCallSites(in: source).map(\.chain)
    }

    /// `accessorCalls(in:)` with the 0-based line each chain's root identifier sits on, so a
    /// diagnostic about a chain can land on the user's own line. One scan serves both — the two
    /// can never disagree about what counts as a chain.
    public static func accessorCallSites(in source: String) -> [(chain: String, line: Int)] {
        let tokens = tokenise(source)
        var out: [(chain: String, line: Int)] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard t.kind == .identifier, !t.afterDot else { i += 1; continue }
            var text = t.text
            var j = i + 1
            var matchedAny = false
            while j + 3 < tokens.count,
                  tokens[j].kind == .punctuation, tokens[j].text == ".",
                  tokens[j + 1].kind == .identifier,
                  tokens[j + 2].kind == .punctuation, tokens[j + 2].text == "(",
                  tokens[j + 3].kind == .punctuation, tokens[j + 3].text == ")" {
                text += ".\(tokens[j + 1].text)()"
                j += 4
                matchedAny = true
            }
            if matchedAny {
                out.append((chain: text, line: t.line))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// A name bound by `<type> <name>` earlier in the text is a local, not an input.
    private static func declaredLocals(_ tokens: [Token]) -> Set<String> {
        var out = Set<String>()
        for (i, t) in tokens.enumerated() where t.kind == .identifier && reservedNames.contains(t.text) {
            guard isTypeName(t.text), i + 1 < tokens.count else { continue }
            let next = tokens[i + 1]
            if next.kind == .identifier, !next.afterDot, !reservedNames.contains(next.text) {
                out.insert(next.text)
            }
        }
        return out
    }

    private static func isTypeName(_ s: String) -> Bool {
        s == "void" || s.hasPrefix("float") || s.hasPrefix("half") || s.hasPrefix("int")
            || s.hasPrefix("uint") || s.hasPrefix("bool") || s == "auto" || s == "short"
            || s == "long" || s == "char" || s == "double"
            || s.hasPrefix("packed_float") || s.hasPrefix("packed_half")
    }

    /// A bounded, insertion-ordered memo. Content-keyed, so a document reload needs no
    /// invalidation; bounded, so an editing session cannot grow it without limit (spec §25.3).
    struct ScanCache<Value> {
        let capacity: Int
        private var order: [String] = []
        private var values: [String: Value] = [:]

        init(capacity: Int) { self.capacity = capacity }

        var count: Int { values.count }

        /// Whether `key` is currently held — the test probe for "served from the cache".
        func contains(_ key: String) -> Bool { values[key] != nil }

        mutating func value(for key: String, compute: () -> Value) -> Value {
            if let hit = values[key] { return hit }
            let v = compute()
            values[key] = v
            order.append(key)
            if order.count > capacity {
                values[order.removeFirst()] = nil
            }
            return v
        }
    }

    /// `scopeBreakers` memoised per body text. ~600 ns per character over three passes, re-paid on
    /// every debounced recompile for every authored body (handoff §15.5 item 11); with this only
    /// the edited body is scanned again. Sixty-four entries covers more definitions than any
    /// document has held; the lock is uncontended in practice (validation runs on one task).
    private static let scopeBreakerCache = Mutex(ScanCache<[Violation]>(capacity: 64))

    public static func scopeBreakers(in source: String) -> [Violation] {
        scopeBreakerCache.withLock { cache in
            cache.value(for: source) { uncachedScopeBreakers(in: source) }
        }
    }

    /// Whether a body's scan is currently memoised. Deterministic, unlike timing the second scan.
    static func isScopeBreakerScanCached(_ source: String) -> Bool {
        scopeBreakerCache.withLock { $0.contains(source) }
    }

    private static func uncachedScopeBreakers(in source: String) -> [Violation] {
        let source = normalisedLineEndings(source)
        var out: [Violation] = []
        let uncommented = stripComments(source)
        for (i, raw) in uncommented.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let name = line.dropFirst().prefix { $0.isLetter }
            out.append(Violation(kind: .preprocessor(String(name)), line: i))
        }
        let tokens = tokenise(source)
        var depth = 0, unbalancedAt: Int?
        for t in tokens where t.kind == .punctuation {
            if t.text == "{" { depth += 1 }
            if t.text == "}" {
                depth -= 1
                if depth < 0, unbalancedAt == nil { unbalancedAt = t.line }
            }
        }
        if depth != 0 || unbalancedAt != nil {
            out.append(Violation(kind: .unbalancedBrace, line: unbalancedAt ?? (tokens.last?.line ?? 0)))
        }
        for t in tokens where t.kind == .identifier && t.text == "return" && !t.afterDot {
            out.append(Violation(kind: .bareReturn, line: t.line))
        }
        // Run over the same comment-blanked text the preprocessor check uses, so a `{` that only
        // exists inside a comment can never read as the brace this loop is missing.
        for opener in loopOpeners(tokenise(uncommented)) where !opener.isBraced {
            out.append(Violation(kind: .unbracedLoopBody, line: opener.line))
        }
        return out.sorted { $0.line < $1.line }
    }

    /// A `for`, non-closing `while`, or `do` that opens a loop: its line, its keyword's index in
    /// the token array, and the index of the `{` opening its body — `nil` for an unbraced body.
    /// Internal so `LoopHardening` splices by these indices instead of re-deriving them (spec
    /// §25.3, handoff §15.5 item 13).
    struct LoopOpener {
        let line: Int
        let keywordIndex: Int
        let braceIndex: Int?
        let isDo: Bool
        var isBraced: Bool { braceIndex != nil }
    }

    /// Every loop-opening `for`/`while`/`do` in `tokens`, in the order encountered, alongside
    /// where each one's body brace is. A `do`'s own closing `while` is excluded: it is
    /// recognised by brace depth, not by simple order — each `do` that opens a `{ … }` body is
    /// paired with the `while` that follows once that block's closing `}` has brought the brace
    /// depth back down to where the `do` was seen. That is what keeps a *nested*
    /// `do { do { } while (a); } while (b);` from reporting the outer closing `while` as a third,
    /// spurious opener.
    ///
    /// A `do` whose body is a single statement with no braces is a known gap in that pairing:
    /// there is no brace event to pair it against, so its closing `while` is matched as soon as
    /// one is seen — which can swallow a genuine nested loop as if it were that `while`. This is
    /// not chased further, because doing so turns a token scanner into a parser (spec §24.4); it
    /// is closed instead by `scopeBreakers` refusing every unbraced loop body outright — see
    /// `loopSites`.
    static func loopOpeners(_ tokens: [Token]) -> [LoopOpener] {
        struct DoFrame { var closeDepth: Int; var satisfied: Bool }
        var out: [LoopOpener] = []
        var depth = 0
        var doStack: [DoFrame] = []
        for (i, t) in tokens.enumerated() {
            if t.kind == .punctuation {
                if t.text == "{" {
                    depth += 1
                } else if t.text == "}" {
                    depth -= 1
                    if let top = doStack.last, !top.satisfied, depth == top.closeDepth {
                        doStack[doStack.count - 1].satisfied = true
                    }
                }
                continue
            }
            guard t.kind == .identifier, !t.afterDot else { continue }
            switch t.text {
            case "for":
                out.append(LoopOpener(line: t.line, keywordIndex: i,
                                      braceIndex: bracedHeaderBraceIndex(tokens, headerStart: i + 1), isDo: false))
            case "do":
                let braced = i + 1 < tokens.count && tokens[i + 1].kind == .punctuation
                    && tokens[i + 1].text == "{"
                doStack.append(DoFrame(closeDepth: depth, satisfied: !braced))
                out.append(LoopOpener(line: t.line, keywordIndex: i, braceIndex: braced ? i + 1 : nil, isDo: true))
            case "while":
                if let top = doStack.last, top.satisfied {
                    doStack.removeLast()
                } else {
                    out.append(LoopOpener(line: t.line, keywordIndex: i,
                                          braceIndex: bracedHeaderBraceIndex(tokens, headerStart: i + 1), isDo: false))
                }
            default: break
            }
        }
        return out
    }

    /// The token index of the `{` that follows a parenthesized `( … )` header starting at
    /// `tokens[headerStart]` (tracking nested parens, so a call like `length(v)` inside a `for`'s
    /// condition doesn't close it early), or `nil` when the header is missing or unbraced.
    static func bracedHeaderBraceIndex(_ tokens: [Token], headerStart: Int) -> Int? {
        guard headerStart < tokens.count, tokens[headerStart].kind == .punctuation,
              tokens[headerStart].text == "(" else { return nil }
        var depth = 0
        var i = headerStart
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "(" {
                    depth += 1
                } else if t.text == ")" {
                    depth -= 1
                    if depth == 0 {
                        let next = i + 1
                        if next < tokens.count, tokens[next].kind == .punctuation, tokens[next].text == "{" {
                            return next
                        }
                        return nil
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// The 0-based line of every `for`, `while` or `do` that opens a loop. A `while` that closes a
    /// `do` is not a separate site — hardening the `do` covers it.
    ///
    /// Every reported site opens a *braced* loop body, unconditionally: an unbraced opener is
    /// filtered out here as well as being refused by `scopeBreakers` as `.unbracedLoopBody`, so
    /// neither path can hand a caller a site with no body to insert a guard into. (In practice the
    /// two are indistinguishable, since codegen only runs on a document `scopeBreakers` has already
    /// validated — but the guarantee does not depend on that call order; it holds for this function
    /// on its own.)
    public static func loopSites(in source: String) -> [Int] {
        loopOpeners(tokenise(source)).filter(\.isBraced).map(\.line).sorted()
    }

    /// The end (exclusive) of the comment that starts at `chars[i]`, or `nil` when no comment
    /// starts there. A `//` comment ends at its newline, which is *not* consumed — both callers
    /// need it, one to count and one to keep. A `/* … */` comment ends after its `*/`, or at the
    /// text's end when unterminated. One routine, two readers (spec §25.3, handoff §15.5 item 14):
    /// `tokenise` skips the span, `stripComments` blanks it.
    private static func commentEnd(at i: Int, in chars: [Character]) -> Int? {
        guard chars[i] == "/", i + 1 < chars.count else { return nil }
        if chars[i + 1] == "/" {
            var j = i + 2
            while j < chars.count, chars[j] != "\n" { j += 1 }
            return j
        }
        if chars[i + 1] == "*" {
            var j = i + 2
            while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
            return min(j + 2, chars.count)
        }
        return nil
    }

    /// Blanks `//` and `/* … */` comment *content* to spaces while leaving every newline in place,
    /// so a caller that scans the result line by line still sees the user's own line numbers. Used
    /// by `scopeBreakers` so a preprocessor directive is recognised (or excused) exactly where MSL
    /// itself would: comments are gone before directive lines are read, in either direction — a
    /// same-line `/* note */ #include <x>` is a real directive, and a `#include` sitting inside a
    /// multi-line `/* … */` block is not.
    ///
    /// MSL has no string literal type, so unlike `tokenise` this pass does not special-case quoted
    /// text — a `//` or `/*` inside a `"…"` cannot arise in a shader body.
    static func stripComments(_ source: String) -> String {
        var out = ""
        let chars = Array(normalisedLineEndings(source))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let end = commentEnd(at: i, in: chars) {
                for k in i..<end { out.append(chars[k] == "\n" ? "\n" : " ") }
                i = end
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// `tokenise` memoised per source text (spec §27.3): every entry point over one body —
    /// identifiers, lines, accessor call sites, scope breakers, loop sites — shares the one hit.
    private static let tokenCache = Mutex(ScanCache<[Token]>(capacity: 64))

    static func tokenise(_ source: String) -> [Token] {
        tokenCache.withLock { $0.value(for: source) { uncachedTokenise(source) } }
    }

    static func isTokeniseCached(_ source: String) -> Bool {
        tokenCache.withLock { $0.contains(source) }
    }

    /// One pass: identifiers, numbers and punctuation, with `//` and `/* */` comments and string
    /// literals skipped so a brace inside either never counts.
    private static func uncachedTokenise(_ source: String) -> [Token] {
        var out: [Token] = []
        var line = 0, afterDot = false
        let chars = Array(normalisedLineEndings(source))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if let end = commentEnd(at: i, in: chars) {
                line += chars[i..<end].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                i = end
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c.isWhitespace { i += 1; continue }
            if (c.isASCII && c.isLetter) || c == "_" {
                let start = i
                var s = ""
                while i < chars.count, (chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber)) || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .identifier, text: s, line: line, afterDot: afterDot, start: start))
                afterDot = false
                continue
            }
            if c.isNumber {
                let start = i
                var s = ""
                let isHex = c == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X")
                if isHex {
                    s.append(chars[i]); s.append(chars[i + 1]); i += 2
                    while i < chars.count, chars[i].isHexDigit || chars[i] == "." || chars[i] == "p" || chars[i] == "P"
                        || ((chars[i] == "-" || chars[i] == "+") && (s.last == "p" || s.last == "P")) {
                        s.append(chars[i]); i += 1
                    }
                } else {
                    while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E"
                        || ((chars[i] == "-" || chars[i] == "+") && (s.last == "e" || s.last == "E")) {
                        s.append(chars[i]); i += 1
                    }
                }
                // MSL's suffixes (`1u`, `0.5h`, `2.0f`, `3l`) belong to the literal, not to a following name.
                while i < chars.count, "uUhHfFlL".contains(chars[i]) {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .number, text: s, line: line, afterDot: false, start: start))
                afterDot = false
                continue
            }
            out.append(Token(kind: .punctuation, text: String(c), line: line, afterDot: false, start: i))
            afterDot = (c == ".")
            i += 1
        }
        return out
    }
}
