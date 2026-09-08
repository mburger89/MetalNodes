import Foundation

/// Identifies one uniform-backed value: a node instance path plus a socket/param name.
public struct ParamPath: Hashable, Sendable, Codable {
    public var instancePath: [NodeID]
    public var param: ParamID
    public init(node: NodeID, param: ParamID) { instancePath = [node]; self.param = param }
    public init(instancePath: [NodeID], param: ParamID) { self.instancePath = instancePath; self.param = param }
}

public struct UniformField: Sendable, Hashable {
    public let name: String
    public let mslType: String
    public let offset: Int
    public let size: Int
    public let type: SocketType
    public let path: ParamPath?
}

public struct UniformLayout: Sendable, Hashable {
    public let fields: [UniformField]
    public let totalSize: Int
    private let byPath: [ParamPath: Int]

    init(fields: [UniformField], totalSize: Int) {
        self.fields = fields
        self.totalSize = totalSize
        var m: [ParamPath: Int] = [:]
        for (i, f) in fields.enumerated() { if let p = f.path { m[p] = i } }
        byPath = m
    }

    public func field(for path: ParamPath) -> UniformField? { byPath[path].map { fields[$0] } }

    /// `field(for:)`, narrowed to the one further question that decides whether a path marked live
    /// (`DocumentSettings.liveParameters`, spec §24.6) can actually read the `CustomMaterial`'s
    /// `float4` there: the field must exist — something in the graph requests it, or a rewired or
    /// hand-edited path requests nothing — and it must be `.float`, since a `float2`/`float3`/
    /// `float4`/`.color`/`.int`/`.bool` field has no legal single-component read from that `float4`.
    ///
    /// This is the *one* place that second question is asked. `EmitEnvironment.bakedUniforms`'s
    /// substitution and `MaterialExport.liveParameters`'s export filter both call this rather than
    /// each re-spelling `field(for: path)?.type == .float` inline — two copies of that condition
    /// drifted apart once already (`vector.dot`, fix round 2): the export's filter checked field
    /// existence alone while the emitter's substitution also checked `.float`, and a live path whose
    /// generic input resolved to a vector slipped through the export's weaker filter and was
    /// documented and seeded for a component the `.metal` never actually read live. A single
    /// predicate can't drift from itself; asserting by doc comment that two independent spellings
    /// "happen to agree" is the same shape of bug this method exists to close, one level up.
    public func liveField(for path: ParamPath) -> UniformField? {
        guard let f = field(for: path), f.type == .float else { return nil }
        return f
    }

    /// Names of the path-less (reserved) fields, in struct order.
    public var reservedNames: [String] { fields.filter { $0.path == nil }.map(\.name) }

    public func hasReserved(_ name: String) -> Bool { fields.contains { $0.path == nil && $0.name == name } }

    public func reserved(_ name: String) -> UniformField {
        guard let f = fields.first(where: { $0.path == nil && $0.name == name }) else {
            preconditionFailure("unknown reserved uniform \(name)")
        }
        return f
    }

    public var mslStruct: String {
        var s = "struct Uniforms {\n"
        for f in fields { s += "    \(f.mslType) \(f.name);\n" }
        s += "};"
        return s
    }
}

public enum UniformLayoutBuilder {
    public typealias Reserved = (name: String, type: SocketType)

    /// Every program has these three (spec §9.6).
    public static let standardReserved: [Reserved] = [("resolution", .float2), ("mouse", .float2), ("time", .float)]
    /// Viewer programs add the manual range for float/int visualisation (spec §19.3).
    public static let viewerReserved: [Reserved] = standardReserved + [("viewerMin", .float), ("viewerMax", .float)]

    public static func build(_ requests: [(path: ParamPath, type: SocketType)],
                             reserved: [Reserved] = standardReserved) -> UniformLayout {
        struct Pending { let path: ParamPath?; let name: String?; let type: SocketType }
        var pending: [Pending] = reserved.map { Pending(path: nil, name: $0.name, type: $0.type) }
        pending += requests.filter { $0.type.isUniformable }.map { Pending(path: $0.path, name: nil, type: $0.type) }

        // Stable sort, alignment descending.
        let sorted = pending.enumerated()
            .sorted { (a, b) in
                let aa = a.element.type.alignment ?? 0, ba = b.element.type.alignment ?? 0
                return aa != ba ? aa > ba : a.offset < b.offset
            }
            .map(\.element)

        var fields: [UniformField] = []
        var cursor = 0
        var userIndex = 0
        for p in sorted {
            let size = p.type.byteSize ?? 0, align = p.type.alignment ?? 1
            cursor = (cursor + align - 1) / align * align
            let name = p.name ?? "p\(userIndex)"
            if p.name == nil { userIndex += 1 }
            fields.append(UniformField(name: name, mslType: p.type.uniformStorageName ?? p.type.mslName,
                                       offset: cursor, size: size, type: p.type, path: p.path))
            cursor += size
        }
        let total = max(16, (cursor + 15) / 16 * 16)
        return UniformLayout(fields: fields, totalSize: total)
    }
}
