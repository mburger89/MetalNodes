import Foundation

/// Maps 1-based lines of generated source back to the node that produced them (spec §9.4).
public struct LineMap: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let range: ClosedRange<Int>
        public let node: NodeID
    }
    public var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    public func node(forLine line: Int) -> NodeID? {
        entries.first { $0.range.contains(line) }?.node
    }

    public func lines(for node: NodeID) -> [ClosedRange<Int>] {
        entries.filter { $0.node == node }.map(\.range)
    }

    /// Generated lines that came from text the user typed — an Expression's formula or a Custom
    /// MSL definition's body (spec §24.4). Kept separate from `entries` rather than folded in as
    /// an optional field: `Entry.node` is a non-optional `NodeID`, and a definition's body belongs
    /// to no node instance at all, so it cannot be represented as one.
    public struct UserEntry: Sendable, Hashable {
        public let range: ClosedRange<Int>
        /// For each line of `range`, the 0-based line of the user's own text it came from — `nil`
        /// for a line `LoopHardening` inserted.
        public let userLines: [Int?]
        /// The Expression node this text belongs to, or `nil` when it is a definition's body.
        public let node: NodeID?
        /// The Custom MSL definition this text belongs to, or `nil` for an Expression.
        public let definition: GroupID?

        public init(range: ClosedRange<Int>, userLines: [Int?], node: NodeID? = nil, definition: GroupID? = nil) {
            self.range = range; self.userLines = userLines; self.node = node; self.definition = definition
        }
    }
    public var userEntries: [UserEntry] = []

    /// The 1-based line of the user's own text that generated `line`, or `nil` when `line` did not
    /// come from user-authored code (scaffolding the emitter wrote, or a line `LoopHardening`
    /// inserted).
    ///
    /// **Numbering obligation for any consumer that shows this against the user's own text (e.g. a
    /// code editor's gutter):** this number counts *physical* lines, because `LoopHardening.hardened`
    /// normalises `\r\n`/`\r` to `\n` before splitting — Swift folds a `\r\n` pair into a single
    /// `Character`, so counting on the raw stored text would undercount. `GroupDefinition.body`
    /// itself is never rewritten (only the generated copy is), so it still stores whatever line
    /// endings the user pasted. A consumer that numbers the editor's own gutter by splitting
    /// `body`'s raw string on `"\n"` will therefore disagree with this method for a CRLF body,
    /// unless it normalises identically first (spec §24.4, Task 9).
    public func userLine(forLine line: Int) -> Int? {
        for e in userEntries where e.range.contains(line) {
            let i = line - e.range.lowerBound
            guard i >= 0, i < e.userLines.count, let u = e.userLines[i] else { return nil }
            return u + 1   // report 1-based, as compilers do
        }
        return nil
    }

    /// Which definition's body `line` came from, so the code editor can list only its own errors
    /// (Task 17). `nil` when `line` is not inside any Custom MSL definition's body.
    public func definition(forLine line: Int) -> GroupID? {
        userEntries.first { $0.range.contains(line) }?.definition
    }
}
