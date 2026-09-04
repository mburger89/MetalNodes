import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct CanvasTransformTests {
    @Test func screenCanvasRoundTrip() {
        let t = CanvasTransform(pan: CGSize(width: 100, height: -40), zoom: 2)
        let p = CGPoint(x: 37, y: 91)
        let back = t.toCanvas(t.toScreen(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        #expect(t.toScreen(.zero) == CGPoint(x: 100, y: -40))
    }

    @Test func zoomAroundKeepsAnchorFixed() {
        var t = CanvasTransform(pan: CGSize(width: 10, height: 10), zoom: 1)
        let anchor = CGPoint(x: 200, y: 150)
        let canvasUnderAnchor = t.toCanvas(anchor)
        t.zoom(by: 1.5, around: anchor)
        let after = t.toCanvas(anchor)
        #expect(abs(after.x - canvasUnderAnchor.x) < 1e-9 && abs(after.y - canvasUnderAnchor.y) < 1e-9)
        #expect(t.zoom == 1.5)
    }

    @Test func zoomIsClamped() {
        var t = CanvasTransform(pan: .zero, zoom: 1)
        t.zoom(by: 100, around: .zero)
        #expect(t.zoom == CanvasTransform.maxZoom)
        t.zoom(by: 0.0001, around: .zero)
        #expect(t.zoom == CanvasTransform.minZoom)
    }

    @Test func visibleRectInCanvasSpace() {
        let t = CanvasTransform(pan: CGSize(width: -100, height: -50), zoom: 2)
        let r = t.visibleRect(viewport: CGSize(width: 800, height: 600))
        #expect(r == CGRect(x: 50, y: 25, width: 400, height: 300))
    }

    @Test func cameraRoundTrip() {
        let cam = Camera(pan: CGSize(width: 3, height: 4), zoom: 0.5)
        #expect(CanvasTransform(camera: cam).camera == cam)
    }
}
