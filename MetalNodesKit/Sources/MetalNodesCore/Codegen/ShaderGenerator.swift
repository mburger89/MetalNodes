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

        var src = ""
        src += "#include <metal_stdlib>\nusing namespace metal;\n\n"
        src += emitted.layout.mslStruct + "\n\n"   // mslStruct ends with "};" (no newline)
        src += "struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n\n"
        for f in MSLStdlib.resolve(emitted.requiredStdlib) { src += f.source + "\n\n" }
        src += "fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n"
        src += "                           constant Uniforms &u [[buffer(0)]]) {\n"
        let bodyStart = src.components(separatedBy: "\n").count   // 1-based line of first body line
        var map = LineMap()
        for (i, line) in emitted.bodyLines.enumerated() {
            src += "    " + line + "\n"
            if let owner = emitted.lineOwners[i] {
                let n = bodyStart + i
                if let last = map.entries.last, last.node == owner, last.range.upperBound == n - 1 {
                    map.entries[map.entries.count - 1] = LineMap.Entry(range: last.range.lowerBound...n, node: owner)
                } else {
                    map.entries.append(LineMap.Entry(range: n...n, node: owner))
                }
            }
        }
        src += "}\n"
        return GeneratedShader(source: src, layout: emitted.layout, lineMap: map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: target)
    }
}
