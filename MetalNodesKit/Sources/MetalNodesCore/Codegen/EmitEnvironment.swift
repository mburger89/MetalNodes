import Foundation

/// How generated statements spell a uniform read and the four system values (spec §19.2).
/// One emitter serves every target; only this differs.
public struct EmitEnvironment: Sendable {
    public var uniform: @Sendable (UniformField) -> String
    public var sys: [String: String]
    /// The whole sample expression a Texture Sample body becomes, given its slot and the
    /// expression for its `uv` input (spec §21.2). The y flip lives here, not in the loader.
    public var textureSample: @Sendable (TextureSlot, _ uvExpr: String) -> String
    /// How a *call site* in this program spells a slot it passes to a group function.
    public var textureName: @Sendable (TextureSlot) -> String

    public static let sysNames: Set<String> = ["uv", "time", "resolution", "mouse"]

    /// A slot sampled by name, y-flipped: the shape every target but the Layer Effect export uses.
    public static func flippedSample(_ name: String, _ uv: String) -> String {
        "\(name).sample(mn_sampler, float2(\(uv).x, 1.0 - \(uv).y))"
    }

    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: String],
                textureSample: @escaping @Sendable (TextureSlot, String) -> String
                    = { slot, uv in EmitEnvironment.flippedSample(slot.fragmentName, uv) },
                textureName: @escaping @Sendable (TextureSlot) -> String = { $0.fragmentName }) {
        self.uniform = uniform
        self.sys = sys
        self.textureSample = textureSample
        self.textureName = textureName
    }

    /// The fragment program (and every viewer program): a `constant Uniforms &u` buffer.
    public static let fragment = EmitEnvironment(
        uniform: { f in f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)" },
        sys: ["uv": "in.uv", "time": "u.time", "resolution": "u.resolution", "mouse": "u.mouse"])

    /// Inside a group function (spec §20.4): uniforms are parameters named after their slot's
    /// path, so the function is the same whatever the caller's target.
    public static let groupFunction = EmitEnvironment(
        uniform: { f in
            guard let p = f.path else { return f.name }
            return GroupCodegen.parameterName(for: p)
        },
        sys: ["uv": "uv", "time": "time", "resolution": "size", "mouse": "mouse"],
        textureSample: { slot, uv in flippedSample(slot.parameterName, uv) },
        textureName: { $0.parameterName })

    /// Inside a stitchable function: uniforms are arguments named after their slots; SwiftUI has
    /// no int/bool `Shader.Argument`, so those arrive as `float` and are cast on read, and
    /// `.color(_:)` arrives as a premultiplied `half4` that is widened to `float4`.
    public static let stitchableFunction = EmitEnvironment(
        uniform: { f in
            switch f.type {
            case .bool: "bool(\(f.name))"
            case .int: "int(\(f.name))"
            case .color: "float4(\(f.name))"
            default: f.name
            }
        },
        sys: ["uv": "uv", "time": "time", "resolution": "size", "mouse": "mouse"])

    /// The exported Layer Effect function (spec §21.2): there is no asset to bind, so every
    /// Texture Sample reads the layer SwiftUI hands the effect. Alpha comes from the layer too.
    /// `Layer::sample` yields a `half4` and MSL widens neither vectors nor their element type
    /// implicitly, so the sample is spelled with the conversion the surrounding `float4` needs.
    public static let layerExport = EmitEnvironment(
        uniform: stitchableFunction.uniform,
        sys: stitchableFunction.sys,
        textureSample: { _, _ in "float4(layer.sample(position))" },
        textureName: { _ in "layer" })
}
