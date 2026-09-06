import Foundation

/// Accumulates generated source and the node that owns each line (spec §9.4).
struct SourceBuilder {
    private(set) var text = ""
    private(set) var map = LineMap()
    private var nextLine = 1

    /// Appends `chunk` plus a trailing newline. Multi-line chunks attribute every line to `owner`;
    /// consecutive lines with the same owner merge into one `LineMap` entry.
    mutating func add(_ chunk: String, owner: NodeID? = nil) {
        let first = nextLine, last = append(chunk)
        guard let owner else { return }
        own(first...last, owner)
    }

    /// Appends `chunk` plus a trailing newline, carrying over `map` — a line map of `chunk`'s own
    /// 1-based lines, as produced by the builder that made it — shifted into this builder's
    /// numbering. Used to fold a group function's map into the program's (spec §9.4).
    mutating func add(_ chunk: String, map: LineMap) {
        let offset = nextLine - 1
        append(chunk)
        for e in map.entries { own((e.range.lowerBound + offset)...(e.range.upperBound + offset), e.node) }
    }

    /// Appends `chunk` plus a trailing newline; returns the last line number it occupies.
    @discardableResult private mutating func append(_ chunk: String) -> Int {
        let count = chunk.split(separator: "\n", omittingEmptySubsequences: false).count
        let last = nextLine + count - 1
        nextLine += count
        text += chunk + "\n"
        return last
    }

    private mutating func own(_ range: ClosedRange<Int>, _ owner: NodeID) {
        if let prev = map.entries.last, prev.node == owner, prev.range.upperBound == range.lowerBound - 1 {
            map.entries[map.entries.count - 1] = LineMap.Entry(range: prev.range.lowerBound...range.upperBound, node: owner)
        } else {
            map.entries.append(LineMap.Entry(range: range, node: owner))
        }
    }
}
