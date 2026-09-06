import Foundation

/// The system pasteboard behind a protocol so paste is testable in memory (spec §18.4).
@MainActor
public protocol Pasteboarding: AnyObject {
    func write(_ data: Data, type: String)
    func read(type: String) -> Data?
}

@MainActor
public final class MemoryPasteboard: Pasteboarding {
    private var items: [String: Data] = [:]
    public init() {}
    public func write(_ data: Data, type: String) { items = [type: data] }
    public func read(type: String) -> Data? { items[type] }
}
