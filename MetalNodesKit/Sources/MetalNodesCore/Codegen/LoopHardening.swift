import Foundation

/// A seatbelt on emitted loops (spec §24.4). Nothing correct is refused: every loop form —
/// `for`, `while`, `do` — is allowed, including bounds that are parameters rather than literals.
/// The *emitted* text simply carries a per-loop counter and a `break`, so a runaway loop
/// terminates rather than hanging the GPU — which Metal's watchdog would otherwise kill, taking
/// the app with it.
///
/// The user's own text is never modified: `harden`/`hardened` run on the way into the generated
/// program, and the editor always shows exactly what was typed.
public enum LoopHardening {
    /// Deliberately generous: high enough that no plausible shader loop reaches it, low enough
    /// that hitting it costs milliseconds rather than a frozen device.
    public static let cap = 4096

    /// The hardened text plus, for each emitted line, the 0-based user line it came from — `nil`
    /// for a line the hardener inserted. Hardening *inserts* lines (a counter declaration before
    /// each loop, a check-and-break as its body's first statement), so a flat line offset cannot
    /// describe the correspondence between emitted and user lines; this array is exact for every
    /// emitted line, including a line that is only a fragment of one user line (a loop header and
    /// its `{` commonly share a user line with the rest of the body, since nothing in the spec
    /// requires a loop to be formatted across multiple lines — see `loopBraceSites` below).
    ///
    /// Not consumed by this task: the next task in this milestone maps compiler diagnostics back
    /// to the user's own line numbers and needs exactly this shape.
    public static func hardened(_ text: String) -> (text: String, userLines: [Int?]) {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sites = loopBraceSites(in: text)
        guard !sites.isEmpty else { return (text, (0..<rawLines.count).map { $0 }) }

        let lineStarts = lineStartOffsets(text)
        // Column-tagged insertions, grouped by the original line each one falls on. A line can
        // carry more than one — e.g. two loops opening on the same physical line — and each is
        // just a (column, text-to-insert) pair; `splice(_:with:)` below does the rest.
        var cutsByLine: [Int: [(col: Int, insert: String)]] = [:]
        for (i, site) in sites.enumerated() {
            let guardName = "mn_loopGuard\(i)"
            let (declLine, declCol) = location(of: site.keywordStart, lineStarts: lineStarts)
            let (checkLine, checkCol) = location(of: site.braceEnd, lineStarts: lineStarts)
            let indent = String(rawLines[declLine].prefix { $0 == " " || $0 == "\t" })
            // Declared immediately before the loop statement, once — never inside the body,
            // where it would reset to 0 on every iteration and the cap would never bite.
            cutsByLine[declLine, default: []].append((declCol, "\(indent)int \(guardName) = 0;"))
            // The check is spliced right after the body's opening `{`, so it runs as the body's
            // first statement on every iteration, for `for`, `while` and `do` alike — this works
            // uniformly because `MSLScanner.loopSites`' guarantee means that brace is always on
            // the same line as the opener, whether or not the rest of the body shares that line.
            cutsByLine[checkLine, default: []].append((checkCol, "\(indent)    if (++\(guardName) > \(cap)) { break; }"))
        }

        var outLines: [String] = []
        var userLines: [Int?] = []
        for (i, raw) in rawLines.enumerated() {
            guard let cuts = cutsByLine[i], !cuts.isEmpty else {
                outLines.append(raw)
                userLines.append(i)
                continue
            }
            let chars = Array(raw)
            var cursor = 0
            for cut in cuts.sorted(by: { $0.col < $1.col }) {
                let col = min(max(cut.col, cursor), chars.count)
                appendFragment(String(chars[cursor..<col]), line: i, to: &outLines, &userLines)
                outLines.append(cut.insert)
                userLines.append(nil)
                cursor = col
            }
            appendFragment(String(chars[cursor...]), line: i, to: &outLines, &userLines)
        }
        return (outLines.joined(separator: "\n"), userLines)
    }

    public static func harden(_ text: String) -> String { hardened(text).text }

