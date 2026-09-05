import Foundation

/// Text pieces of a SwiftUI `[[stitchable]]` program (spec §9.5, §19.4).
public enum StitchableCodegen {
    public static let defaultName = "metalNodesShader"

    /// `raw` reduced to a C identifier; empty/blank → `defaultName`.
    public static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultName }
        var s = String(trimmed.unicodeScalars.map { ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_") ? Character($0) : "_" })
        if let first = s.first, ("0"..."9").contains(first) { s = "_" + s }
        return s.isEmpty ? defaultName : s
    }

    public struct Argument: Sendable, Hashable {
        public let name: String
        public let mslType: String
        /// nil for `mouse`, which is not a layout slot.
        public let field: UniformField?
    }

    /// `float2 mouse`, then every user slot in layout order; int/bool travel as `float` (spec §19.2).
    public static func arguments(layout: UniformLayout) -> [Argument] {
        var out = [Argument(name: "mouse", mslType: "float2", field: nil)]
        for f in layout.fields where f.path != nil {
            let t: String = switch f.type {
            case .int, .bool: "float"
            default: f.type.mslName
            }
            out.append(Argument(name: f.name, mslType: t, field: f))
        }
        return out
    }

    static func signature(kind: StitchableKind, name: String, args: [Argument], forExport: Bool) -> String {
        let prefix: String = switch kind {
        case .colorEffect: "half4 \(name)(float2 position, half4 currentColor, float2 size, float time"
        case .distortionEffect: "float2 \(name)(float2 position, float2 size, float time"
        case .layerEffect: forExport
            ? "half4 \(name)(float2 position, SwiftUI::Layer layer, float2 size, float time"
            : "half4 \(name)(float2 position, float2 size, float time"
        }
        let tail = args.map { ", \($0.mslType) \($0.name)" }.joined()
        return (forExport ? "[[stitchable]] " : "") + prefix + tail + ")"
    }

    static func returnStatement(kind: StitchableKind, color: String) -> String {
        switch kind {
        case .colorEffect, .layerEffect: "return half4(\(color));"
        case .distortionEffect: "return float2(\(color).x, 1.0 - \(color).y) * size;"
        }
    }

    /// Body of the preview's `shaderMain`, calling the function with values read from `Uniforms`.
    static func previewBody(kind: StitchableKind, name: String, args: [Argument]) -> [String] {
        let call = args.map { a in a.field == nil ? "u.mouse" : "u.\(a.name)" }.joined(separator: ", ")
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
