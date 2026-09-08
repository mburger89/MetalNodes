import Foundation

/// The four rules the RealityKit target adds beyond the terminal rules (spec §23.7). They live
/// apart from `GraphValidator` because they are the only rules that reason about stages, and
/// `Validation.swift` is long enough already.
public enum MaterialValidation {
    /// Rules 2–5. Rule 1 (the terminal) is `GraphValidator`'s, because every target has one.
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry,
                                   target: OutputTarget, reachable: [GroupDefinition]) -> [Diagnostic] {
        guard target == .realityKit else {
            return targetDiagnostics(doc, registry: registry, target: target, reachable: reachable)
        }
        guard let terminal = GraphValidator.terminal(in: doc.root, target: .realityKit) else { return [] }
        return stageDiagnostics(doc, registry: registry, terminal: terminal, reachable: reachable)
            + targetDiagnostics(doc, registry: registry, target: target, reachable: reachable)
            + definitionNodeDiagnostics(doc, registry: registry, reachable: reachable)
            + textureDiagnostics(doc, reachable: reachable)
            + lightingDiagnostics(doc, terminal: terminal)
            + liveParameterDiagnostics(doc, registry: registry)
    }

    /// Every node of the root and of a reachable definition, each with the graph it lives in.
    private static func allNodes(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [(NodeInstance, Graph)] {
        var out = doc.root.nodes.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .map { ($0, doc.root) }
        for d in reachable {
            out += d.graph.nodes.values
                .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                .map { ($0, d.graph) }
        }
        return out
    }

    private static func title(_ inst: NodeInstance, _ doc: ShaderDocument, _ registry: NodeRegistry) -> String {
        if case .builtin(let id) = inst.kind, let def = registry[id] { return inst.customTitle ?? def.title }
        return inst.customTitle ?? "Node"
    }

    // MARK: Rule 2 — stage legality

    /// A node whose `stages` omits the stage that reaches it. Reachability inside a definition is
    /// wire-based, the same as the root: once the walk reaches a `.group` instance, it continues
    /// from that definition's own Group Output (`TopoSort.order`, matching what `GroupCodegen`
    /// actually emits) rather than over every node the definition's canvas happens to hold — a
    /// node orphaned in a definition, never wired to its output, is in no emitted program and must
    /// not be flagged. A definition is still attributed to every stage that instantiates it,
    /// because one function body serves both callers.
    private static func stageDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry, terminal: NodeID,
                                         reachable: [GroupDefinition]) -> [Diagnostic] {
        MaterialStage.allCases.sorted { $0.rawValue < $1.rawValue }.flatMap { stage in
            stageViolations(order: MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage),
                            in: doc, registry: registry, stage: stage) { title in
                "\(title) is not available in the \(stage.title) stage"
            }
        }
    }

    /// The walk rule 2 is built from, over an arbitrary root order rather than a stage's own roots.
    ///
    /// `ShaderGenerator`'s viewer widening needs exactly this: it prepends the viewed node's
    /// upstream cone to the **surface** order, and those nodes were never among `stageOrder`'s
    /// roots, so rule 2 above never looked at them. The caller supplies the message because the
    /// reason differs — rule 2 is about a wire, the viewer is about what a viewed value can be.
    public static func stageViolations(order: [NodeID], in doc: ShaderDocument, registry: NodeRegistry,
                                       stage: MaterialStage,
                                       message: (String) -> String) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var toVisit: [(NodeInstance, Graph)] = order.compactMap { id in
            doc.root.nodes[id].map { ($0, doc.root) }
        }
        var visitedDefinitions = Set<GroupID>()
        var i = 0
        while i < toVisit.count {
            let (inst, _) = toVisit[i]; i += 1
            switch inst.kind {
            case .builtin(let id):
                // A node legal in *no* stage is not a stage error: "Mouse is not available in the
                // surface stage" invites the reader to move it to the geometry stage, where it is
                // just as unavailable. Rule 3 names those nodes, once, with the reason that is
                // actually true of them. Deriving `stages` is what made this case appear at all —
                // Mouse and Resolution *declared* both stages while rule 3 refused them from a
                // separate list, so rule 2 never saw them.
                guard let def = registry[id], !def.stages.isEmpty, !def.stages.contains(stage) else { continue }
                out.append(Diagnostic(.error, message(title(inst, doc, registry)), node: inst.id))
            case .group(let gid):
                guard visitedDefinitions.insert(gid).inserted, let d = doc.definitions[gid],
                      let output = d.outputNode else { continue }
                toVisit += TopoSort.order(d.graph, from: output).compactMap { id in
                    d.graph.nodes[id].map { ($0, d.graph) }
                }
            case .groupInput, .groupOutput:
                continue
            }
        }
        return out
    }

    // MARK: Rule 3 — target legality

    /// A node that reads a system value this target cannot supply — and, in the same breath, its
    /// former mirror: a node only *another* target can supply, reachable under this one. They were
    /// two hand-maintained sets (`twoDimensionalOnly`, and `material3D` minus the terminal) whose
    /// job was to restate, by node id, what the emit environments already say by vocabulary. Spec
    /// §24.5: one predicate, asked of the environments the target actually emits in.
    ///
    /// Illegal means illegal in *every* one of them. Under `.realityKit` there are two, and a node
    /// legal in only one is not a target error but a stage error — rule 2's question, with its own
    /// message about which stage the wire reached.
    ///
    /// The message names the problem *and* the fix. The two retired strings each named only the
    /// fix ("needs the RealityKit Material target"), which is the half a user acts on: the palette
    /// does no target filtering, so dropping World Position into a Color Effect document is a
    /// two-click mistake. The predicate can now derive that half instead of hardcoding it — ask it
    /// which *other* targets would accept this body — so the unified rule keeps both halves.
    private static func targetDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                          target: OutputTarget, reachable: [GroupDefinition]) -> [Diagnostic] {
        let environments = EmitEnvironment.environments(for: target)
        return allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, let def = registry[id] else { return nil }
            let chosen = def.variantCase(for: inst)
            var missing: String?
            for env in environments {
                switch env.canEmit(def.body, chosen: chosen) {
                case .allowed: return nil
                case .missing(let name): missing = missing ?? name
                }
            }
            guard let missing else { return nil }
            let problem = "\(title(inst, doc, registry)) reads \(missing), which the \(target.title) target does not provide"
            guard let fix = alternativeTargets(for: def.body, chosen: chosen, excluding: target) else {
                return Diagnostic(.error, problem, node: inst.id)
            }
            return Diagnostic(.error, problem + " — this node needs the \(fix) target", node: inst.id)
        }
    }

    /// How a diagnostic names the targets that *would* accept this body, derived by asking the same
    /// predicate of every other target rather than from a second hand-kept list.
    ///
    /// The three SwiftUI kinds share one `sys` vocabulary, so a body legal under one is legal under
    /// all three and naming each would be noise; they collapse to "SwiftUI" — which is what the
    /// retired hand-written string said as well. `nil` when no other target can emit the body
    /// either: then the message names the problem and stops rather than inventing a fix. No builtin
    /// is in that position today, but a library node reading two vocabularies at once would be.
    private static func alternativeTargets(for body: NodeBody, chosen: String?,
                                           excluding target: OutputTarget) -> String? {
        var labels: [String] = []
        for other in OutputTarget.all where other != target {
            guard EmitEnvironment.environments(for: other).contains(where: { $0.canEmit(body, chosen: chosen) == .allowed })
            else { continue }
            let label = other.stitchableKind == nil ? other.title : "SwiftUI"
            if !labels.contains(label) { labels.append(label) }
        }
        guard let last = labels.last else { return nil }
        return labels.count == 1 ? last : labels.dropLast().joined(separator: ", ") + " or " + last
    }

    /// The *inverse* of rule 3, and the same predicate asked of a different environment: under
    /// `.realityKit` a 3D input is legal in the root and illegal inside a group definition.
    ///
    /// A group function is target-agnostic by design — `EmitEnvironment.groupFunction`'s `sys`
    /// carries `uv`/`time`/`resolution`/`mouse` and nothing else, because one emitted function
    /// serves every target and every caller (spec §23.4). It therefore cannot spell
    /// `params.geometry().world_position()`, and without this rule a World Position inside a
    /// definition emitted `v0 = /* ?sys.worldPosition */;` into *both* the preview program (a raw
    /// MSL error the user cannot act on) and `exportSource` (a `.metal` file that will not
    /// compile). Rule 2 does not catch it — these nodes carry both stages — and rule 3 asks the
    /// *material* environments, which spell every one of these names perfectly well.
    ///
    /// So the question is not "is this node one of the 3D inputs" — that was a third hand-listed
    /// set restating the vocabulary — but "can the environment this node's statement is emitted in
    /// spell what it reads", which for a node inside a definition is always `groupFunction`
    /// (spec §24.5).
    ///
    /// Reachable definitions only, and inside each one only what is wire-reachable from its own
    /// Group Output — the breadth rule 2 uses and `GroupCodegen` actually emits. A 3D input left
    /// orphaned on a definition's canvas reaches no function, so it produces no marker and must not
    /// be flagged (fix round 1 settled that principle for rule 2).
    private static func definitionNodeDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                                  reachable: [GroupDefinition]) -> [Diagnostic] {
        reachable.flatMap { d -> [Diagnostic] in
            guard let output = d.outputNode else { return [] }
            return TopoSort.order(d.graph, from: output).compactMap { nodeID -> Diagnostic? in
                guard let inst = d.graph.nodes[nodeID], case .builtin(let id) = inst.kind,
                      let def = registry[id],
                      EmitEnvironment.groupFunction.canEmit(def.body, chosen: def.variantCase(for: inst)) != .allowed
                else { return nil }
                return Diagnostic(.error,
                    "A RealityKit material reads \(title(inst, doc, registry)) in the root graph — move this node out of the group",
                    node: inst.id)
            }
        }
    }

    // MARK: Rule 4 — one texture slot

    private static func textureDiagnostics(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // A group function declares its texture parameters as `texture2d<float>` (spec §21.2), and
        // `params.textures().custom()` is a `texture2d<half>` — MSL converts neither. Rather than
        // fork the group-function signature per target for one slot, this target samples from the
        // root only. The same shape as M3's refusal, which M6 lifted for the Layer Effect.
        for d in reachable {
            for id in d.graph.nodes.values
                .filter({ $0.kind == .builtin("texture.sample") })
                .map(\.id)
                .sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
                out.append(Diagnostic(.error,
                    "A RealityKit material samples its texture in the root graph — move this Texture Sample out of the group",
                    node: id))
            }
        }

        // The limit is one texture *slot*, not one Texture Sample node. `Emitter.requestTexture`
        // allocates one slot per distinct asset in first-use order (unassigned samples sharing the
        // `nil` slot), so two nodes sampling the same image both read `tex0` and export cleanly —
        // counting nodes refused a document `params.textures().custom()` serves perfectly well.
        // The first distinct asset the root names is the one that fits; every sample naming a
        // different one is what has to go.
        let samples = doc.root.nodes.values
            .filter { $0.kind == .builtin("texture.sample") }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        if let first = samples.first.map(asset) {
            out += samples.filter { asset($0) != first }.map {
                Diagnostic(.error, "A RealityKit material has one texture slot — remove the extra Texture Sample", node: $0.id)
            }
        }
        return out
    }

    /// The asset a Texture Sample names; `nil` when unset — which is itself a slot, exactly as
    /// `Emitter.requestTexture` treats it.
    private static func asset(_ inst: NodeInstance) -> AssetID? {
        if case .asset(let a)? = inst.params["asset"] { return a }
        return nil
    }

    // MARK: Rule 5 — lighting model

    private static func lightingDiagnostics(_ doc: ShaderDocument, terminal: NodeID) -> [Diagnostic] {
        guard doc.settings.lightingModel == .unlit else { return [] }
        // Only a *surface* socket other than Emissive matters here — a geometry socket like
        // Position Offset moves vertices regardless of the lighting model, so wiring it under
        // `.unlit` is correct and must not warn.
        let wired = BuiltinNodes.materialStages
            .filter { $0.value == .surface && $0.key != "emissive" }
            .keys
            .filter { doc.root.inputs[SocketRef(terminal, $0)] != nil }
        guard !wired.isEmpty else { return [] }
        return [Diagnostic(.warning, "Unlit materials render only Emissive", node: terminal)]
    }

    // MARK: Rule 6 — live parameters

    /// A `CustomMaterial` exposes exactly one `float4` (spec §24.6), so `settings.liveParameters`
    /// may hold at most four entries, no path may repeat (a duplicate would silently drop one
    /// component's worth of animation — the header and the Swift snippet would both list and seed
    /// two components from the same value), and every one of them must itself be a float — a live
    /// vector or texture path has nowhere to go in that single `float4`. Nothing in this build's
    /// editor can produce any of the three mistakes yet — the inspector has no Live affordance
    /// until a later task — but a hand-edited or migrated document can carry one anyway, and this
    /// rule is what stands between that document and a `.metal` export that fails to compile
    /// (`length(params.uniforms().custom_parameter().x)` is ambiguous MSL for a float — see
    /// `fieldType` below).
    ///
    /// A path naming a node the document no longer has is *not* this rule's problem: `EditorModel`
    /// prunes a dangling live parameter the moment its node is deleted
    /// (`EditorModel.pruneLiveParameters`, called from `pruneAfterRemoval`), the same way it prunes
    /// a dangling viewer or selection. This rule only judges paths that still resolve. (A dangling
    /// path would not by itself break the export either way — `bakedUniforms` only substitutes for
    /// a path with a matching `UniformLayout` field, and a path nothing requests has none — but
    /// leaving the setting to point at nothing is still stale data worth pruning.)
    private static func liveParameterDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry) -> [Diagnostic] {
        let live = doc.settings.liveParameters
        guard !live.isEmpty else { return [] }
        var out: [Diagnostic] = []
        if live.count > 4 {
            out.append(Diagnostic(.error,
                "A RealityKit material exposes one float4 — at most four parameters can be live"))
        }
        if Set(live).count != live.count {
            out.append(Diagnostic(.error, "The same parameter is marked live more than once"))
        }
        for path in live {
            guard let type = fieldType(for: path, in: doc, registry: registry), type != .float else { continue }
            out.append(Diagnostic(.error,
                "A live parameter must be a float — \(type.rawValue) cannot animate through a RealityKit material's custom float4",
                node: path.instancePath.first))
        }
        return out
    }

    /// The type a live parameter's path names. Tries the two shapes a `ParamPath` the app itself
    /// constructs can have — a declared value param, then an unwired input socket's own *concrete*
    /// type — the same order `ParamValues.value` resolves in. Neither branch answers for a
    /// **generic** input (`vector.length`'s `v: .generic("T")`, defaulting to `.float2`): its
    /// declared type is a type variable, not a `SocketType`, so this falls back to the value
    /// `ParamValues.value` itself would bake there — the same lookup `bakedUniforms` uses — whose
    /// `.socketType` is concrete. Only truly unresolvable paths (an id nothing in the document owns)
    /// come back `nil`, left unjudged rather than wrongly flagged.
    private static func fieldType(for path: ParamPath, in doc: ShaderDocument, registry: NodeRegistry) -> SocketType? {
        guard let nodeID = path.instancePath.first, let (inst, gpath) = doc.node(nodeID),
              let shape = doc.shape(of: inst, in: gpath, registry: registry) else { return nil }
        if let p = shape.param(named: path.param), case .value(let t, _) = p.kind { return t }
        if let decl = shape.input(named: path.param), case .concrete(let t) = decl.type { return t }
        return ParamValues.value(for: path, in: doc, registry: registry)?.socketType
    }
}