    /// Skips a fragment that is empty or pure whitespace — it carries no code, so recording it as
    /// its own emitted (and user-attributed) line would only add clutter, not information the
    /// next task's error-line mapping could use.
    private static func appendFragment(_ fragment: String, line: Int, to outLines: inout [String],
                                        _ userLines: inout [Int?]) {
        guard !fragment.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        outLines.append(fragment)
        userLines.append(line)
    }

    /// The character offset (into `Array(text)`, matching `MSLScanner.Token.start`) where each
    /// line begins. `starts[0] == 0`; `starts.count` equals the number of lines `text` splits into.
    private static func lineStartOffsets(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for ch in text {
            offset += 1
            if ch == "\n" { starts.append(offset) }
        }
        return starts
    }

    /// The (line, column) a global character offset falls on, given `lineStartOffsets(_:)`'s result.
    private static func location(of offset: Int, lineStarts: [Int]) -> (line: Int, col: Int) {
        var line = 0
        for (i, start) in lineStarts.enumerated() where start <= offset { line = i }
        return (line, offset - lineStarts[line])
    }

    /// One loop opener: the character offset of its keyword (`for`/`while`/`do`) and the offset
    /// right after the `{` that opens its body.
    private struct Site {
        let keywordStart: Int
        let braceEnd: Int
    }

    /// Mirrors `MSLScanner`'s own (private) loop-opener detection — a `do`'s closing `while` is
    /// tracked by a brace-depth stack so it is never counted as a second, spurious opener — but
    /// additionally records the exact character offsets hardening needs to splice at.
    ///
    /// `MSLScanner.loopSites(in:)` only reports which *line* each opener is on. That is not
    /// enough here: every test in this suite, and the spec's own examples, write a loop's header
    /// and body on one physical line (`for (...) { body; }`), and a hardener that merely inserts
    /// a new line after that whole line would place its `break` *outside* the loop — which is not
    /// just a wrong cap, it is invalid MSL (`break` outside a loop or `switch` fails to compile).
    /// So this walks tokens itself rather than reusing that line-only API. `MSLScanner.swift`
    /// belongs to a different task in this milestone and is not modified here.
    private static func loopBraceSites(in source: String) -> [Site] {
        struct DoFrame { var closeDepth: Int; var satisfied: Bool }
        let tokens = MSLScanner.tokenise(source)
        var out: [Site] = []
        var depth = 0
        var doStack: [DoFrame] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "{" {
                    depth += 1
                } else if t.text == "}" {
                    depth -= 1
                    if let top = doStack.last, !top.satisfied, depth == top.closeDepth {
                        doStack[doStack.count - 1].satisfied = true
                    }
                }
                i += 1
                continue
            }
            guard t.kind == .identifier, !t.afterDot else { i += 1; continue }
            switch t.text {
            case "for":
                if let brace = bracedHeaderBrace(tokens, headerStart: i + 1) {
                    out.append(Site(keywordStart: t.start, braceEnd: brace + 1))
                }
            case "do":
                let braced = i + 1 < tokens.count && tokens[i + 1].kind == .punctuation
                    && tokens[i + 1].text == "{"
                doStack.append(DoFrame(closeDepth: depth, satisfied: !braced))
                if braced { out.append(Site(keywordStart: t.start, braceEnd: tokens[i + 1].start + 1)) }
            case "while":
                if let top = doStack.last, top.satisfied {
                    doStack.removeLast()
                } else if let brace = bracedHeaderBrace(tokens, headerStart: i + 1) {
                    out.append(Site(keywordStart: t.start, braceEnd: brace + 1))
                }
            default: break
            }
            i += 1
        }
        return out
    }

    /// The character offset of the `{` that follows a parenthesized `(…)` header starting at
    /// `tokens[headerStart]` (tracking nested parens, so a call like `length(v)` inside the
    /// condition doesn't close the header early), or `nil` if none follows. An unbraced loop body
    /// never reaches here in practice — `scopeBreakers` refuses it before codegen runs — but this
    /// returns `nil` rather than guessing if it ever were.
    private static func bracedHeaderBrace(_ tokens: [MSLScanner.Token], headerStart: Int) -> Int? {
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
                            return tokens[next].start
                        }
                        return nil
                    }
                }
            }
            i += 1
        }
        return nil
    }
}
