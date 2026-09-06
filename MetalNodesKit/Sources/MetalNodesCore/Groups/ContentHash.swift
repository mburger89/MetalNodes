import Foundation

/// 64-bit FNV-1a, hex. Deterministic across runs and platforms, which `Hasher` is not.
public enum ContentHash {
    public static func fnv1a(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
}
