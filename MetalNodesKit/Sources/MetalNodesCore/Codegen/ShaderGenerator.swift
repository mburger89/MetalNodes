import Foundation

public struct GeneratedShader: Sendable, Hashable {
    public let source: String
    public let layout: UniformLayout
    public let lineMap: LineMap
    public let resolved: [NodeID: ResolvedNode]
    public let fragmentFunctionName: String
    public let target: OutputTarget

    public init(source: String, layout: UniformLayout, lineMap: LineMap, resolved: [NodeID: ResolvedNode],
                fragmentFunctionName: String, target: OutputTarget) {
        self.source = source
        self.layout = layout
        self.lineMap = lineMap
        self.resolved = resolved
        self.fragmentFunctionName = fragmentFunctionName
        self.target = target
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

    public static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment,
                                registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { throw .invalid(structural) }
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(structural + typeDiags) }

        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved)

        var builder = SourceBuilder()
        builder.add("#include <metal_stdlib>\nusing namespace metal;\n")
        builder.add(emitted.layout.mslStruct + "\n")
        builder.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in MSLStdlib.resolve(emitted.requiredStdlib) { builder.add(f.source + "\n") }
        builder.add("fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")
        for (i, line) in emitted.bodyLines.enumerated() {
            builder.add("    " + line, owner: emitted.lineOwners[i])
        }
        builder.add("}")
        return GeneratedShader(source: builder.text, layout: emitted.layout, lineMap: builder.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: target)
    }
}
