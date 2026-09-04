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
    /// Paste / duplicate: nodes first, then wires among them, as one change.
    case insert(nodes: [NodeInstance], edges: [Edge])
    case setSettings(DocumentSettings)
    /// Undo/redo only. Bypasses transactions; never registers an undo of its own.
    case restore(ShaderDocument)

    public var changeClass: ChangeClass {
        switch self {
        case .moveNodes, .setTitle: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNodes, .insert, .setSettings, .restore: .topology
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
        }
    }
}
