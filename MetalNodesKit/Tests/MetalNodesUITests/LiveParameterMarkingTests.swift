import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

@Suite @MainActor struct LiveParameterMarkingTests {
    private func model(floats: Int) -> (EditorModel, [ParamPath]) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var paths: [ParamPath] = []
        for i in 0..<floats {
            var f = NodeInstance(kind: .builtin("input.float"), position: CGPoint(x: Double(i) * 20, y: 0))
            f.params["value"] = .float(Float(i))
            doc.root.nodes[f.id] = f
            paths.append(ParamPath(node: f.id, param: "value"))
        }
        return (EditorModel(document: doc, compiler: RecordingCompiler()), paths)
    }

    @Test func markingAParamAddsItInOrder() {
        let (m, p) = model(floats: 3)
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.toggleLiveParameter(p[2]))
        #expect(m.document.settings.liveParameters == [p[0], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
        #expect(m.liveParameterIndex(of: p[1]) == nil)
    }

    @Test func markingAgainUnmarksAndClosesTheGap() {
        let (m, p) = model(floats: 3)
        for path in p { _ = m.toggleLiveParameter(path) }
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.document.settings.liveParameters == [p[1], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
    }

    /// A CustomMaterial exposes one float4 — four floats, not five (spec §23.6, §24.5).
    @Test func theFifthIsRefusedWithANotice() {
        let (m, p) = model(floats: 5)
        for path in p.prefix(4) { #expect(m.toggleLiveParameter(path)) }
        #expect(!m.toggleLiveParameter(p[4]))
        #expect(m.document.settings.liveParameters.count == 4)
        #expect(m.notice != nil)
    }

    @Test func markingIsUndoable() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        m.undo()
        #expect(m.document.settings.liveParameters.isEmpty)
    }

    /// Deleting a marked node must not leave a live parameter pointing at nothing.
    @Test func deletingAMarkedNodeDropsItsLiveParameter() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        _ = m.toggleLiveParameter(p[1])
        // `ParamPath` has no `.node` accessor (that's `SocketRef`'s) — the node id is the first
        // (only, for these single-node paths) element of `instancePath`.
        m.apply(.removeNodes([p[0].instancePath[0]]))
        #expect(m.document.settings.liveParameters == [p[1]])
    }

    /// The component letter shown beside each marked param, and used by the export.
    @Test func componentLettersFollowTheOrder() {
        #expect(EditorModel.liveParameterComponent(0) == "x")
        #expect(EditorModel.liveParameterComponent(3) == "w")
    }
}
