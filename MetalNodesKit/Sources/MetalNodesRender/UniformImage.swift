import Foundation
import MetalNodesCore

/// CPU-side bytes for one `Uniforms` struct. Copied into a GPU buffer every frame.
public struct UniformImage: Sendable, Equatable {
    public let layout: UniformLayout
    public private(set) var bytes: [UInt8]

    public init(layout: UniformLayout) {
        self.layout = layout
        bytes = [UInt8](repeating: 0, count: layout.totalSize)
    }

    @discardableResult
    public mutating func set(_ value: ParamValue, for path: ParamPath) -> Bool {
        guard let f = layout.field(for: path) else { return false }
        write(value, into: f)
        return true
    }

    public mutating func setReserved(time: Float, resolution: SIMD2<Float>, mouse: SIMD2<Float>) {
        write(.float(time), into: layout.reserved("time"))
        write(.float2(resolution), into: layout.reserved("resolution"))
        write(.float2(mouse), into: layout.reserved("mouse"))
    }

    /// Manual low/high for normalizing a viewed float/int socket (spec §19.3). A no-op when the
    /// layout has no viewer fields (a non-viewer program).
    public mutating func setViewerRange(_ r: ClosedRange<Float>) {
        guard layout.hasReserved("viewerMin") else { return }
        write(.float(r.lowerBound), into: layout.reserved("viewerMin"))
        write(.float(r.upperBound), into: layout.reserved("viewerMax"))
    }

    /// Fresh image from the document: every field takes the instance's stored
    /// value, else the definition's default. Called on every pipeline publish.
    public static func rebuild(layout: UniformLayout, document: ShaderDocument, registry: NodeRegistry) -> UniformImage {
        var img = UniformImage(layout: layout)
        for f in layout.fields {
            guard let path = f.path, let nodeID = path.instancePath.first,
                  let inst = document.root.nodes[nodeID], case .builtin(let defID) = inst.kind,
                  let def = registry[defID] else { continue }
            if let v = inst.params[path.param] {
                img.write(v, into: f)
            } else if let decl = def.input(named: path.param), case .value(let v) = decl.default {
                img.write(v, into: f)
            } else if let p = def.param(named: path.param) {
                img.write(p.defaultValue, into: f)
            }
        }
        return img
    }

    // MARK: - Coercion

    private static func components(_ v: ParamValue) -> [Float] {
        switch v {
        case .float(let x): [x]
        case .float2(let s): [s.x, s.y]
        case .float3(let s): [s.x, s.y, s.z]
        case .float4(let s): [s.x, s.y, s.z, s.w]
        case .int(let i): [Float(i)]
        case .bool(let b): [b ? 1 : 0]
        case .enumCase, .asset: []
        }
    }

    private mutating func write(_ value: ParamValue, into f: UniformField) {
        let src = UniformImage.components(value)
        guard !src.isEmpty else { return }
        switch f.type {
        case .int:
            // Round and clamp in Double: Float(Int32.max) rounds to 2^31 (not exactly
            // representable in Float), which would still trap on conversion back to
            // Int32. Double represents every Int32 exactly, so the clamp is safe there.
            let d = Double(src[0])
            let r = d.isNaN ? 0 : d.rounded()
            let clamped = min(max(r, Double(Int32.min)), Double(Int32.max))
            put(Int32(clamped), at: f.offset)
        case .bool:
            put(Int32(src[0] != 0 ? 1 : 0), at: f.offset)
        case .float:
            put(src[0], at: f.offset)
        case .float2, .float3, .float4, .color:
            let n = f.type.componentCount ?? 1
            var out = [Float](repeating: 0, count: n)
            if src.count == 1 {
                out = [Float](repeating: src[0], count: n)
            } else {
                for i in 0..<n { out[i] = i < src.count ? src[i] : (i == 3 ? 1 : 0) }
            }
            for (i, x) in out.enumerated() { put(x, at: f.offset + i * 4) }
        case .texture:
            break
        }
    }

    private mutating func put<T>(_ x: T, at offset: Int) {
        withUnsafeBytes(of: x) { raw in
            for (i, b) in raw.enumerated() { bytes[offset + i] = b }
        }
    }
}
