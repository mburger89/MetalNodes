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
    public static let reservedNames = ["resolution", "mouse", "time"]

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
    public static func build(_ requests: [(path: ParamPath, type: SocketType)]) -> UniformLayout {
        struct Pending { let path: ParamPath?; let name: String?; let type: SocketType }
        var pending: [Pending] = [
            Pending(path: nil, name: "resolution", type: .float2),
            Pending(path: nil, name: "mouse", type: .float2),
            Pending(path: nil, name: "time", type: .float),
        ]
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
