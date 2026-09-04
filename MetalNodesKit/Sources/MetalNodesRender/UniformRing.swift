import Metal

/// Triple-buffered uniform storage so the CPU never writes a buffer the GPU is reading.
@MainActor
public final class UniformRing {
    private let buffers: [MTLBuffer]
    private var index = 0
    public let size: Int

    public init(device: MTLDevice, size: Int, count: Int = 3) {
        self.size = size
        buffers = (0..<count).map { i in
            let b = device.makeBuffer(length: max(size, 16), options: .storageModeShared)!
            b.label = "Uniforms[\(i)]"
            return b
        }
    }

    public func next() -> MTLBuffer {
        index = (index + 1) % buffers.count
        return buffers[index]
    }
}
