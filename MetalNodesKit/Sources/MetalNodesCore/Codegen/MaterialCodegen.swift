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

public extension MaterialCodegen {
    /// `<exportName>_surface` / `<exportName>_geometry` (spec §23.6).
    static func functionNames(exportName: String) -> (surface: String, geometry: String) {
        let n = StitchableCodegen.sanitizedName(exportName)
        return ("\(n)_surface", "\(n)_geometry")
    }

    /// The RealityKit call one Material Output socket becomes.
    ///
    /// Every surface setter takes `half`/`half3`; `set_normal` is the sole `float3` one and takes a
    /// tangent-space vector. Colours arrive as `float4` from the graph and are narrowed to `half3`.
    /// Verbatim from `RealityKitSurfaceShader.h` (spec §23.2).
    static func setterStatement(socket: String, expression e: String) -> String? {
        switch socket {
        case "baseColor":      "surface.set_base_color(half3(\(e).rgb));"
        case "emissive":       "surface.set_emissive_color(half3(\(e).rgb));"
        case "normal":         "surface.set_normal(\(e));"
        case "roughness":      "surface.set_roughness(half(\(e)));"
        case "metallic":       "surface.set_metallic(half(\(e)));"
        case "opacity":        "surface.set_opacity(half(\(e)));"
        case "occlusion":      "surface.set_ambient_occlusion(half(\(e)));"
        case "specular":       "surface.set_specular(half(\(e)));"
        case "positionOffset": "geo.set_model_position_offset(\(e));"
        default: nil
        }
    }

    /// Which sockets a lighting model actually renders (spec §23.7 rule 5). `.unlit` renders only
    /// emissive, so emitting the other seven setters would be noise in the exported file.
    static func liveSurfaceSockets(_ lighting: MaterialLightingModel) -> [String] {
        switch lighting {
        case .lit: ["baseColor", "normal", "roughness", "metallic", "emissive", "opacity", "occlusion", "specular"]
        case .unlit: ["emissive"]
        }
    }
}

// `Emitter` is internal (`ShaderGenerator` is the API), so anything spelling its types in a
// signature must stay internal too — same reasoning as `sharedBindings` above.
extension MaterialCodegen {
    /// The exported `.metal`: the RealityKit header, the stdlib the graph needs, the group
    /// functions, then one `[[visible]]` function per non-empty stage (spec §23.6).
    ///
    /// `surface` and `geometry` are `Emitter.Output`s produced with `EmitEnvironment
    /// .realityKitSurface`/`.realityKitGeometry` whose `uniform` closure was replaced by
    /// `EmitEnvironment.bakedUniforms`, so no statement here reads a uniform buffer.
    static func exportSource(surface: Emitter.Output, geometry: Emitter.Output,
                             groupFunctions: [GroupFunction], terminal: NodeID,
                             lighting: MaterialLightingModel, exportName: String,
                             textures: [TextureSlot]) -> String {
        let names = functionNames(exportName: exportName)
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>")
        b.add("#include <RealityKit/RealityKit.h>")
        b.add("using namespace metal;\n")
        for f in MSLStdlib.resolve(surface.requiredStdlib + geometry.requiredStdlib
                                    + groupFunctions.flatMap(\.requiredStdlib)) {
            b.add(f.source + "\n")
        }
        for f in groupFunctions { b.add(f.source, map: f.lineMap) }

        // Surface.
        b.add("[[visible]]")
        b.add("void \(names.surface)(realitykit::surface_parameters params) {")
        // `mn_sampler` is a program-scope `constexpr sampler` supplied by the stdlib (the Texture
        // Sample node `requires` it), already emitted above — declaring another here would be a
        // redefinition.
        //
        // A slot's local is declared only in the stage that actually samples it: a texture feeding
        // Base Color but not Position Offset has nothing for the geometry function to read, and an
        // unused `texture2d<half>` local is a warning in every user's Xcode build (spec §23.6).
        for slot in textures where stageReferences(surface, slot: slot) {
            b.add("    texture2d<half> \(slot.fragmentName) = params.textures().custom();")
        }
        b.add("    auto surface = params.surface();")
        for (i, line) in surface.bodyLines.enumerated() where surface.lineOwners[i] != terminal {
            b.add("    " + line, owner: surface.lineOwners[i])
        }
        for socket in liveSurfaceSockets(lighting) {
            guard let e = surface.inputExpressions[terminal]?[socket],
                  let statement = setterStatement(socket: socket, expression: e) else { continue }
            b.add("    " + statement, owner: terminal)
        }
        b.add("}")

        // Geometry — omitted entirely when nothing reaches Position Offset.
        if hasGeometryWork(geometry, terminal: terminal) {
            b.add("")
            b.add("[[visible]]")
            b.add("void \(names.geometry)(realitykit::geometry_parameters params) {")
            for slot in textures where stageReferences(geometry, slot: slot) {
                b.add("    texture2d<half> \(slot.fragmentName) = params.textures().custom();")
            }
            b.add("    auto geo = params.geometry();")
            for (i, line) in geometry.bodyLines.enumerated() where geometry.lineOwners[i] != terminal {
                b.add("    " + line, owner: geometry.lineOwners[i])
            }
            if let e = geometry.inputExpressions[terminal]?["positionOffset"],
               let statement = setterStatement(socket: "positionOffset", expression: e) {
                b.add("    " + statement, owner: terminal)
            }
            b.add("}")
        }
        return b.text
    }

    /// True when the geometry stage does anything but restate its default: some node reaches
    /// Position Offset. An offset left at its slot default moves nothing, and emitting a modifier
    /// that adds a constant zero would cost the caller a `boundsMargin` conversation for nothing.
    static func hasGeometryWork(_ geometry: Emitter.Output, terminal: NodeID) -> Bool {
        geometry.lineOwners.contains { $0 != nil && $0 != terminal }
    }

    /// True when some statement this stage actually emits names `slot` (`tex0`, `tex1`, …) — the
    /// only place a Texture Sample body can spell it. `\b` keeps `tex1` from matching inside
    /// `tex10`; without it a stage with ten-plus textures could declare an extra unused local.
    static func stageReferences(_ output: Emitter.Output, slot: TextureSlot) -> Bool {
        let pattern = "\\b\(slot.fragmentName)\\b"
        return output.bodyLines.contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }
}
