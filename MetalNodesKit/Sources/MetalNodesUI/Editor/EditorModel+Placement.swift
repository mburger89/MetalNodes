import CoreGraphics
import MetalNodesCore

extension EditorModel {
    /// Adds a builtin node with its defaults at `point` (top-left) and selects it. `nil` for an unknown id.
    @discardableResult
    public func addNode(defID: String, at point: CGPoint, select: Bool = true) -> NodeID? {
        guard registry[defID] != nil else { return nil }
        let n = NodeInstance(kind: .builtin(defID), position: point)
        apply(.addNode(n))
        if select { self.select(n.id) }
        return n.id
    }

    /// Connects only if the resolved/declared types convert (spec §7.2). Returns whether it did.
    @discardableResult
    public func connectIfCompatible(_ from: SocketRef, to: SocketRef) -> Bool {
        guard let ft = DropResolver.outputType(of: from, graph: document.root, registry: registry, resolved: resolvedTypes),
              let tt = DropResolver.inputType(of: to, graph: document.root, registry: registry, resolved: resolvedTypes),
              DropResolver.compatible(ft, tt) else { return false }
        apply(.connect(from: from, to: to))
        return true
    }
}
