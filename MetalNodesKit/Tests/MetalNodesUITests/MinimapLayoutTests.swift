import Testing
import CoreGraphics
@testable import MetalNodesUI

/// Pure geometry (spec §21.6): a 1000×500 graph in a 180×120 map fits width-limited, aspect
/// preserving, centred on the axis with room to spare.
@Suite struct MinimapLayoutTests {
    @Test func widthLimitedGraphIsCentredVertically() {
        let graphBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let layout = MinimapLayout(graphBounds: graphBounds, viewport: graphBounds)
        // (180 - 2*8) / 1000 = 0.164; (120 - 2*8) / 500 = 0.208 — width wins.
        #expect(abs(layout.scale - 0.164) < 1e-9)
        let mapped = layout.mapRect(graphBounds)
        // Full padding on the constrained axis, spare room split evenly on the other.
        #expect(abs(mapped.minX - 8) < 1e-9)
        #expect(abs(mapped.width - 164) < 1e-9)
        let verticalInset = (120 - graphBounds.height * layout.scale) / 2
        #expect(abs(mapped.minY - verticalInset) < 1e-9)
        #expect(verticalInset > 8)   // more than the base padding: vertically centred, not pinned
    }

    @Test func canvasPointRoundTripsThroughMapRectOrigin() {
        let graphBounds = CGRect(x: -200, y: 50, width: 1000, height: 500)
        let layout = MinimapLayout(graphBounds: graphBounds, viewport: graphBounds)
        let p = CGPoint(x: 137, y: 322)
        let mapped = layout.mapRect(CGRect(origin: p, size: .zero)).origin
        let back = layout.canvasPoint(mapped)
        #expect(abs(back.x - p.x) < 1e-6)
        #expect(abs(back.y - p.y) < 1e-6)
    }

    @Test func viewportOutsideGraphBoundsExtendsTheFittedArea() {
        let graphBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let farViewport = CGRect(x: 800, y: 0, width: 1000, height: 500)   // extends past the graph
        let extended = MinimapLayout(graphBounds: graphBounds, viewport: farViewport)
        let unextended = MinimapLayout(graphBounds: graphBounds, viewport: graphBounds)
        // The union is wider than the graph alone, so the fitted scale must shrink to fit it.
        #expect(extended.scale < unextended.scale)
        // The graph's own frame is still mapped inside the map bounds, just smaller/shifted.
        let mappedGraph = extended.mapRect(graphBounds)
        #expect(mappedGraph.minX >= 0 && mappedGraph.maxX <= 180)
    }

    @Test func defaultSizeIs180By120() {
        let layout = MinimapLayout(graphBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    viewport: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(layout.size == CGSize(width: 180, height: 120))
    }
}
