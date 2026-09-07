import Foundation
import Metal
import MetalNodesCore

/// A ready-to-draw pipeline plus the shader it was built from.
/// `MTLRenderPipelineState` is documented thread-safe, hence `@unchecked`.
public struct CompiledPipeline: @unchecked Sendable {
    public let state: MTLRenderPipelineState
    public let shader: GeneratedShader
    public let generation: UInt64
    /// Depth testing for a 3D program (spec §23.5); `nil` for the fullscreen path. Every pipeline
    /// *declares* the depth attachment (`pipelineDescriptor`), because the view always presents
    /// one — but a 2D program leaves the state unset, so Metal's default never tests and never
    /// writes.
    public let depthStencilState: MTLDepthStencilState?

    public init(state: MTLRenderPipelineState, shader: GeneratedShader, generation: UInt64,
                depthStencilState: MTLDepthStencilState? = nil) {
        self.state = state; self.shader = shader; self.generation = generation
        self.depthStencilState = depthStencilState
    }
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

    /// The 3D preview's depth attachment (spec §23.5). `MTKView.depthStencilPixelFormat` must match.
    public static let depthPixelFormat: MTLPixelFormat = .depth32Float

    /// The pipeline shape **every** preview program is built with, 2D and 3D alike.
    ///
    /// `PreviewView` gives its `MTKView` a `depthStencilPixelFormat` unconditionally, so the render
    /// pass it hands the renderer always carries a depth attachment. One `MTKView` outlives any
    /// number of programs and the document's target changes under it — and a *dived* viewer under
    /// `.realityKit` generates a program whose `target` is `.fragment` (`ShaderGenerator`), so a 2D
    /// pipeline can be the one drawing while a material document is open. Declaring the attachment
    /// only on the 3D pipelines therefore means Metal's validation layer — on by default for
    /// Xcode's Debug Run action — aborting on `setRenderPipelineState` with "the render pipeline's
    /// pixelFormat (MTLPixelFormatInvalid) does not match the framebuffer's pixelFormat".
    ///
    /// Making the *pass shape* the invariant and the pipeline unconditional is the cheaper half of
    /// that contract: the format costs a 2D program nothing at draw time, because
    /// `CompiledPipeline.depthStencilState` stays `nil` for them and Metal's default depth state
    /// never tests and never writes. The alternative — re-deriving the view's format from the live
    /// document — would have to stay in step with an asynchronous compile, and would still be wrong
    /// for the frame in between.
    ///
    /// It still takes the shader although the result no longer varies with it: that invariance is
    /// the contract, and a test asserts it holds for a 2D program as well as a 3D one.
    static func pipelineDescriptor(for shader: GeneratedShader, vertex: MTLFunction?,
                                   fragment: MTLFunction?,
                                   pixelFormat: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.depthAttachmentPixelFormat = depthPixelFormat
        return desc
    }

    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let pixelFormat: MTLPixelFormat
    private var cache: [CacheKey: MTLRenderPipelineState] = [:]
    private var lru: [CacheKey] = []          // least recent first
    public let cacheLimit: Int

    // A `lazy var` inside an `actor` is fine — access is already serialized.
    private lazy var depthState: MTLDepthStencilState? = {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }()

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
            // A 3D program brings its own vertex stage — that is what makes a geometry modifier
            // visible in the preview (spec §23.5). Every 2D program uses the static one compiled
            // in `init`.
            let vertex: MTLFunction
            if shader.vertexFunctionName == VertexStage.functionName {
                vertex = vertexFunction
            } else if let generated = lib.makeFunction(name: shader.vertexFunctionName) {
                vertex = generated
            } else {
                throw ShaderCompilerError.vertexFunctionMissing
            }
            let desc = ShaderCompiler.pipelineDescriptor(for: shader, vertex: vertex, fragment: frag,
                                                         pixelFormat: pixelFormat)
            let state = try await device.makeRenderPipelineState(descriptor: desc)
            insert(key, state)
            return finish(state, shader, generation)
        } catch {
            let msg = error.localizedDescription
            return .failure(message: msg, lines: ShaderCompiler.parseLines(msg), generation: generation)
        }
    }

    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        .success(CompiledPipeline(state: state, shader: shader, generation: generation,
                                  depthStencilState: shader.target == .realityKit ? depthState : nil))
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
