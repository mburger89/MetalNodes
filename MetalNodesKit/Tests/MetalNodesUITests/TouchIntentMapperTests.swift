import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

/// Every row of the §22.2 gesture table, in every mode it behaves differently in, plus the
/// thresholds and the two "difference since the last report" gestures. Events carry **viewport**
/// points; the context's transform is at zoom 2 with a non-zero pan, so every canvas/viewport
/// conversion the mapper makes is exercised rather than being the identity.
@Suite struct TouchIntentMapperTests {
    let nodeID = NodeID()
    let wireOwner = NodeID()
    let sticky = CommentID.sticky(StickyID())
    let transform = CanvasTransform(pan: CGSize(width: 20, height: 10), zoom: 2)

    // Viewport points, and the canvas points they map to: (v.x - 20) / 2, (v.y - 10) / 2.
    let onNode = CGPoint(x: 120, y: 110)        // canvas (50, 50)
    let onComment = CGPoint(x: 520, y: 510)     // canvas (250, 250)
    let onSocket = CGPoint(x: 320, y: 310)      // canvas (150, 150)
    let onWire = CGPoint(x: 420, y: 410)        // canvas (200, 200)
    let onEmpty = CGPoint(x: 220, y: 210)       // canvas (100, 100)

    private var socketRef: SocketRef { SocketRef(nodeID, "out") }
    private var wireRef: SocketRef { SocketRef(wireOwner, "a") }
    private func canvas(_ p: CGPoint) -> CGPoint { transform.toCanvas(p) }

    /// The canvas's hit test, faked: the four canvas points above are the four kinds of hit and
    /// everything else is empty canvas.
    private var everything: [CGPoint: CanvasHit] {
        [canvas(onNode): .node(nodeID),
         canvas(onComment): .comment(sticky),
         canvas(onSocket): .socket(socketRef, isInput: false),
         canvas(onWire): .wire(wireRef)]
    }

    private func context(_ mode: CanvasMode, hits: [CGPoint: CanvasHit] = [:],
                         selected: [CanvasHit] = []) -> TouchContext {
        TouchContext(mode: mode, transform: transform,
                     hitTest: { hits[$0] ?? .empty },
                     isSelected: { selected.contains($0) })
    }

    // MARK: Tap

