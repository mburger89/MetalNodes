import Foundation
import CoreGraphics
import MetalNodesCore

public enum ChangeClass: Sendable { case cosmetic, parameter, topology }

/// Every edit goes through one of these, which is what makes classification
/// (spec §10) a `switch` instead of a diff. Spec §18.2 lists the M2 set.
public enum DocumentChange: Sendable {
    case moveNodes([NodeID: CGPoint])
    case setParam(NodeID, ParamID, ParamValue)
    case setTitle(NodeID, String?)
    case connect(from: SocketRef, to: SocketRef)
    case disconnect(SocketRef)
    case addNode(NodeInstance)
    case removeNodes(Set<NodeID>)
    /// Paste / duplicate: the definitions the payload carries, then the nodes, then the wires
    /// among them, then the comments it brought, as one change (spec §20.7, §21.4). `assets` are
    /// the manifest entry and bytes for every asset the payload referenced that the source had
    /// bytes for (spec §13, §21.2); applying never overwrites an asset id the destination already has.
    case insert(nodes: [NodeInstance], edges: [Edge], definitions: [GroupDefinition] = [],
                assets: [AssetID: (info: AssetInfo, data: Data)] = [:],
                stickies: [StickyNote] = [], frames: [CommentFrame] = [])
    case setSettings(DocumentSettings)

    /// Adds a definition with no instance — the graph-definition half of Task 16's test fixture.
    /// A Custom MSL node's own creation goes through `.insert` instead, so its definition and its
    /// one instance land as a single undo step (spec §24.3, `EditorModel+Groups.swift`).
    case addDefinition(GroupDefinition)

    // MARK: Groups (spec §20.6)

    /// Folds the given nodes of the active graph into a fresh definition and its one instance.
    case groupSelection(Set<NodeID>, name: String?)
    case ungroup(NodeID)
    case makeUnique(NodeID)
    case renameDefinition(GroupID, String)
    case setDefinitionAccent(GroupID, DraculaAccent)
    case addSocket(GroupID, SocketKind, SocketDecl)
    case renameSocket(GroupID, SocketKind, from: String, to: String)
    case removeSocket(GroupID, SocketKind, String)
    case deleteDefinition(GroupID)
    /// Replaces a `.msl` definition's whole body text — the code editor's one write (spec §24.4,
    /// Task 17). Classified `.topology`, not `.parameter`: the body decides what the function
    /// computes and which identifiers it needs, not a tunable value inside an unchanged program.
    case setDefinitionBody(GroupID, String)

    // MARK: Comments (spec §21.4)

    case addSticky(StickyNote)
    case updateSticky(StickyID, text: String, accent: DraculaAccent)
    case addFrame(CommentFrame)
    case updateFrame(FrameID, title: String, accent: DraculaAccent)
    /// New origins, one drag frame at a time — the comment counterpart of `.moveNodes`.
    case moveComments([CommentID: CGPoint])
    case resizeComment(CommentID, CGRect)
    case removeComments(Set<CommentID>)

    /// Undo/redo only. Bypasses transactions; never registers an undo of its own.
    case restore(ShaderDocument)

    /// Spec §18.2. `.setSettings` is topology only when `fastMath`, `target`, or — under a
    /// stitchable target — `exportName` changes, and this cannot see the previous settings to tell
    /// — so it classifies as cosmetic and `EditorModel.perform` compares against the current
    /// document and schedules the recompile itself.
    public var changeClass: ChangeClass {
        switch self {
        // A definition's accent is a label; its *name* is part of the emitted function's
        // identifier (spec §20.4), so a rename changes the source and must rebuild (ruling R14).
        // Comments are document data but never reach codegen (spec §21.4).
        case .moveNodes, .setTitle, .setSettings, .setDefinitionAccent,
             .addSticky, .updateSticky, .addFrame, .updateFrame,
             .moveComments, .resizeComment, .removeComments: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNodes, .insert, .restore, .groupSelection, .ungroup,
             .makeUnique, .renameDefinition, .addSocket, .renameSocket, .removeSocket, .deleteDefinition,
             .addDefinition, .setDefinitionBody: .topology
        }
    }

