import Testing
import Metal
import MetalNodesCore
@testable import MetalNodesRender

@MainActor
@Suite struct PreviewStateTests {
    @Test func pipelineMirrorsTheProgram() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — this test needs a GPU")
        let compiler = try ShaderCompiler(device: device)
        let shader = try ShaderGenerator.generate(.starter(), registry: .builtin)
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1, fastMath: true) else {
            Issue.record("starter did not compile"); return
        }
        let state = PreviewState()
        #expect(state.pipeline == nil)
        state.program = PreviewProgram(pipeline: pipeline, textures: [:])
        #expect(state.pipeline?.generation == 1)
        #expect(state.program?.textures.isEmpty == true)
    }
}
