import Foundation
import Metal
import MetalNodesCore
import Synchronization

/// GPU buffers for the preview meshes, built on first use and kept (spec §23.5). Four small
/// meshes; there is nothing to evict. Not actor-isolated: the live view draws on the main actor
/// and `ExportSession` encodes off it, and both go through the same `FrameRenderer.encode` — the
/// cache is guarded by a mutex instead so neither has to hop.
public final class MeshResources: Sendable {
    /// `@unchecked` because `MTLBuffer` predates `Sendable`; these are immutable once built and
    /// Metal buffers are safe to read from any thread.
    public struct Buffers: @unchecked Sendable {
        public let vertices: MTLBuffer
        public let indices: MTLBuffer
        public let indexCount: Int
    }

    private let device: MTLDevice
    /// Build-on-miss happens under the lock: four meshes, built once each, and a duplicate build
    /// would waste GPU memory.
    private let cache = Mutex<[PreviewMesh: Buffers]>([:])

    public init(device: MTLDevice) { self.device = device }

    public func buffers(for mesh: PreviewMesh) -> Buffers? {
        cache.withLock { cache in
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
}
