import Foundation
import CoreGraphics

/// Which graph the canvas is bound to.
public enum GraphPath: Hashable, Codable, Sendable {
    case root
    case definition(GroupID)
}

public struct Camera: Codable, Sendable, Hashable {
    public var pan: CGSize
    public var zoom: CGFloat
    public init(pan: CGSize = .zero, zoom: CGFloat = 1) { self.pan = pan; self.zoom = zoom }
}

/// Persisted next to the document, never part of an undo snapshot (spec §3, §5).
public struct EditorViewState: Codable, Sendable, Hashable {
    public var cameras: [GraphPath: Camera] = [:]
    public var editingStack: [NodeID] = []
    public var viewer: SocketRef? = nil
    public var selection: Set<NodeID> = []
    public init() {}
}
