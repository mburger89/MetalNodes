import Foundation
import Metal
import MetalNodesCore

/// A ready-to-draw pipeline plus the shader it was built from.
/// `MTLRenderPipelineState` is documented thread-safe, hence `@unchecked`.
public struct CompiledPipeline: @unchecked Sendable {
    public let state: MTLRenderPipelineState
    public let shader: GeneratedShader
    public let generation: UInt64
}

public enum CompileSeverity: String, Sendable, Hashable {
    case error, warning, note
}

public struct CompileLine: Sendable, Hashable {
    public let line: Int
    public let severity: CompileSeverity
    public let message: String
    public init(line: Int, severity: CompileSeverity = .error, message: String) {
        self.line = line; self.severity = severity; self.message = message
    }
}

public enum CompileResult: Sendable {
    case success(CompiledPipeline)
    case failure(message: String, lines: [CompileLine], generation: UInt64)
    /// A compile the producer abandoned. `ShaderCompiler` never returns it — generations belong to
    /// each document, not to the shared compiler — but clients still handle it (test doubles use it).
    case superseded(generation: UInt64)
}

public enum ShaderCompilerError: Error { case vertexFunctionMissing, fragmentFunctionMissing }

/// Compiles generated MSL off the main actor. LRU cache keyed by (source, fastMath) (spec §9.6, §10, §18.1).
///
/// One compiler is shared by every open document, so it holds no notion of a "latest" generation:
/// generations are per-`EditorModel` counters and are only echoed back here. Each client drops its
/// own stale results (`EditorModel.compileNow` compares the echoed generation against its own).
public actor ShaderCompiler {
    private struct CacheKey: Hashable { let source: String; let fastMath: Bool }

    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let pixelFormat: MTLPixelFormat
    private var cache: [CacheKey: MTLRenderPipelineState] = [:]
    private var lru: [CacheKey] = []          // least recent first
    public let cacheLimit: Int

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm, cacheLimit: Int = 64) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.cacheLimit = max(1, cacheLimit)
        let lib = try device.makeLibrary(source: VertexStage.source, options: nil)
        guard let fn = lib.makeFunction(name: VertexStage.functionName) else { throw ShaderCompilerError.vertexFunctionMissing }
        vertexFunction = fn
    }

    public var cacheCount: Int { cache.count }

    public func isCached(_ shader: GeneratedShader, fastMath: Bool = true) -> Bool {
        cache[CacheKey(source: shader.source, fastMath: fastMath)] != nil
    }

    public func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool = true) async -> CompileResult {
        let key = CacheKey(source: shader.source, fastMath: fastMath)

        if let hit = cache[key] {
            touch(key)
            return finish(hit, shader, generation)
        }
        do {
            let options = MTLCompileOptions()
            // Fast math is a document-level choice (spec §18.1): it relaxes NaN/Inf/denormal
            // semantics for every node. `.safe` keeps IEEE behaviour.
            options.mathMode = fastMath ? .fast : .safe
            let lib = try await device.makeLibrary(source: shader.source, options: options)
            guard let frag = lib.makeFunction(name: shader.fragmentFunctionName) else {
                throw ShaderCompilerError.fragmentFunctionMissing
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let state = try await device.makeRenderPipelineState(descriptor: desc)
            insert(key, state)
            return finish(state, shader, generation)
        } catch {
            let msg = error.localizedDescription
            return .failure(message: msg, lines: ShaderCompiler.parseLines(msg), generation: generation)
        }
    }

    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        .success(CompiledPipeline(state: state, shader: shader, generation: generation))
    }

    private func touch(_ key: CacheKey) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func insert(_ key: CacheKey, _ state: MTLRenderPipelineState) {
        cache[key] = state
        touch(key)
        while lru.count > cacheLimit {
            let evicted = lru.removeFirst()
            cache[evicted] = nil
        }
    }

    /// Pulls `program_source:LINE:COL: (error|warning|note): message` entries out of a Metal compiler message.
    public static func parseLines(_ message: String) -> [CompileLine] {
        let pattern = /program_source:(\d+):\d+:\s*(error|warning|note):\s*([^\n]*)/
        return message.matches(of: pattern).compactMap { m in
            guard let line = Int(m.1), let sev = CompileSeverity(rawValue: String(m.2)) else { return nil }
            return CompileLine(line: line, severity: sev, message: String(m.3).trimmingCharacters(in: .whitespaces))
        }
    }
}