    @Test(arguments: [CanvasMode.pointer, .lasso])
    func tapOnANodeReplacesTheSelection(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onNode), in: context(mode, hits: everything)) == [.select(.node(nodeID), .replace)])
    }

    @Test func tapOnANodeTogglesItInSelectMode() {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onNode), in: context(.select, hits: everything)) == [.select(.node(nodeID), .toggle)])
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnACommentFollowsTheSameRuleAsANode(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let expected: SelectionMode = mode == .select ? .toggle : .replace
        #expect(m.map(.tap(onComment), in: context(mode, hits: everything)) == [.select(.comment(sticky), expected)])
    }

    /// A wire selection is a single ref in the model, so it always replaces — there is no
    /// "add this wire to the selection".
    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnAWireAlwaysReplaces(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onWire), in: context(mode, hits: everything)) == [.select(.wire(wireRef), .replace)])
    }

    /// A finger is 20 pt wide: a tap that lands on a socket means the node, not the wire drag.
    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnASocketSelectsItsNode(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let expected: SelectionMode = mode == .select ? .toggle : .replace
        #expect(m.map(.tap(onSocket), in: context(mode, hits: everything)) == [.select(.node(nodeID), expected)])
    }

    @Test(arguments: [CanvasMode.pointer, .lasso])
    func tapOnEmptyCanvasClearsTheSelection(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onEmpty), in: context(mode, hits: everything)) == [.clearSelection])
    }

    @Test func tapOnEmptyCanvasKeepsTheSelectionInSelectMode() {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onEmpty), in: context(.select, hits: everything)).isEmpty)
    }

    // MARK: Double tap and long press

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func doubleTapOnEmptyCanvasOpensTheChooserAtTheViewportPoint(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.doubleTap(onEmpty), in: context(mode, hits: everything)) == [.openChooser(at: onEmpty)])
    }

    @Test func doubleTapOnAnythingElseDoesNothing() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        #expect(m.map(.doubleTap(onNode), in: c).isEmpty)
        #expect(m.map(.doubleTap(onSocket), in: c).isEmpty)
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func longPressAlwaysOpensTheContextMenuWithWhatItHit(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        #expect(m.map(.longPress(onNode), in: c) == [.contextMenu(at: onNode, hit: .node(nodeID))])
        #expect(m.map(.longPress(onEmpty), in: c) == [.contextMenu(at: onEmpty, hit: .empty)])
    }

    // MARK: One-finger drag

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func dragOnAnUnselectedNodeSelectsItThenMoves(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        #expect(m.map(.dragBegan(onNode), in: c).isEmpty)
        let first = CGSize(width: 8, height: 0)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 8, y: onNode.y), translation: first), in: c)
                == [.select(.node(nodeID), .replace), .beginMove(.node(nodeID)), .move(first)])
        let second = CGSize(width: 20, height: 6)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 20, y: onNode.y + 6), translation: second), in: c)
                == [.move(second)])
        #expect(m.map(.dragEnded(location: CGPoint(x: onNode.x + 20, y: onNode.y + 6), translation: second), in: c)
                == [.move(second), .endMove])
    }

    /// An already-selected node must not be re-selected: that would collapse a multi-node
    /// selection to the one finger landed on, and the whole selection is what moves.
    @Test func dragOnASelectedNodeDoesNotTouchTheSelection() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything, selected: [.node(nodeID)])
        _ = m.map(.dragBegan(onNode), in: c)
        let t = CGSize(width: 0, height: 9)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x, y: onNode.y + 9), translation: t), in: c)
                == [.beginMove(.node(nodeID)), .move(t)])
    }

    @Test func dragOnACommentMovesTheComment() {
        var m = TouchIntentMapper()
        let c = context(.lasso, hits: everything)
        _ = m.map(.dragBegan(onComment), in: c)
        let t = CGSize(width: 12, height: 0)
        #expect(m.map(.dragChanged(location: CGPoint(x: onComment.x + 12, y: onComment.y), translation: t), in: c)
                == [.select(.comment(sticky), .replace), .beginMove(.comment(sticky)), .move(t)])
        #expect(m.map(.dragEnded(location: CGPoint(x: onComment.x + 12, y: onComment.y), translation: t), in: c)
                == [.move(t), .endMove])
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func dragFromASocketWiresInCanvasCoordinates(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        _ = m.map(.dragBegan(onSocket), in: c)
        let moved = CGPoint(x: onSocket.x + 10, y: onSocket.y)
        #expect(m.map(.dragChanged(location: moved, translation: CGSize(width: 10, height: 0)), in: c)
                == [.beginWire(socketRef, isInput: false), .wire(canvas(moved))])
        let dropped = CGPoint(x: onSocket.x + 40, y: onSocket.y + 20)
        #expect(m.map(.dragEnded(location: dropped, translation: CGSize(width: 40, height: 20)), in: c)
                == [.endWire(canvas(dropped))])
    }

    /// Pointer mode pans, by the *difference* since the last change — the canvas adds each delta
    /// to the live transform rather than to a remembered origin.
    @Test func dragOnEmptyCanvasPansByTheDeltaSinceTheLastChange() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onEmpty), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onEmpty.x + 10, y: onEmpty.y),
                                   translation: CGSize(width: 10, height: 0)), in: c) == [.pan(CGSize(width: 10, height: 0))])
        #expect(m.map(.dragChanged(location: CGPoint(x: onEmpty.x + 30, y: onEmpty.y + 5),
                                   translation: CGSize(width: 30, height: 5)), in: c) == [.pan(CGSize(width: 20, height: 5))])
        #expect(m.map(.dragEnded(location: CGPoint(x: onEmpty.x + 30, y: onEmpty.y + 5),
                                 translation: CGSize(width: 30, height: 5)), in: c) == [.endPan])
    }

    /// A wire is not a drag handle: a drag that starts on one pans (or marquees) like empty canvas.
    @Test func dragStartingOnAWirePansLikeEmptyCanvas() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onWire), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onWire.x + 12, y: onWire.y),
                                   translation: CGSize(width: 12, height: 0)), in: c) == [.pan(CGSize(width: 12, height: 0))])
    }

    @Test func dragOnEmptyCanvasMarqueesAndAddsInSelectMode() {
        var m = TouchIntentMapper()
        let c = context(.select, hits: everything)
        _ = m.map(.dragBegan(onEmpty), in: c)
        let moved = CGPoint(x: onEmpty.x + 40, y: onEmpty.y + 20)          // canvas (120, 110)
        let rect = CGRect(x: 100, y: 100, width: 20, height: 10)
        #expect(m.map(.dragChanged(location: moved, translation: CGSize(width: 40, height: 20)), in: c)
                == [.beginMarquee(CGPoint(x: 100, y: 100)), .marquee(rect)])
        #expect(m.map(.dragEnded(location: moved, translation: CGSize(width: 40, height: 20)), in: c)
                == [.endMarquee(rect, .add)])
    }

    /// Lasso mode marquees the same way but replaces, and the rect normalises when the finger
    /// travels up and to the left.
    @Test func lassoMarqueeReplacesTheSelection() {
        var m = TouchIntentMapper()
        let c = context(.lasso, hits: everything)
        let start = CGPoint(x: 620, y: 610)                                // canvas (300, 300), empty
        _ = m.map(.dragBegan(start), in: c)
        let moved = CGPoint(x: start.x - 60, y: start.y - 20)              // canvas (270, 290)
        let translation = CGSize(width: -60, height: -20)
        // Up and to the left: the rect normalises around the press point.
        let rect = CGRect(x: 270, y: 290, width: 30, height: 10)
        #expect(m.map(.dragChanged(location: moved, translation: translation), in: c)
                == [.beginMarquee(CGPoint(x: 300, y: 300)), .marquee(rect)])
        #expect(m.map(.dragEnded(location: moved, translation: translation), in: c)
                == [.endMarquee(rect, .replace)])
    }

    // MARK: Thresholds

    @Test func aDragLatchesOnlyOnceItPassesSixPoints() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onNode), in: c)
        // hypot(4, 3) == 5: still a tap as far as the mapper is concerned.
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 4, y: onNode.y + 3),
                                   translation: CGSize(width: 4, height: 3)), in: c).isEmpty)
        // hypot(5, 4) ≈ 6.4: latches, from the *press* point, not from where the finger is now.
        let t = CGSize(width: 5, height: 4)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 5, y: onNode.y + 4), translation: t), in: c)
                == [.select(.node(nodeID), .replace), .beginMove(.node(nodeID)), .move(t)])
    }

    @Test func aDragThatEndsBeforeLatchingEmitsNothing() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onNode), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 2, y: onNode.y + 2),
                                   translation: CGSize(width: 2, height: 2)), in: c).isEmpty)
        // The tap recognizer handles this touch; the drag must not open a transaction it never closes.
        #expect(m.map(.dragEnded(location: CGPoint(x: onNode.x + 3, y: onNode.y),
                                 translation: CGSize(width: 3, height: 0)), in: c).isEmpty)
    }

    // MARK: Two fingers

    @Test func twoFingerPanEmitsTheDeltaSinceTheLastReport() {
        var m = TouchIntentMapper()
        let c = context(.select, hits: everything)          // pans in every mode
        #expect(m.map(.twoFingerPan(CGSize(width: 10, height: 0)), in: c) == [.pan(CGSize(width: 10, height: 0))])
        #expect(m.map(.twoFingerPan(CGSize(width: 25, height: 4)), in: c) == [.pan(CGSize(width: 15, height: 4))])
        #expect(m.map(.twoFingerPanEnded, in: c) == [.endPan])
        // The next gesture starts from zero again, not from 25.
        #expect(m.map(.twoFingerPan(CGSize(width: 5, height: 0)), in: c) == [.pan(CGSize(width: 5, height: 0))])
    }

    @Test func pinchEmitsTheRatioBetweenReportsAroundTheCentroid() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        #expect(m.map(.pinch(scale: 2, centroid: onEmpty), in: c) == [.zoom(2, around: onEmpty)])
        #expect(m.map(.pinch(scale: 3, centroid: onEmpty), in: c) == [.zoom(1.5, around: onEmpty)])
        #expect(m.map(.pinchEnded, in: c) == [.endZoom])
        #expect(m.map(.pinch(scale: 2, centroid: onNode), in: c) == [.zoom(2, around: onNode)])
    }
}
