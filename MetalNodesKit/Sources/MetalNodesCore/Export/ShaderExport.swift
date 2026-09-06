import Foundation

public struct ExportFile: Sendable, Hashable {
    public let name: String
    public let contents: String
    public init(name: String, contents: String) { self.name = name; self.contents = contents }
}

/// What File ▸ Export Shader… writes (spec §9.5, §19.4).
public enum ShaderExport {
    public static func files(for doc: ShaderDocument, registry: NodeRegistry = .builtin) throws(GenerationError) -> [ExportFile] {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let shader = try ShaderGenerator.generate(doc, target: doc.settings.target, viewer: nil, registry: registry)
        guard let kind = doc.settings.target.stitchableKind, let export = shader.exportSource else {
            let header = fragmentHeader(for: shader, document: doc, registry: registry)
            return [ExportFile(name: "\(name).metal", contents: header + shader.source)]
        }
        return [ExportFile(name: "\(name).metal", contents: export),
                ExportFile(name: "\(name).swift", contents: swiftSnippet(for: shader, kind: kind, document: doc, registry: registry))]
    }

    /// The comment block File ▸ Export… prepends to the fragment target's program source (spec
    /// §21.3): the uniform buffer's layout (offset, MSL type, field name, and — for a field backed
    /// by a node parameter — the "node · param" it came from) and the texture slots, each naming
    /// its asset or "unassigned". Ends with a blank line, ready to concatenate with `shader.source`.
    public static func fragmentHeader(for shader: GeneratedShader, document: ShaderDocument, registry: NodeRegistry) -> String {
        let name = StitchableCodegen.sanitizedName(document.settings.exportName)
        var lines = ["// MetalNodes fragment shader \"\(name)\"", "// Uniforms (buffer 0):"]
        for f in shader.layout.fields {
            var line = "//   \(f.offset)  \(f.mslType)  \(f.name)"
            if f.path != nil { line += "  \u{2190} " + commentLabel(for: f, document: document, registry: registry) }
            lines.append(line)
        }
        lines.append("// Textures:")
        for slot in shader.textures {
            let assetName = slot.asset.flatMap { document.settings.assets[$0]?.name } ?? "unassigned"
            lines.append("//   texture(\(slot.index))  \(assetName)")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Swift parameter names: `mouse`, then camelCase(node title + param label), de-duplicated with a numeric suffix.
    public static func parameterNames(for args: [StitchableCodegen.Argument], document: ShaderDocument, registry: NodeRegistry) -> [String] {
        var used = Set<String>(), out: [String] = []
        for a in args {
            var base = "mouse"
            if let f = a.field, let path = f.path, let nodeID = path.instancePath.first,
               let node = document.root.nodes[nodeID], case .builtin(let defID) = node.kind, let def = registry[defID] {
                let title = node.customTitle ?? def.title
                let label = def.input(named: path.param)?.label ?? def.param(named: path.param)?.label ?? path.param
                base = camelCase(title + " " + label)
            } else if a.field != nil {
                base = a.name
            }
            var name = base, n = 2
            while used.contains(name) { name = base + "\(n)"; n += 1 }
            used.insert(name); out.append(name)
        }
        return out
    }

    static func camelCase(_ s: String) -> String {
        let words = s.split { !$0.isLetter && !$0.isNumber }.map { String($0) }
        guard let first = words.first else { return "value" }
        let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        var out = first.lowercased() + rest.joined()
        if let c = out.first, c.isNumber { out = "_" + out }
        return out
    }

    public static func swiftSnippet(for shader: GeneratedShader, kind: StitchableKind, document: ShaderDocument, registry: NodeRegistry) -> String {
        let name = shader.functionName
        let args = StitchableCodegen.arguments(layout: shader.layout)
        let names = parameterNames(for: args, document: document, registry: registry)
        var params: [String] = ["size: CGSize", "time: Float"]
        var calls: [(call: String, comment: String)] = [(".float2(size)", ""), (".float(time)", "")]
        for (a, n) in zip(args, names) {
            guard let f = a.field else { params.append("\(n): CGPoint"); calls.append((".float2(\(n))", "")); continue }
            let comment = "    // " + commentLabel(for: f, document: document, registry: registry)
            switch f.type {
            case .float: params.append("\(n): Float"); calls.append((".float(\(n))", comment))
            // `Shader.Argument` has no vector-taking overload: `.floatN` takes N scalar components
            // (the only `.float2(_:)` overloads take CGPoint/CGSize), so spell them out.
            case .float2: params.append("\(n): SIMD2<Float>"); calls.append((".float2(\(n).x, \(n).y)", comment))
            case .float3: params.append("\(n): SIMD3<Float>"); calls.append((".float3(\(n).x, \(n).y, \(n).z)", comment))
            case .float4: params.append("\(n): SIMD4<Float>"); calls.append((".float4(\(n).x, \(n).y, \(n).z, \(n).w)", comment))
            case .color: params.append("\(n): Color"); calls.append((".color(\(n))", comment))
            case .int: params.append("\(n): Int"); calls.append((".float(Float(\(n)))", comment))
            case .bool: params.append("\(n): Bool"); calls.append((".float(\(n) ? 1 : 0)", comment))
            case .texture: continue
            }
        }
        // The comma goes before the comment — a trailing comment must never swallow it.
        let argumentLines = calls.enumerated().map { i, c in
            "            " + c.call + (i == calls.count - 1 ? "" : ",") + c.comment
        }
        let modifier: String = switch kind {
        case .colorEffect: "colorEffect"
        case .distortionEffect: "distortionEffect"
        case .layerEffect: "layerEffect"
        }
        let tail = kind == .colorEffect ? "))" : "), maxSampleOffset: .zero)"
        var s = "// \(name).swift — generated by MetalNodes. Argument order matches \(name).metal.\n"
        s += "import SwiftUI\n\nextension View {\n"
        s += "    /// Applies the MetalNodes shader \"\(name)\".\n"
        s += "    func \(name)(\(params.joined(separator: ", "))) -> some View {\n"
        s += "        \(modifier)(ShaderLibrary.\(name)(\n"
        s += argumentLines.joined(separator: "\n") + "\n"
        s += "        \(tail)\n    }\n}\n"
        return s
    }

    private static func commentLabel(for f: UniformField, document: ShaderDocument, registry: NodeRegistry) -> String {
        guard let path = f.path, let nodeID = path.instancePath.first, let node = document.root.nodes[nodeID],
              case .builtin(let defID) = node.kind, let def = registry[defID] else { return f.name }
        let label = def.input(named: path.param)?.label ?? def.param(named: path.param)?.label ?? path.param
        return "\(node.customTitle ?? def.title) · \(label)"
    }
}
