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
    /// each loop, a check-and-break as its body's first statement, and — when the loop sits in an
    /// unbraced statement slot — a pair of wrapping braces), so a flat line offset cannot describe
    /// the correspondence between emitted and user lines; this array is exact for every emitted
    /// line, including a line that is only a fragment of one user line (a loop header and its `{`
    /// commonly share a user line with the rest of the body, since nothing in the spec requires a
    /// loop to be formatted across multiple lines — see `loopBraceSites` below).
    ///
    /// Consumed by `GroupCodegen`'s `.msl` branch via `SourceBuilder.add(userText:origins:…)`,
    /// which maps compiler diagnostics back to the user's own line numbers (spec §24.4, Task 9).
    public static func hardened(_ text: String) -> (text: String, userLines: [Int?]) {
        // Normalised once, here, on the way into the *generated* copy only — `text` as stored in
        // the document and shown by the editor is never touched (a caller keeps its own copy).
        // Both this function and `MSLScanner.tokenise` split on `Character("\n")`, and Swift folds
        // a `\r\n` pair into one `Character` (grapheme cluster): a body pasted from a Windows
        // editor would otherwise read as a single giant line below, so `userLines.count` would be
        // the Swift-level line count rather than the physical line count Metal's compiler reports
        // errors against — silently misattributing every diagnostic inside it (Task 9). MSL treats
        // `\n` and `\r\n` as equivalent line terminators, so this changes nothing about what
        // compiles.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sites = loopBraceSites(in: text)
        guard !sites.isEmpty else { return (text, (0..<rawLines.count).map { $0 }) }

        let lineStarts = lineStartOffsets(text)
        // Column-tagged insertions, grouped by the original line each one falls on, with an
        // explicit tie-break for two insertions the same site places at the same column (the
        // wrapping `{` and the counter declaration both land immediately before the loop
        // keyword). A line can also carry cuts from more than one *site* — e.g. two loops opening
        // on the same physical line — each independently a (column, order, text) triple.
        var cutsByLine: [Int: [(col: Int, order: Int, insert: String)]] = [:]
        for (i, site) in sites.enumerated() {
            let guardName = "mn_loopGuard\(i)"
            let (declLine, declCol) = location(of: site.keywordStart, lineStarts: lineStarts)
            let (checkLine, checkCol) = location(of: site.braceEnd, lineStarts: lineStarts)
            let indent = String(rawLines[declLine].prefix { $0 == " " || $0 == "\t" })
            if let wrapCloseOffset = site.wrapCloseOffset {
                // The loop is the single unbraced statement of an enclosing `if`/`else`/`case`
                // (the token immediately before its keyword is not `;`, `{` or `}`). Splicing the
                // declaration there without a scope of its own would either steal that statement
                // slot (a syntax error the moment there's more than one statement to place) or,
                // inside a `switch`, jump over the declaration's initialization from another case
                // label (invalid in MSL's C++-family grammar) — see fix round 1. Wrapping the
                // whole loop statement in its own `{ … }` gives the declaration a scope that ends
                // before control could ever jump around it, and is legal to add here precisely
                // because nothing about *placement* needs parsing — brace-matching the loop body
                // is already what this file does for `do`/`while` pairing.
                cutsByLine[declLine, default: []].append((declCol, 0, "\(indent){"))
                cutsByLine[declLine, default: []].append((declCol, 1, "\(indent)int \(guardName) = 0;"))
                let (wrapLine, wrapCol) = location(of: wrapCloseOffset, lineStarts: lineStarts)
                let wrapIndent = String(rawLines[wrapLine].prefix { $0 == " " || $0 == "\t" })
                cutsByLine[wrapLine, default: []].append((wrapCol, 0, "\(wrapIndent)}"))
            } else {
                // Declared immediately before the loop statement, once — never inside the body,
                // where it would reset to 0 on every iteration and the cap would never bite.
                cutsByLine[declLine, default: []].append((declCol, 0, "\(indent)int \(guardName) = 0;"))
            }
            // The check is spliced right after the body's opening `{`, so it runs as the body's
            // first statement on every iteration, for `for`, `while` and `do` alike — this works
            // uniformly because `MSLScanner.loopSites`' guarantee means that brace is always on
            // the same line as the opener, whether or not the rest of the body shares that line.
            cutsByLine[checkLine, default: []].append((checkCol, 0, "\(indent)    if (++\(guardName) > \(cap)) { break; }"))
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
            let sorted = cuts.sorted { $0.col != $1.col ? $0.col < $1.col : $0.order < $1.order }
            for cut in sorted {
                let col = min(max(cut.col, cursor), chars.count)
                let prefix = String(chars[cursor..<col])
                if prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Nothing but whitespace between the last emission and this insertion point
                    // (the ordinary case: a loop opener indented on its own line). Don't emit it
                    // as an orphaned line, and — this is the fix for the indentation-loss defect
                    // flagged in fix round 1 — don't consume it either: leaving `cursor` where it
                    // is lets that whitespace carry over as the leading indentation of whatever
                    // code follows this insertion, rather than being flushed left.
                } else {
                    outLines.append(prefix)
                    userLines.append(i)
                    cursor = col
                }
                outLines.append(cut.insert)
                userLines.append(nil)
            }
            appendFragment(String(chars[cursor...]), line: i, to: &outLines, &userLines)
        }
        return (outLines.joined(separator: "\n"), userLines)
    }

    public static func harden(_ text: String) -> String { hardened(text).text }

    /// Skips a fragment that is empty or pure whitespace — it carries no code, so recording it as
    /// its own emitted (and user-attributed) line would only add clutter, not information the
    /// next task's error-line mapping could use. Only used for the trailing remainder of a line
    /// after its last insertion, where there is no following fragment left to carry it into.
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

    /// One loop opener: the character offset of its keyword (`for`/`while`/`do`), the offset
    /// right after the `{` that opens its body, and — only when the loop sits in an unbraced
    /// statement slot — the offset right after the loop *statement* ends, where a wrapping `}`
    /// must close the scope opened before the keyword.
    private struct Site {
        let keywordStart: Int
        let braceEnd: Int
        let wrapCloseOffset: Int?
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
                if let braceIndex = bracedHeaderBraceIndex(tokens, headerStart: i + 1) {
                    out.append(makeSite(tokens, keywordIndex: i, braceIndex: braceIndex, isDo: false))
                }
            case "do":
                let braced = i + 1 < tokens.count && tokens[i + 1].kind == .punctuation
                    && tokens[i + 1].text == "{"
                doStack.append(DoFrame(closeDepth: depth, satisfied: !braced))
                if braced {
                    out.append(makeSite(tokens, keywordIndex: i, braceIndex: i + 1, isDo: true))
                }
            case "while":
                if let top = doStack.last, top.satisfied {
                    doStack.removeLast()
                } else if let braceIndex = bracedHeaderBraceIndex(tokens, headerStart: i + 1) {
                    out.append(makeSite(tokens, keywordIndex: i, braceIndex: braceIndex, isDo: false))
                }
            default: break
            }
            i += 1
        }
        return out
    }

    /// Builds one `Site`, resolving `wrapCloseOffset` only when the loop keyword needs wrapping
    /// (fix round 1): the token immediately before it is anything other than `;`, `{` or `}`,
    /// meaning the loop is sitting in a slot that grammatically allows exactly one statement (an
    /// `if`/`else` body, or after a `case`/`default:` label with nothing braced around it) rather
    /// than being one statement among a block's several.
    private static func makeSite(_ tokens: [MSLScanner.Token], keywordIndex: Int, braceIndex: Int,
                                  isDo: Bool) -> Site {
        let keyword = tokens[keywordIndex]
        let braceEnd = tokens[braceIndex].start + 1
        guard needsWrapping(tokens, keywordIndex: keywordIndex) else {
            return Site(keywordStart: keyword.start, braceEnd: braceEnd, wrapCloseOffset: nil)
        }
        guard let closeIndex = matchingCloseIndex(tokens, openIndex: braceIndex) else {
            return Site(keywordStart: keyword.start, braceEnd: braceEnd, wrapCloseOffset: nil)
        }
        // For `for`/`while` the statement ends at the body's own closing `}`. A `do` isn't done
        // there: the statement is `do { … } while (…);` as a whole, so the wrap must close after
        // that trailing `;`, not after the body — closing early would leave `while (…);` outside
        // the wrap, attached to nothing.
        let wrapClose = isDo ? afterDoWhileSemicolon(tokens, bodyCloseIndex: closeIndex)
                             : tokens[closeIndex].start + 1
        return Site(keywordStart: keyword.start, braceEnd: braceEnd, wrapCloseOffset: wrapClose)
    }

    /// True when the token immediately preceding `tokens[keywordIndex]` is not a statement
    /// boundary (`;`, `{`, `}`) — i.e. the loop is the unbraced single statement of an enclosing
    /// `if`/`else`/`case`, and its counter declaration needs a scope of its own (fix round 1). No
    /// preceding token at all (the loop opens the whole custom-code body) needs no wrapping: that
    /// text is always spliced inside the enclosing function's own braces.
    private static func needsWrapping(_ tokens: [MSLScanner.Token], keywordIndex: Int) -> Bool {
        let j = keywordIndex - 1
        guard j >= 0 else { return false }
        let prev = tokens[j]
        if prev.kind == .punctuation, prev.text == ";" || prev.text == "{" || prev.text == "}" {
            return false
        }
        return true
    }

    /// The token index of the `}` that matches the `{` at `tokens[openIndex]`.
    private static func matchingCloseIndex(_ tokens: [MSLScanner.Token], openIndex: Int) -> Int? {
        var depth = 0
        var i = openIndex
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "{" { depth += 1 }
                else if t.text == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// The character offset right after the `;` that terminates a `do { … } while (…);` whose
    /// body closes at `tokens[bodyCloseIndex]`. Falls back to right after that closing `}` if the
    /// expected `while (…);` tail isn't found — malformed input outside anything this scanner is
    /// asked to parse, and it fails as a real MSL compile error either way, not silently.
    private static func afterDoWhileSemicolon(_ tokens: [MSLScanner.Token], bodyCloseIndex: Int) -> Int {
        let fallback = tokens[bodyCloseIndex].start + 1
        var i = bodyCloseIndex + 1
        guard i < tokens.count, tokens[i].kind == .identifier, tokens[i].text == "while" else { return fallback }
        i += 1
        guard i < tokens.count, tokens[i].kind == .punctuation, tokens[i].text == "(" else { return fallback }
        var depth = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "(" { depth += 1 }
                else if t.text == ")" {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
            }
            i += 1
        }
        if i < tokens.count, tokens[i].kind == .punctuation, tokens[i].text == ";" {
            return tokens[i].start + 1
        }
        return fallback
    }

    /// The character offset of the `{` that follows a parenthesized `(…)` header starting at
    /// `tokens[headerStart]` (tracking nested parens, so a call like `length(v)` inside the
    /// condition doesn't close the header early), or `nil` if none follows. An unbraced loop body
    /// never reaches here in practice — `scopeBreakers` refuses it before codegen runs — but this
    /// returns `nil` rather than guessing if it ever were.
    private static func bracedHeaderBraceIndex(_ tokens: [MSLScanner.Token], headerStart: Int) -> Int? {
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
}
