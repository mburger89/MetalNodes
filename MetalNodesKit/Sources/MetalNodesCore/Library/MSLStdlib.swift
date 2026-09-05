import Foundation

public struct MSLFunction: Sendable {
    public let name: String
    public let dependencies: [String]
    public let source: String
}

/// Hand-written MSL helpers pulled in by `NodeDef.requires`. Every function is
/// prefixed `mn_` so generated code can never collide with Metal's own names.
public enum MSLStdlib {
    public static let functions: [String: MSLFunction] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// Returns the closure of `names` over dependencies, dependencies first, each once.
    public static func resolve(_ names: [String]) -> [MSLFunction] {
        var out: [MSLFunction] = []
        var seen = Set<String>()
        func visit(_ n: String) {
            guard !seen.contains(n), let f = functions[n] else { return }
            seen.insert(n)
            f.dependencies.forEach(visit)
            out.append(f)
        }
        names.forEach(visit)
        return out
    }

    static let core: [MSLFunction] = [
        MSLFunction(name: "hash21", dependencies: [], source: """
        float mn_hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        """),
        MSLFunction(name: "valueNoise", dependencies: ["hash21"], source: """
        float mn_valueNoise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 s = f * f * (3.0 - 2.0 * f);
            float a = mn_hash21(i);
            float b = mn_hash21(i + float2(1.0, 0.0));
            float c = mn_hash21(i + float2(0.0, 1.0));
            float d = mn_hash21(i + float2(1.0, 1.0));
            return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
        }
        """),
    ]

    private static let all: [MSLFunction] = core + vector + sdf + noise
}
