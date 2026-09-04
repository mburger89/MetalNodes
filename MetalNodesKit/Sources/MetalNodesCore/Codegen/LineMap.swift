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
}
