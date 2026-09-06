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
public struct EditorViewState: Sendable, Hashable {
    public var cameras: [GraphPath: Camera] = [:]
    /// The instances dived through, outermost first (spec §4.2, §20.3).
    public var editingStack: [NodeID] = []
    /// A definition opened from the palette with no instance (spec §20.3).
    public var editingDefinition: GroupID? = nil
    public var viewer: SocketRef? = nil
    /// How codegen reaches `viewer`, captured when it was set rather than read from the editing
    /// stack at compile time — popping out of a group keeps the viewer alive (spec §20.5).
    /// Empty and `nil` for a viewer in the root.
    public var viewerPath: [NodeID] = []
    public var viewerDefinition: GroupID? = nil
    public var selection: Set<NodeID> = []
    /// Comments have their own selection set, cleared together with the node selection (spec §21.4).
    public var selectedComments: Set<CommentID> = []
    /// View ▸ Generated Code (spec §21.5).
    public var showsCode = false
    /// View ▸ Minimap, on by default (spec §21.6).
    public var showsMinimap = true
    public init() {}

    /// The graph the editor is bound to: the last dived instance's definition, else the edited
    /// definition, else the root. A dangling stack entry falls back rather than trapping.
    public func activePath(in doc: ShaderDocument) -> GraphPath {
        if let last = editingStack.last, let (n, _) = doc.node(last), case .group(let gid) = n.kind, doc.definitions[gid] != nil {
            return .definition(gid)
        }
        if let d = editingDefinition, doc.definitions[d] != nil { return .definition(d) }
        return .root
    }
}

extension EditorViewState: Codable {
    private enum Keys: String, CodingKey {
        case cameras, editingStack, editingDefinition, viewer, viewerPath, viewerDefinition, selection
        case selectedComments, showsCode, showsMinimap
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cameras = try c.decodeIfPresent([GraphPath: Camera].self, forKey: .cameras) ?? [:]
        editingStack = try c.decodeIfPresent([NodeID].self, forKey: .editingStack) ?? []
        editingDefinition = try c.decodeIfPresent(GroupID.self, forKey: .editingDefinition)
        viewer = try c.decodeIfPresent(SocketRef.self, forKey: .viewer)
        viewerPath = try c.decodeIfPresent([NodeID].self, forKey: .viewerPath) ?? []
        viewerDefinition = try c.decodeIfPresent(GroupID.self, forKey: .viewerDefinition)
        selection = try c.decodeIfPresent(Set<NodeID>.self, forKey: .selection) ?? []
        selectedComments = try c.decodeIfPresent(Set<CommentID>.self, forKey: .selectedComments) ?? []
        showsCode = try c.decodeIfPresent(Bool.self, forKey: .showsCode) ?? false
        showsMinimap = try c.decodeIfPresent(Bool.self, forKey: .showsMinimap) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(cameras, forKey: .cameras); try c.encode(editingStack, forKey: .editingStack)
        try c.encodeIfPresent(editingDefinition, forKey: .editingDefinition)
        try c.encodeIfPresent(viewer, forKey: .viewer); try c.encode(viewerPath, forKey: .viewerPath)
        try c.encodeIfPresent(viewerDefinition, forKey: .viewerDefinition)
        try c.encode(selection, forKey: .selection)
        try c.encode(selectedComments, forKey: .selectedComments)
        try c.encode(showsCode, forKey: .showsCode); try c.encode(showsMinimap, forKey: .showsMinimap)
    }
}
