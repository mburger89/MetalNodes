import Testing
import Metal
import CoreGraphics
import ImageIO
import Foundation
import MetalNodesCore
@testable import MetalNodesRender

@MainActor
@Suite struct TextureStoreTests {
    static let device = MTLCreateSystemDefaultDevice()

    private func store() throws -> TextureStore {
        let d = try #require(Self.device, "No Metal device — these tests need a GPU")
        return TextureStore(device: d)
    }

    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", n))!) }

    /// A 4x4 RGBA PNG, built with CGImage + CGImageDestination.
    private func fourByFourPNG() -> Data {
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in 0..<16 {
            pixels[i * 4 + 0] = 255
            pixels[i * 4 + 1] = 0
            pixels[i * 4 + 2] = 0
            pixels[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4 * 4,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func placeholderIsTwoByTwo() throws {
        let s = try store()
        #expect(s.placeholder.width == 2)
        #expect(s.placeholder.height == 2)
    }

    @Test func nilAssetReturnsThePlaceholder() throws {
        let s = try store()
        let tex = s.texture(for: nil, bytes: nil)
        #expect(tex === s.placeholder)
    }

    @Test func garbageBytesReturnThePlaceholder() throws {
        let s = try store()
        let tex = s.texture(for: aid(1), bytes: Data([0, 1, 2, 3]))
        #expect(tex === s.placeholder)
    }

    @Test func missingBytesReturnThePlaceholder() throws {
        let s = try store()
        let tex = s.texture(for: aid(2), bytes: nil)
        #expect(tex === s.placeholder)
    }

    @Test func validPNGDecodesToAFourByFourTexture() throws {
        let s = try store()
        let tex = s.texture(for: aid(3), bytes: fourByFourPNG())
        #expect(tex.width == 4)
        #expect(tex.height == 4)
    }

    @Test func decodedTextureIsCachedByAsset() throws {
        let s = try store()
        let a = aid(4)
        let bytes = fourByFourPNG()
        let first = s.texture(for: a, bytes: bytes)
        let second = s.texture(for: a, bytes: bytes)
        #expect(first === second)
    }

    @Test func evictRemovesTheCachedEntry() throws {
        let s = try store()
        let a = aid(5)
        let bytes = fourByFourPNG()
        let first = s.texture(for: a, bytes: bytes)
        s.evict(a)
        let second = s.texture(for: a, bytes: bytes)
        #expect(first !== second)
    }

    @Test func bindingsMapsSlotIndicesToTextures() throws {
        let s = try store()
        let a = aid(6)
        let slots = [TextureSlot(index: 0, asset: nil), TextureSlot(index: 1, asset: a)]
        let textures: [AssetID: Data] = [a: fourByFourPNG()]
        let bindings = s.bindings(for: slots, textures: textures)
        #expect(bindings.count == 2)
        #expect(bindings[0] === s.placeholder)
        #expect(bindings[1]!.width == 4)
    }
}
