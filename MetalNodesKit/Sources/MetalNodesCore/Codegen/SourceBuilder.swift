import Foundation

/// Accumulates generated source and the node that owns each line (spec §9.4).
struct SourceBuilder {
    private(set) var text = ""
    private(set) var map = LineMap()
    private var nextLine = 1

    /// Appends `chunk` plus a trailing newline. Multi-line chunks attribute every line to `owner`;
    /// consecutive lines with the same owner merge into one `LineMap` entry.
    mutating func add(_ chunk: String, owner: NodeID? = nil) {
        let count = chunk.split(separator: "\n", omittingEmptySubsequences: false).count
        let first = nextLine, last = nextLine + count - 1
        nextLine += count
        text += chunk + "\n"
        guard let owner else { return }
        if let prev = map.entries.last, prev.node == owner, prev.range.upperBound == first - 1 {
            map.entries[map.entries.count - 1] = LineMap.Entry(range: prev.range.lowerBound...last, node: owner)
        } else {
            map.entries.append(LineMap.Entry(range: first...last, node: owner))
        }
    }
}
