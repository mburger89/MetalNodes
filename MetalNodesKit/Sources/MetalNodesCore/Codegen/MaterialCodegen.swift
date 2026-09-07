import Foundation

/// The RealityKit target's code generation (spec §23.2, §23.4, §23.6). One graph, two stages:
/// this type decides what each stage needs, how the two agree on bindings, and what the exported
/// `[[visible]]` functions say.
public enum MaterialCodegen {
    /// The nodes `stage` needs, dependencies first, terminal last.
    ///
    /// A stage's roots are the terminal sockets that belong to it (`BuiltinNodes.materialStages`).
    /// Walking upstream from each root and deduplicating preserves the post-order the emitter
    /// requires. The terminal is included last so `Emitter.Output.inputExpressions[terminal]`
    /// carries the setter arguments; its own (empty) body lines are dropped by the assembler.
    public static func stageOrder(graph: Graph, terminal: NodeID, stage: MaterialStage) -> [NodeID] {
        var out: [NodeID] = []
        var seen = Set<NodeID>()
        let roots = BuiltinNodes.materialStages
            .filter { $0.value == stage }
            .keys
            .sorted()
            .compactMap { graph.inputs[SocketRef(terminal, $0)] }
            .map(\.node)
        for root in roots where graph.nodes[root] != nil {
            for id in TopoSort.order(graph, from: root) where seen.insert(id).inserted {
                out.append(id)
            }
        }
        // A wire into the terminal from the terminal itself is impossible (validation refuses
        // cycles), so the terminal can only arrive here as a duplicate of nothing.
        seen.insert(terminal)
        out.append(terminal)
        return out
    }

    /// The union of two passes' uniform and texture requests, as one layout and one slot numbering.
    /// The surface pass is numbered first so its slot indices are the stable ones.
    static func sharedBindings(surface: Emitter.Output, geometry: Emitter.Output,
                               reserved: [UniformLayoutBuilder.Reserved] = UniformLayoutBuilder.standardReserved)
        -> Emitter.SharedBindings {
        var requests: [(path: ParamPath, type: SocketType)] = []
        var seen = Set<ParamPath>()
        for r in surface.uniformRequests + geometry.uniformRequests where seen.insert(r.path).inserted {
            requests.append(r)
        }
        var slots: [AssetID?: TextureSlot] = [:]
        var order: [TextureSlot] = []
        for slot in surface.textureRequests + geometry.textureRequests where slots[slot.asset] == nil {
            let renumbered = TextureSlot(index: order.count, asset: slot.asset)
            slots[slot.asset] = renumbered
            order.append(renumbered)
        }
        return Emitter.SharedBindings(layout: UniformLayoutBuilder.build(requests, reserved: reserved),
                                      textures: slots, order: order)
    }
}
