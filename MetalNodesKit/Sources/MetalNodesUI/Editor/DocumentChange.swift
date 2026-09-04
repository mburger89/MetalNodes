import CoreGraphics
import MetalNodesCore

public enum ChangeClass: Sendable { case cosmetic, parameter, topology }

/// Every edit goes through one of these, which is what makes classification
/// (spec §10) a `switch` instead of a diff.
public enum DocumentChange: Sendable {
    case moveNode(NodeID, to: CGPoint)
    case setParam(NodeID, ParamID, ParamValue)
    case connect(from: SocketRef, to: SocketRef)
    case disconnect(SocketRef)
    case addNode(NodeInstance)
    case removeNode(NodeID)

    public var changeClass: ChangeClass {
        switch self {
        case .moveNode: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNode: .topology
        }
    }
}
