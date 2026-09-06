import Foundation

/// Text pieces of a SwiftUI `[[stitchable]]` program (spec §9.5, §19.4).
public enum StitchableCodegen {
    public static let defaultName = "metalNodesShader"

    /// Words that cannot name the generated function in Swift or in MSL.
    static let reservedNames: Set<String> = [
        "default", "for", "class", "switch", "struct", "enum", "func", "return", "if", "else",
        "while", "do", "in", "is", "as", "let", "var", "import", "extension", "protocol",
        "static", "public", "private", "internal", "case", "break", "continue", "where",
        "self", "Self", "true", "false", "nil", "half", "float", "int", "bool",
        "kernel", "vertex", "fragment", "constant", "device", "thread", "texture", "sampler", "bundle",
    ]

    /// `raw` reduced to a C identifier; empty/blank → `defaultName`. A reserved word gains a `_`.
    public static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultName }
        var s = String(trimmed.unicodeScalars.map { ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_") ? Character($0) : "_" })
        if let first = s.first, ("0"..."9").contains(first) { s = "_" + s }
        guard !s.isEmpty else { return defaultName }
        return reservedNames.contains(s) ? s + "_" : s
    }

    public struct Argument: Sendable, Hashable {
        public let name: String
        public let mslType: String
        /// nil for `mouse`, which is not a layout slot.
        public let field: UniformField?
    }

    /// `float2 mouse`, then every user slot in layout order; int/bool travel as `float` and
    /// `color` arrives as the premultiplied `half4` SwiftUI's `.color(_:)` passes (spec §19.2, §19.4).
    public static func arguments(layout: UniformLayout) -> [Argument] {
        var out = [Argument(name: "mouse", mslType: "float2", field: nil)]
        for f in layout.fields where f.path != nil {
            let t: String = switch f.type {
            case .int, .bool: "float"
            case .color: "half4"
            default: f.type.mslName
            }
            out.append(Argument(name: f.name, mslType: t, field: f))
        }
        return out
    }

    /// `textures` is always empty for the exported function — SwiftUI passes no textures, and under
    /// the Layer Effect the samples read `layer` instead (spec §21.2). The preview declares one
    /// `texture2d<float>` parameter per slot so `shaderMain` can forward its bindings.
    static func signature(kind: StitchableKind, name: String, args: [Argument],
                          textures: [TextureSlot] = [], forExport: Bool) -> String {
        let prefix: String = switch kind {
        case .colorEffect: "half4 \(name)(float2 position, half4 currentColor, float2 size, float time"
        case .distortionEffect: "float2 \(name)(float2 position, float2 size, float time"
        case .layerEffect: forExport
            ? "half4 \(name)(float2 position, SwiftUI::Layer layer, float2 size, float time"
            : "half4 \(name)(float2 position, float2 size, float time"
        }
        let tail = args.map { ", \($0.mslType) \($0.name)" }.joined()
            + textures.map { ", texture2d<float> \($0.fragmentName)" }.joined()
        return (forExport ? "[[stitchable]] " : "") + prefix + tail + ")"
    }

    static func returnStatement(kind: StitchableKind, color: String) -> String {
        switch kind {
        case .colorEffect, .layerEffect: "return half4(\(color));"
        case .distortionEffect: "return float2(\(color).x, 1.0 - \(color).y) * size;"
        }
    }

    /// Body of the preview's `shaderMain`, calling the function with values read from `Uniforms`.
    static func previewBody(kind: StitchableKind, name: String, args: [Argument],
                            textures: [TextureSlot] = []) -> [String] {
        // MSL has no implicit conversion between vector types, so the `float4` a colour slot occupies
        // in `Uniforms` needs an explicit narrowing to the `half4` the function declares.
        let call = (args.map { a in
            guard let f = a.field else { return "u.mouse" }
            return f.type == .color ? "half4(u.\(a.name))" : "u.\(a.name)"
        } + textures.map(\.fragmentName)).joined(separator: ", ")
        var lines = ["float2 position = float2(in.uv.x, 1.0 - in.uv.y) * u.resolution;"]
        switch kind {
        case .colorEffect:
            lines.append("half4 c = \(name)(position, half4(0.0), u.resolution, u.time, \(call));")
            lines.append("return float4(c);")
        case .layerEffect:
            lines.append("half4 c = \(name)(position, u.resolution, u.time, \(call));")
            lines.append("return float4(c);")
        case .distortionEffect:
            lines.append("float2 c = \(name)(position, u.resolution, u.time, \(call));")
            lines.append("return float4(c / u.resolution, 0.0, 1.0);")
        }
        return lines
    }
}
