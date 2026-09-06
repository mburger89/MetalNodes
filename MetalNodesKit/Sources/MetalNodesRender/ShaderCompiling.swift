import MetalNodesCore

/// Abstracts `ShaderCompiler` so the editor can be tested without a GPU.
public protocol ShaderCompiling: Sendable {
    func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult
}

extension ShaderCompiler: ShaderCompiling {}
