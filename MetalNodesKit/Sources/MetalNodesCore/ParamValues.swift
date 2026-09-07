import Foundation

/// What value a uniform slot holds right now, and how to spell it as MSL.
///
/// The lookup is the one `UniformImage.rebuild` has always used (spec §9.2): the instance's stored
/// param, else the socket's `.value` default, else the param declaration's default. It lives in
/// Core because the RealityKit export bakes the same values as literals (spec §23.6) and there
/// must be exactly one answer to "what is this slot worth".
public enum ParamValues {
    public static func value(for path: ParamPath, in doc: ShaderDocument, registry: NodeRegistry) -> ParamValue? {
        guard let nodeID = path.instancePath.first,
              let (inst, gpath) = doc.node(nodeID),
              let shape = doc.shape(of: inst, in: gpath, registry: registry) else { return nil }
        if let v = inst.params[path.param] { return v }
        if let decl = shape.input(named: path.param), case .value(let v) = decl.default { return v }
        if let p = shape.param(named: path.param) { return p.defaultValue }
        return nil
    }

    /// `value` spelled as an MSL literal of `type`. Components are coerced the way the uniform
    /// writer coerces them: a scalar splats, a longer vector truncates, a shorter one zero-fills
    /// (alpha fills with 1 for a colour).
    public static func mslLiteral(_ value: ParamValue, as type: SocketType) -> String {
        switch type {
        case .bool:
            if case .bool(let b) = value { return b ? "true" : "false" }
            return components(value).first.map { $0 != 0 ? "true" : "false" } ?? "false"
        case .int:
            if case .int(let i) = value { return "\(i)" }
            return "\(int32(from: components(value).first ?? 0))"
        case .float:
            return f(components(value).first ?? 0)
        case .float2:
            let c = fit(components(value), 2, fillAlpha: false)
            return "float2(\(c.map(f).joined(separator: ", ")))"
        case .float3:
            let c = fit(components(value), 3, fillAlpha: false)
            return "float3(\(c.map(f).joined(separator: ", ")))"
        case .float4, .color:
            let c = fit(components(value), 4, fillAlpha: true)
            return "float4(\(c.map(f).joined(separator: ", ")))"
        case .texture:
            return "/* texture */"
        }
    }

    /// A float that always reads as a float in MSL: never `1`, always `1.0`.
    private static func f(_ x: Float) -> String {
        let s = "\(x)"
        return s.contains(".") || s.contains("e") || s.contains("n") ? s : s + ".0"
    }

    /// The one rule for coercing a float into the `Int32` an int slot holds: NaN clamps to 0,
    /// everything else rounds to nearest and then clamps into the `Int32` range. `UniformImage`'s
    /// byte writer must use exactly this rule too — a literal and its byte must never disagree on
    /// what an int slot is worth. Rounding and clamping happen in `Double`, which represents every
    /// `Int32` exactly (unlike `Float`, where `Float(Int32.max)` itself rounds to 2^31 and would
    /// still trap on conversion back to `Int32`), so `Int32(clamped)` below can never trap.
    public static func int32(from x: Float) -> Int32 {
        let d = Double(x)
        let r = d.isNaN ? 0 : d.rounded()
        let clamped = min(max(r, Double(Int32.min)), Double(Int32.max))
        return Int32(clamped)
    }

    private static func components(_ v: ParamValue) -> [Float] {
        switch v {
        case .float(let x): [x]
        case .float2(let s): [s.x, s.y]
        case .float3(let s): [s.x, s.y, s.z]
        case .float4(let s): [s.x, s.y, s.z, s.w]
        case .int(let i): [Float(i)]
        case .bool(let b): [b ? 1 : 0]
        case .enumCase, .asset, .text: []
        }
    }

    /// One component splats; a short list fills with 0 (or 1 in alpha); a long one truncates.
    ///
    /// An *empty* list (an `.enumCase`/`.asset` value under a vector slot — hand-edited or
    /// migrated) is the one case a literal cannot handle the way `UniformImage.write` does: the
    /// byte writer just no-ops and leaves the field at its zero-initialized bytes, but a literal
    /// has no "leave it alone" — it must spell *something*. We match the byte writer's result
    /// exactly (all-zero) rather than invent a different answer such as alpha-1: same input, same
    /// value, deliberately, not by accident.
    private static func fit(_ c: [Float], _ n: Int, fillAlpha: Bool) -> [Float] {
        if c.isEmpty { return Array(repeating: 0, count: n) }
        if c.count == 1 { return Array(repeating: c[0], count: n) }
        if c.count >= n { return Array(c.prefix(n)) }
        var out = c
        while out.count < n { out.append(fillAlpha && out.count == 3 ? 1 : 0) }
        return out
    }
}
