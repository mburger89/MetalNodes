import Foundation

public struct GeneratedShader: Sendable, Hashable {
    public let source: String
    public let layout: UniformLayout
    public let lineMap: LineMap
    public let resolved: [NodeID: ResolvedNode]
    public let fragmentFunctionName: String
    public let target: OutputTarget
    /// The node/socket previewed, when this is a viewer program (spec §19.3).
    public let viewer: SocketRef?
    /// The stitchable function's source, when `target` is `.stitchable` (T4). `nil` for a viewer or a fragment program.
    public let exportSource: String?
    /// The exported SwiftUI stitchable function's name. Empty when `exportSource` is `nil`.
    public let functionName: String

    public init(source: String, layout: UniformLayout, lineMap: LineMap, resolved: [NodeID: ResolvedNode],
                fragmentFunctionName: String, target: OutputTarget, viewer: SocketRef? = nil,
                exportSource: String? = nil, functionName: String = "") {
        self.source = source
        self.layout = layout
        self.lineMap = lineMap
        self.resolved = resolved
        self.fragmentFunctionName = fragmentFunctionName
        self.target = target
        self.viewer = viewer
        self.exportSource = exportSource
        self.functionName = functionName
    }
}

public enum ShaderGenerator {
    public static let fragmentFunctionName = "shaderMain"

    /// Validation and type diagnostics without generating. Never throws.
    public static func diagnostics(_ doc: ShaderDocument, target: OutputTarget, registry: NodeRegistry) -> [Diagnostic] {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { return structural }
        guard let terminal = GraphValidator.terminal(in: doc.root) else { return structural }
        let order = TopoSort.order(doc.root, from: terminal)
        return structural + TypeResolver.resolve(doc.root, registry: registry, order: order).diagnostics
    }

    public static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment, viewer: SocketRef? = nil,
                                registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { throw .invalid(structural) }
        if let v = viewer, !GraphValidator.isValidViewer(v, in: doc.root, registry: registry) {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        let terminal = GraphValidator.terminal(in: doc.root)!
        let start = viewer?.node ?? terminal
        let order = TopoSort.order(doc.root, from: start)
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(structural + typeDiags) }

        // A viewer is a preview concept: always a fragment program (spec §19.3).
        let effectiveTarget: OutputTarget = viewer == nil ? target : .fragment
        switch effectiveTarget {
        case .fragment:
            return assembleFragment(doc, order: order, terminal: terminal, viewer: viewer, resolved: resolved, registry: registry)
        case .stitchable(let kind):
            return assembleStitchable(doc, kind: kind, order: order, terminal: terminal, resolved: resolved, registry: registry) // T4
        }
    }

    private static func assembleFragment(_ doc: ShaderDocument, order: [NodeID], terminal: NodeID, viewer: SocketRef?,
                                         resolved: [NodeID: ResolvedNode], registry: NodeRegistry) -> GeneratedShader {
        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved,
                                   env: .fragment,
                                   reserved: viewer == nil ? UniformLayoutBuilder.standardReserved : UniformLayoutBuilder.viewerReserved)
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>\nusing namespace metal;\n")
        b.add(emitted.layout.mslStruct + "\n")
        b.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in MSLStdlib.resolve(emitted.requiredStdlib) { b.add(f.source + "\n") }
        b.add("fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")
        for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]) }
        if let v = viewer, let variable = emitted.outputVars[v], let type = resolved[v.node]?.outputTypes[v.socket],
           let wrap = ViewerWrap.statement(variable: variable, type: type) {
            b.add("    " + wrap, owner: v.node)
        }
        b.add("}")
        return GeneratedShader(source: b.text, layout: emitted.layout, lineMap: b.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: viewer)
    }

    private static func assembleStitchable(_ doc: ShaderDocument, kind: StitchableKind, order: [NodeID], terminal: NodeID,
                                           resolved: [NodeID: ResolvedNode], registry: NodeRegistry) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved, env: .stitchableFunction)
        let args = StitchableCodegen.arguments(layout: emitted.layout)
        let color = emitted.inputExpressions[terminal]?["color"] ?? "float4(0.0, 0.0, 0.0, 1.0)"
        let stdlib = MSLStdlib.resolve(emitted.requiredStdlib)

        func function(into b: inout SourceBuilder, forExport: Bool) {
            b.add(StitchableCodegen.signature(kind: kind, name: name, args: args, forExport: forExport) + " {")
            b.add("    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);")
            for (i, line) in emitted.bodyLines.enumerated() where emitted.lineOwners[i] != terminal {
                b.add("    " + line, owner: emitted.lineOwners[i])
            }
            b.add("    " + StitchableCodegen.returnStatement(kind: kind, color: color), owner: terminal)
            b.add("}")
        }

        var export = SourceBuilder()
        export.add("#include <metal_stdlib>" + (kind == .layerEffect ? "\n#include <SwiftUI/SwiftUI_Metal.h>" : "") + "\nusing namespace metal;\n")
        for f in stdlib { export.add(f.source + "\n") }
        function(into: &export, forExport: true)

        var preview = SourceBuilder()
        preview.add("#include <metal_stdlib>\nusing namespace metal;\n")
        preview.add(emitted.layout.mslStruct + "\n")
        preview.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in stdlib { preview.add(f.source + "\n") }
        function(into: &preview, forExport: false)
        preview.add("")
        preview.add("fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")
        for l in StitchableCodegen.previewBody(kind: kind, name: name, args: args) { preview.add("    " + l) }
        preview.add("}")

        return GeneratedShader(source: preview.text, layout: emitted.layout, lineMap: preview.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: .stitchable(kind),
                               viewer: nil, exportSource: export.text, functionName: name)
    }
}
