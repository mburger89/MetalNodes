import Foundation

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

    struct Token: Equatable {
        enum Kind: Equatable { case identifier, number, punctuation }
        let kind: Kind
        let text: String
        let line: Int
        /// True when the previous non-space token was `.`, so this is a member or swizzle.
        let afterDot: Bool
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
    ]

    /// Free identifiers in first-appearance order: not reserved, not a member after `.`, and not
    /// bound by a declaration earlier in the same text.
    public static func identifiers(in source: String) -> [String] {
        let tokens = tokenise(source)
        let declared = declaredLocals(tokens)
        var seen = Set<String>(), out: [String] = []
        for t in tokens where t.kind == .identifier && !t.afterDot {
            guard !reservedNames.contains(t.text), !declared.contains(t.text) else { continue }
            if seen.insert(t.text).inserted { out.append(t.text) }
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
    }

    public static func scopeBreakers(in source: String) -> [Violation] {
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

    /// A `for`, non-closing `while`, or `do` that opens a loop, and whether its body is a braced
    /// `{ … }` block.
    private struct LoopOpener {
        let line: Int
        let isBraced: Bool
    }

    /// Every loop-opening `for`/`while`/`do` in `tokens`, in the order encountered, alongside
    /// whether each one's body is braced. A `do`'s own closing `while` is excluded: it is
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
    private static func loopOpeners(_ tokens: [Token]) -> [LoopOpener] {
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
                let braced = isBracedAfterParenthesizedHeader(tokens, headerStart: i + 1)
                out.append(LoopOpener(line: t.line, isBraced: braced))
            case "do":
                let braced = i + 1 < tokens.count && tokens[i + 1].kind == .punctuation
                    && tokens[i + 1].text == "{"
                doStack.append(DoFrame(closeDepth: depth, satisfied: !braced))
                out.append(LoopOpener(line: t.line, isBraced: braced))
            case "while":
                if let top = doStack.last, top.satisfied {
                    doStack.removeLast()
                } else {
                    let braced = isBracedAfterParenthesizedHeader(tokens, headerStart: i + 1)
                    out.append(LoopOpener(line: t.line, isBraced: braced))
                }
            default: break
            }
        }
        return out
    }

    /// True when `tokens[headerStart]` opens a `( … )` clause (tracking nested parens, so a call
    /// like `length(v)` inside a `for`'s condition doesn't close it early) and the token right
    /// after its matching `)` is `{`.
    private static func isBracedAfterParenthesizedHeader(_ tokens: [Token], headerStart: Int) -> Bool {
        guard headerStart < tokens.count, tokens[headerStart].kind == .punctuation,
              tokens[headerStart].text == "(" else { return false }
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
                        return next < tokens.count && tokens[next].kind == .punctuation
                            && tokens[next].text == "{"
                    }
                }
            }
            i += 1
        }
        return false
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

    /// Blanks `//` and `/* … */` comment *content* to spaces while leaving every newline in place,
    /// so a caller that scans the result line by line still sees the user's own line numbers. Used
    /// by `scopeBreakers` so a preprocessor directive is recognised (or excused) exactly where MSL
    /// itself would: comments are gone before directive lines are read, in either direction — a
    /// same-line `/* note */ #include <x>` is a real directive, and a `#include` sitting inside a
    /// multi-line `/* … */` block is not.
    ///
    /// MSL has no string literal type, so unlike `tokenise` this pass does not special-case quoted
    /// text — a `//` or `/*` inside a `"…"` cannot arise in a shader body.
    private static func stripComments(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    out.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                out.append(" ")
                out.append(" ")
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                let end = min(i + 2, chars.count)
                while i < end {
                    out.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// One pass: identifiers, numbers and punctuation, with `//` and `/* */` comments and string
    /// literals skipped so a brace inside either never counts.
    static func tokenise(_ source: String) -> [Token] {
        var out: [Token] = []
        var line = 0, afterDot = false
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i = min(i + 2, chars.count)
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
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .identifier, text: s, line: line, afterDot: afterDot))
                afterDot = false
                continue
            }
            if c.isNumber {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e"
                    || chars[i] == "E" || chars[i] == "f" || chars[i] == "F"
                    || (chars[i] == "-" && (s.last == "e" || s.last == "E")) {
                    s.append(chars[i]); i += 1
                }
                out.append(Token(kind: .number, text: s, line: line, afterDot: false))
                afterDot = false
                continue
            }
            out.append(Token(kind: .punctuation, text: String(c), line: line, afterDot: false))
            afterDot = (c == ".")
            i += 1
        }
        return out
    }
}
