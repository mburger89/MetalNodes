import Testing
@testable import MetalNodesCore

@Suite struct SocketTypeTests {
    @Test func mslNames() {
        #expect(SocketType.float.mslName == "float")
        #expect(SocketType.color.mslName == "float4")
        #expect(SocketType.texture.mslName == "texture2d<float>")
    }

    @Test func float3IsSixteenBytes() {
        #expect(SocketType.float3.byteSize == 16)
        #expect(SocketType.float3.alignment == 16)
    }

    @Test(arguments: [
        (SocketType.float, 4, 4), (.float2, 8, 8), (.float3, 16, 16), (.float4, 16, 16),
        (.color, 16, 16), (.int, 4, 4), (.bool, 4, 4),
    ])
    func sizeAndAlignment(type: SocketType, size: Int, alignment: Int) {
        #expect(type.byteSize == size)
        #expect(type.alignment == alignment)
    }

    @Test func boolIsStoredAsIntInUniforms() {
        #expect(SocketType.bool.uniformStorageName == "int")
    }

    @Test func textureIsNotUniformable() {
        #expect(SocketType.texture.isUniformable == false)
        #expect(SocketType.texture.byteSize == nil)
        #expect(SocketType.texture.uniformStorageName == nil)
    }

    @Test func componentCounts() {
        #expect(SocketType.float.componentCount == 1)
        #expect(SocketType.color.componentCount == 4)
        #expect(SocketType.texture.componentCount == nil)
    }
}
