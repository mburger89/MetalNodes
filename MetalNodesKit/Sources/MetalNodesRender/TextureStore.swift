import Foundation
import Metal
import MetalKit
import MetalNodesCore

/// Loads and caches the `MTLTexture`s a compiled program's texture slots bind (spec §21.2).
///
/// Textures are cached by `AssetID` so repeated draws (and repeated slot rebuilds) reuse the same
/// GPU object; `nil` assets and undecodable bytes fall back to a 2×2 magenta/black placeholder,
/// which is also what an unassigned Texture Sample's shared slot binds. Runs on the main actor —
/// the renderer that consumes it runs on the main thread.
@MainActor
public final class TextureStore {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private var cache: [AssetID: MTLTexture] = [:]
    public let placeholder: MTLTexture

    public init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
        self.placeholder = Self.makePlaceholder(device: device)
    }

    private static func makePlaceholder(device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)!
        let magenta: [UInt8] = [255, 0, 255, 255]
        let black: [UInt8] = [0, 0, 0, 255]
        let row0 = magenta + black
        let row1 = black + magenta
        let bytes = row0 + row1
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: 2 * 4)
        }
        return texture
    }

    /// The texture for `asset`, decoding `bytes` and caching the result. `nil` asset, `nil` bytes,
    /// or undecodable bytes all return `placeholder`.
    public func texture(for asset: AssetID?, bytes: Data?) -> MTLTexture {
        guard let asset else { return placeholder }
        if let cached = cache[asset] { return cached }
        guard let bytes,
              let texture = try? loader.newTexture(data: bytes, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        else { return placeholder }
        cache[asset] = texture
        return texture
    }

    /// Drops the cached texture for `asset`, forcing the next `texture(for:bytes:)` call to reload it.
    public func evict(_ asset: AssetID) {
        cache.removeValue(forKey: asset)
    }

    /// Resolves every slot of a compiled program to its texture, keyed by slot index, so the
    /// renderer can bind them with `setFragmentTexture(_:index:)`.
    public func bindings(for slots: [TextureSlot], textures: [AssetID: Data]) -> [Int: MTLTexture] {
        var result: [Int: MTLTexture] = [:]
        for slot in slots {
            result[slot.index] = texture(for: slot.asset, bytes: slot.asset.flatMap { textures[$0] })
        }
        return result
    }
}