    /// Whether this change can alter any `NodeShape` (spec §27.9): a shape reads a node's kind, its
    /// non-uniform params (an Expression's formula, a Math node's operator), its title, and its
    /// definition's sockets and accent — never its position, the comments or the settings.
    ///
    /// `EditorModel.perform` bumps `shapesVersion` only for these, so a node drag (`.moveNodes` once
    /// per mouse event) and a slider tick (a uniformable `.setParam`) no longer throw away the
    /// whole-graph cache and re-tokenise every Expression formula on the next layout pass.
    var changesShapes: Bool {
        switch self {
        case .moveNodes, .setSettings, .addSticky, .updateSticky, .addFrame, .updateFrame,
             .moveComments, .resizeComment, .removeComments: false
        case .setParam(_, _, let v): !v.isUniformable
        default: true
        }
    }

    /// Whether this change writes into the *active graph*'s own content — nodes, wires, comments
    /// — as opposed to a document- or definition-scoped edit (renaming, sockets, settings) that
    /// never touches `path`. `GroupDefinition.graph`'s setter already drops a `.graph`-content
    /// write silently when the active definition is `.msl` (spec — its own doc comment), but
    /// `.insert` also carries `definitions`/`assets` that land regardless of the active graph's
    /// body, so that drop alone is not enough to keep a `.msl` definition's "canvas" inert.
    /// `EditorModel.apply` uses this to refuse the whole change outright instead (Task 16's HARD
    /// REQUIREMENT).
    var touchesActiveGraph: Bool {
        switch self {
        // `.groupSelection`/`.ungroup`/`.makeUnique` read and rewrite `path`'s own nodes
        // (`GroupOperations`), same as the plain node edits above; unreachable in practice against
        // a `.msl` definition today (its graph is always empty, so the selection they require is
        // always empty too — `EditorModel+Groups.swift`'s own wrappers already refuse before
        // calling `apply`), but the honest classification is "touches the active graph" regardless.
        case .moveNodes, .setParam, .setTitle, .connect, .disconnect, .addNode, .removeNodes, .insert,
             .addSticky, .updateSticky, .addFrame, .updateFrame, .moveComments, .resizeComment, .removeComments,
             .groupSelection, .ungroup, .makeUnique:
            true
        // Definition- and document-scoped: never read or write `path`, so still legal while the
        // active graph is a `.msl` definition's inert canvas.
        case .setSettings, .addDefinition, .renameDefinition, .setDefinitionAccent, .addSocket,
             .renameSocket, .removeSocket, .deleteDefinition, .restore, .setDefinitionBody:
            false
        }
    }

    /// Edit-menu label for the undo step this change creates.
    public var undoName: String {
        switch self {
        case .moveNodes: "Move"
        case .setParam: "Change Value"
        case .setTitle: "Rename"
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .addNode: "Add Node"
        case .removeNodes: "Delete"
        case .insert: "Paste"
        case .setSettings: "Change Settings"
        case .addDefinition: "Add Node"
        case .restore: "Restore"
        case .groupSelection: "Group"
        case .ungroup: "Ungroup"
        case .makeUnique: "Make Unique"
        case .renameDefinition: "Rename Group"
        case .setDefinitionAccent: "Change Group Color"
        case .addSocket: "Add Socket"
        case .renameSocket: "Rename Socket"
        case .removeSocket: "Remove Socket"
        case .deleteDefinition: "Delete Group"
        case .setDefinitionBody: "Edit Code"
        case .addSticky: "Add Note"
        case .updateSticky: "Edit Note"
        case .addFrame: "Add Frame"
        case .updateFrame: "Edit Frame"
        case .moveComments: "Move"
        case .resizeComment: "Resize"
        case .removeComments: "Delete"
        }
    }
}
