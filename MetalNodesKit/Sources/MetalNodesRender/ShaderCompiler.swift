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

public struct CompileLine: Sendable, Hashable {
    public let line: Int
    public let message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

public enum CompileResult: Sendable {
    case success(CompiledPipeline)
    case failure(message: String, lines: [CompileLine], generation: UInt64)
    case superseded(generation: UInt64)
}

public enum ShaderCompilerError: Error { case vertexFunctionMissing, fragmentFunctionMissing }

/// Compiles generated MSL off the main actor. Caches by source; latest generation wins (spec §9.6, §10).
public actor ShaderCompiler {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let pixelFormat: MTLPixelFormat
    private var cache: [String: MTLRenderPipelineState] = [:]
    private var latestRequested: UInt64 = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        let lib = try device.makeLibrary(source: VertexStage.source, options: nil)
        guard let fn = lib.makeFunction(name: VertexStage.functionName) else { throw ShaderCompilerError.vertexFunctionMissing }
        vertexFunction = fn
    }

    public var cacheCount: Int { cache.count }

    public func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult {
        latestRequested = max(latestRequested, generation)

        if let hit = cache[shader.source] {
            return finish(hit, shader, generation)
        }
        do {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            let lib = try await device.makeLibrary(source: shader.source, options: options)
            guard let frag = lib.makeFunction(name: shader.fragmentFunctionName) else {
                throw ShaderCompilerError.fragmentFunctionMissing
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let state = try await device.makeRenderPipelineState(descriptor: desc)
            cache[shader.source] = state
            return finish(state, shader, generation)
        } catch {
            let msg = error.localizedDescription
            return .failure(message: msg, lines: ShaderCompiler.parseLines(msg), generation: generation)
        }
    }

    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        generation < latestRequested
            ? .superseded(generation: generation)
            : .success(CompiledPipeline(state: state, shader: shader, generation: generation))
    }

    /// Pulls `program_source:LINE:COL: (error|warning): message` entries out of a Metal compiler message.
    public static func parseLines(_ message: String) -> [CompileLine] {
        let pattern = /program_source:(\d+):\d+:\s*(?:error|warning|note):\s*([^\n]*)/
        return message.matches(of: pattern).compactMap { m in
            Int(m.1).map { CompileLine(line: $0, message: String(m.2).trimmingCharacters(in: .whitespaces)) }
        }
    }
}
