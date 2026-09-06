import Foundation

/// One texture binding of a generated program (spec §21.2): a distinct asset, or the shared
/// `nil` slot every unassigned Texture Sample reads (the renderer binds a placeholder there).
///
/// The fragment program numbers its slots and binds them by index; a group function receives
/// them as parameters and so refers to them by asset instead — indices inside a function are
/// meaningless, because the root program assigns the real ones when it dedupes.
public struct TextureSlot: Sendable, Hashable, Codable {
    public let index: Int
    public let asset: AssetID?

    public init(index: Int, asset: AssetID?) { self.index = index; self.asset = asset }

    /// `tex0` in the fragment program.
    public var fragmentName: String { "tex\(index)" }

    /// `t_<8hex>` / `t_none` as a group-function parameter.
    public var parameterName: String {
        asset.map { "t_" + String($0.raw.uuidString.prefix(8)).lowercased() } ?? "t_none"
    }
}
