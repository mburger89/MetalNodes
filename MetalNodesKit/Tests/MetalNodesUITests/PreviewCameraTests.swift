import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

/// The 3D preview's camera controls, end of the chain the editor actually uses.
///
/// `OrbitCamera.dolly` was tested in isolation (`CameraUniformsTests.dollyingStaysPositiveAndBounded`)
/// and had **no caller** anywhere outside the tests, so spec §23.5's "scroll and pinch dolly" did
/// nothing and the camera distance was pinned at 3.0 unless a saved file carried another value.
/// Testing the method alone is what let that read as done, so these tests go through the model
/// entry points the view calls, and `dollyIsWiredIntoThePreviewOverlay` checks the wiring itself.
@Suite struct PreviewCameraTests {
    private func materialModel() -> EditorModel {
        var doc = ShaderDocument.sample()
        doc.settings.target = .realityKit
        return EditorModel(document: doc, compiler: RecordingCompiler())
    }

    @Test func scrollDolliesTheCamera() {
        let m = materialModel()
        let start = m.viewState.orbit.distance
        m.dollyPreview(by: 40)
        #expect(m.viewState.orbit.distance < start)          // positive delta pulls in, like the canvas zoom
        m.dollyPreview(by: -40)
        #expect(abs(m.viewState.orbit.distance - start) < 1e-5)
    }

    /// The camera is view state (spec §23.8, §18.3): mirrored into `PreviewState` for the next
    /// frame, persisted with the document, and never on the undo stack.
    @Test func dollyingIsViewStateAndNeverUndoable() {
        let m = materialModel()
        m.dollyPreview(by: 40)
        #expect(m.preview.orbit == m.viewState.orbit)
        #expect(!m.canUndo)
    }

    /// Gated on the target exactly as the orbit drag is — a scroll over a fragment document's
    /// preview means nothing here.
    @Test func dollyingDoesNothingUnderTheTwoDimensionalTargets() {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        #expect(m.document.settings.target == .fragment)
        m.dollyPreview(by: 40)
        #expect(m.viewState.orbit == .default)
    }

    /// `OrbitCamera.dolly`'s clamp still owns the bounds: no amount of scrolling loses the model or
    /// turns it inside out.
    @Test func dollyingStaysBounded() {
        let m = materialModel()
        for _ in 0..<200 { m.dollyPreview(by: 1000) }
        #expect(m.viewState.orbit.distance >= 0.5)
        for _ in 0..<200 { m.dollyPreview(by: -1000) }
        #expect(m.viewState.orbit.distance <= 20)
        m.dollyPreview(by: .nan)
        #expect(m.viewState.orbit.distance.isFinite)
    }

    /// A pinch reports a factor, not points. The conversion is exact: pinching by `r` divides the
    /// distance by `r`, so a pinch out and back lands where it started.
    @Test func pinchDolliesByItsFactor() {
        let m = materialModel()
        let start = m.viewState.orbit.distance
        m.magnifyPreview(by: 2)
        #expect(abs(m.viewState.orbit.distance - start / 2) < 1e-4)
        m.magnifyPreview(by: 0.5)
        #expect(abs(m.viewState.orbit.distance - start) < 1e-4)

        // Degenerate factors are ignored rather than propagated into the camera.
        m.magnifyPreview(by: 0)
        m.magnifyPreview(by: -1)
        #expect(abs(m.viewState.orbit.distance - start) < 1e-4)
    }

    @Test func pinchIsGatedOnTheTargetToo() {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.magnifyPreview(by: 2)
        #expect(m.viewState.orbit == .default)
    }

    /// The defect itself was an *unwired* control: every assertion above passes against a model
    /// nothing calls. SwiftUI bodies are not reachable from `swift test`, so the only check that
    /// would have caught it reads the view's source and asserts the entry points appear there.
    /// Skipped, not failed, when the source is not beside the test — the test binary can be run
    /// from a build that does not ship it.
    @Test func dollyIsWiredIntoThePreviewOverlay() throws {
        let view = URL(fileURLWithPath: #filePath)            // …/Tests/MetalNodesUITests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/MetalNodesUI/Editor/EditorView.swift")
        guard let source = try? String(contentsOf: view, encoding: .utf8) else {
            withKnownIssue("EditorView.swift not beside the tests") { Issue.record("skipped") }
            return
        }
        #expect(source.contains("model.dollyPreview("), "the scroll wheel must reach OrbitCamera.dolly")
        #expect(source.contains("model.magnifyPreview("), "the pinch must reach OrbitCamera.dolly")
        // And the orbit drag it sits beside, so a rewrite that drops one is visible here.
        #expect(source.contains("model.setOrbit("))
    }
}
