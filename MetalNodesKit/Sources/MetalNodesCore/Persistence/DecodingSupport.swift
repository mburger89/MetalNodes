import Foundation

extension Dictionary {
    /// Builds a dictionary from `pairs`, throwing `DecodingError.dataCorrupted` on the first
    /// repeated key. `Dictionary(uniqueKeysWithValues:)` traps instead, and a decoder is exactly
    /// where input from outside the process arrives (spec §27.2): a hand-merged `document.json`
    /// or a crafted pasteboard must fail with a message, never crash the app.
    static func uniqueOrThrow<S: Sequence>(_ pairs: S, codingPath: [any CodingKey],
                                          describe: (Key) -> String) throws -> Self
    where S.Element == (Key, Value) {
        var out = Self(minimumCapacity: pairs.underestimatedCount)
        for (key, value) in pairs {
            guard out.updateValue(value, forKey: key) == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: describe(key)))
            }
        }
        return out
    }
}
