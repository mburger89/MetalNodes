import Testing
import SwiftUI
@testable import MetalNodesUI
import MetalNodesCore

@Suite struct WireGeometryTests {
    @Test func controlOffsetGrowsWithDistanceButHasAFloor() {
        #expect(WireGeometry.controlOffset(from: .zero, to: CGPoint(x: 10, y: 0)) == 40)
        #expect(WireGeometry.controlOffset(from: .zero, to: CGPoint(x: 400, y: 0)) == 200)
        #expect(WireGeometry.controlOffset(from: CGPoint(x: 400, y: 0), to: .zero) == 200)
    }

    @Test func pathStartsAndEndsAtSockets() {
        let p = WireGeometry.path(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 100))
        let box = p.boundingRect
        #expect(box.minX == 0 && box.maxX == 300)
        #expect(box.minY >= 0 && box.maxY <= 100)
    }

    @Test func anchorPreferenceMergesDictionaries() {
        let a = NodeID(), b = NodeID()
        var v: [SocketRef: CGPoint] = [SocketRef(a, "x"): .zero]
        SocketAnchorKey.reduce(value: &v) { [SocketRef(b, "y"): CGPoint(x: 1, y: 1)] }
        #expect(v.count == 2)
    }

    @Test func distanceIsZeroOnTheCurveAndGrowsAway() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 300, y: 100)
        let mid = WireGeometry.point(t: 0.5, from: a, to: b)
        #expect(WireGeometry.distance(from: mid, wireFrom: a, to: b) < 1.0)
        #expect(WireGeometry.distance(from: CGPoint(x: 150, y: -200), wireFrom: a, to: b) > 100)
        #expect(WireGeometry.distance(from: a, wireFrom: a, to: b) == 0)
    }
}
