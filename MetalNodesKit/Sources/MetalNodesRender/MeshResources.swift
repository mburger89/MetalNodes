import Foundation
import Metal
import MetalNodesCore

/// GPU buffers for the preview meshes, built on first use and kept (spec §23.5). Four small
/// meshes; there is nothing to evict.
@MainActor
public final class MeshResources {
    public struct Buffers {
        public let vertices: MTLBuffer
        public let indices: MTLBuffer
        public let indexCount: Int
    }

    private let device: MTLDevice
    private var cache: [PreviewMesh: Buffers] = [:]

    public init(device: MTLDevice) { self.device = device }

    public func buffers(for mesh: PreviewMesh) -> Buffers? {
        if let hit = cache[mesh] { return hit }
        let (vertices, indices) = MeshBuilder.build(mesh)
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<MeshVertex>.stride * vertices.count,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices,
                                         length: MemoryLayout<UInt16>.stride * indices.count,
                                         options: .storageModeShared) else { return nil }
        let b = Buffers(vertices: vb, indices: ib, indexCount: indices.count)
        cache[mesh] = b
        return b
    }
}
