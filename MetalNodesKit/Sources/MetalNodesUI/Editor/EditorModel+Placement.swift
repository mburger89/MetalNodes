import CoreGraphics
import MetalNodesCore

extension EditorModel {
    /// Adds a builtin node with its defaults at `point` (top-left) and selects it. `nil` for an unknown id.
    @discardableResult
    public func addNode(defID: String, at point: CGPoint, select: Bool = true) -> NodeID? {
        guard registry[defID] != nil else { return nil }
        // The third route a terminal can reach a definition, after ⌘G and ⌘V (spec §23.2): the
        // palette and the ⇧A chooser both land here. A Fragment/Material Output is never valid
        // inside a definition, so refuse with a notice rather than add a node `validate` will
        // immediately condemn.
        if case .definition = activePath, GraphValidator.isTerminal(.builtin(defID)) {
            let label = defID == GraphValidator.materialTerminalID ? "Material Output" : "Fragment Output"
            showNotice("\(label) is only valid in the root graph")
            return nil
        }
        let n = NodeInstance(kind: .builtin(defID), position: point)
        apply(.addNode(n))
        // `apply` can refuse the whole change without this call ever being told — the HARD
        // REQUIREMENT gate, inside a `.msl` definition's inert "canvas" (fix round 1, I5: the
        // same shape `addInstance`/`insert` were already given the check for). Every route that
        // reaches this method today — palette double-click, drag-and-drop, the ⇧A chooser — lives
        // on `GraphCanvasView`, unmounted for exactly as long as the gate is shut, so this is
        // currently unreachable; the check is here so the method's own contract does not depend
        // on that staying true.
        guard graph.nodes[n.id] != nil else {
            showNotice("A Custom Code definition can't hold other nodes — exit it first")
            return nil
        }
        if select { self.select(n.id) }
        return n.id
    }

    /// Connects only if the resolved/declared types convert (spec §7.2). Returns whether it did.
    @discardableResult
    public func connectIfCompatible(_ from: SocketRef, to: SocketRef) -> Bool {
        guard let ft = DropResolver.outputType(of: from, graph: graph, shapes: shape(of:), resolved: resolvedTypes),
              let tt = DropResolver.inputType(of: to, graph: graph, shapes: shape(of:), resolved: resolvedTypes),
              DropResolver.compatible(ft, tt) else { return false }
        apply(.connect(from: from, to: to))
        return true
    }
}
