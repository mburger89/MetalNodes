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

@Suite @MainActor struct PreviewState3DTests {
    @Test func meshAndOrbitHaveDefaults() {
        let s = PreviewState()
        #expect(s.mesh == .sphere)
        #expect(s.orbit == OrbitCamera.default)
    }

    @Test func meshBuffersAreCachedPerMesh() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resources = MeshResources(device: device)
        let a = try #require(resources.buffers(for: .sphere))
        let b = try #require(resources.buffers(for: .sphere))
        #expect(a.vertices === b.vertices)
        #expect(a.indexCount == b.indexCount)
        let c = try #require(resources.buffers(for: .cube))
        #expect(a.vertices !== c.vertices)
        #expect(c.indexCount == 36)   // six faces, two triangles each
    }

    @Test func everyMeshProducesBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resources = MeshResources(device: device)
        for mesh in PreviewMesh.allCases {
            let b = try #require(resources.buffers(for: mesh), "\(mesh)")
            #expect(b.indexCount > 0, "\(mesh)")
        }
    }
}

@Suite @MainActor struct PreviewClockTests {
    @Test func theClockStartsAtTheDefaultTimelineInWallClockMode() {
        let s = PreviewState()
        #expect(s.clock.timeline == Timeline())
        #expect(s.clock.mode == .wallClock)
        #expect(s.clock.frame == 0)
        #expect(s.clock.isPlaying)
    }

    @Test func theDrawRateFollowsAFixedRateTimeline() {
        #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 24), mode: .fixedRate)) == 24)
        #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 30), mode: .fixedRate)) == 30)
        #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 24), mode: .wallClock)) == 60)
    }

    @Test func wallClockAdvanceIsNilUntilTheFrameChanges() throws {
        let c = TimelineClock(timeline: Timeline(duration: 1, frameRate: 24), mode: .wallClock)
        #expect(c.frame == 0)
        #expect(ShaderRenderer.wallClockAdvance(c, elapsed: 0.01) == nil)
        let advanced = try #require(ShaderRenderer.wallClockAdvance(c, elapsed: 0.05))
        #expect(advanced.frame == 1)
        #expect(ShaderRenderer.wallClockAdvance(advanced, elapsed: 0.06) == nil)
    }

    @Test func wallClockAdvanceReportsAStopEvenWithoutAFrameChange() throws {
        var c = TimelineClock(timeline: Timeline(duration: 1, frameRate: 60, loops: false), mode: .wallClock)
        c.frame = 59
        #expect(c.isPlaying)
        let stopped = try #require(ShaderRenderer.wallClockAdvance(c, elapsed: 1.0))
        #expect(stopped.isPlaying == false)
    }
}
