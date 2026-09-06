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
    /// among them, as one change (spec §20.7).
    case insert(nodes: [NodeInstance], edges: [Edge], definitions: [GroupDefinition] = [])
    case setSettings(DocumentSettings)

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

    /// Undo/redo only. Bypasses transactions; never registers an undo of its own.
    case restore(ShaderDocument)

    /// Spec §18.2. `.setSettings` is topology only when `fastMath`, `target`, or — under a
    /// stitchable target — `exportName` changes, and this cannot see the previous settings to tell
    /// — so it classifies as cosmetic and `EditorModel.perform` compares against the current
    /// document and schedules the recompile itself.
    public var changeClass: ChangeClass {
        switch self {
        // A definition's name and accent are labels: the name reaches codegen only as part of the
        // emitted function's identifier, which is not worth a rebuild of an unchanged program.
        case .moveNodes, .setTitle, .setSettings, .renameDefinition, .setDefinitionAccent: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNodes, .insert, .restore,
             .groupSelection, .ungroup, .makeUnique, .addSocket, .renameSocket, .removeSocket, .deleteDefinition: .topology
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
        }
    }
}
