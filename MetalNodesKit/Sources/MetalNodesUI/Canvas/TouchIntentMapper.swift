import CoreGraphics
import MetalNodesCore

/// What a canvas point belongs to (spec §22.2). `GraphCanvasView.hit(at:)` answers this from the
/// same anchors, frames and wire distances the mouse path uses.
nonisolated public enum CanvasHit: Equatable, Sendable {
    case node(NodeID)
    case comment(CommentID)
    case socket(SocketRef, isInput: Bool)
    case wire(SocketRef)
    case empty
}

/// What the canvas should *do*. Every case maps onto a function the mouse path already calls, so
/// selection, wiring, transactions and undo names stay single-sourced (spec §22.2).
nonisolated public enum CanvasIntent: Equatable, Sendable {
    case select(CanvasHit, SelectionMode)
    case clearSelection
    case beginMove(CanvasHit)
    /// Translation since the drag began, in viewport points — the same value `DragGesture`
    /// hands `NodeView.onDrag`, which is why the canvas can reuse `moveSelection(by:)`.
    case move(CGSize)
    case endMove
    case beginWire(SocketRef, isInput: Bool)
    /// Canvas coordinates.
    case wire(CGPoint)
    /// Canvas coordinates.
    case endWire(CGPoint)
    /// Canvas coordinates.
    case beginMarquee(CGPoint)
    case marquee(CGRect)
    case endMarquee(CGRect, SelectionMode)
    /// Pan the camera by this many viewport points — a delta, not a cumulative translation.
    case pan(CGSize)
    case endPan
    /// Multiply the zoom by this factor, keeping the viewport point under it stationary.
    case zoom(CGFloat, around: CGPoint)
    case endZoom
    /// Viewport point.
    case contextMenu(at: CGPoint, hit: CanvasHit)
    /// Viewport point.
    case openChooser(at: CGPoint)
}

/// What the overlay's recognizers report, in **viewport** coordinates (spec §22.2). One event per
/// recognizer callback; the mapper owns everything stateful about a drag.
nonisolated public enum TouchEvent: Equatable, Sendable {
    case tap(CGPoint)
    case doubleTap(CGPoint)
    case longPress(CGPoint)
    case dragBegan(CGPoint)
    case dragChanged(location: CGPoint, translation: CGSize)
    case dragEnded(location: CGPoint, translation: CGSize)
    /// The recognizer's cumulative translation; the mapper emits the difference.
    case twoFingerPan(CGSize)
    case twoFingerPanEnded
    /// The recognizer's cumulative scale; the mapper emits the ratio.
    case pinch(scale: CGFloat, centroid: CGPoint)
    case pinchEnded
}

/// Everything the mapper needs to know about the canvas, passed in per event so the mapper itself
/// holds no reference to the model (and the tests need no model).
nonisolated public struct TouchContext {
    public var mode: CanvasMode
    public var transform: CanvasTransform
    /// What lies under a **canvas** point.
    public var hitTest: (CGPoint) -> CanvasHit
    public var isSelected: (CanvasHit) -> Bool

    public init(mode: CanvasMode, transform: CanvasTransform,
                hitTest: @escaping (CGPoint) -> CanvasHit,
                isSelected: @escaping (CanvasHit) -> Bool) {
        self.mode = mode
        self.transform = transform
        self.hitTest = hitTest
        self.isSelected = isSelected
    }
}

/// Touch events → canvas intents (spec §22.2). Pure: no UIKit, no model, no view — which is what
/// makes the whole gesture table testable on macOS.
///
/// The only state is the current drag. A drag stays *pending* until it has travelled
/// `dragThreshold`, then latches onto what was under the press for the rest of the touch: releasing
/// a finger over a different node, or switching mode mid-drag, can never turn a live wire drag into
/// a pan and strand its transaction — the same latching rule `BackgroundDragMode` gives the mouse.
nonisolated public struct TouchIntentMapper {
    /// A drag begins after 6 pt of travel; a tap is a touch that ends inside 6 pt (spec §22.2).
    public static let dragThreshold: CGFloat = 6

    private enum Drag: Equatable {
        case move(CanvasHit)
        case wire
        /// The last cumulative translation reported, so each change emits a delta.
        case pan(last: CGSize)
        /// Canvas coordinates.
        case marquee(start: CGPoint)
    }

    private var drag: Drag?
    /// Where the finger went down, in viewport points: a latch resolves its hit from here, not
    /// from where the finger has travelled to.
    private var pressPoint: CGPoint?
    /// The most recent `dragChanged` location, in viewport points — set whenever `drag` is set, so
    /// an abandoned latch can close at the last place the finger was actually seen.
    private var lastLocation: CGPoint?
    private var lastTwoFingerTranslation: CGSize?
    private var lastPinchScale: CGFloat?

    public init() {}

    public mutating func map(_ event: TouchEvent, in context: TouchContext) -> [CanvasIntent] {
        switch event {
        case .tap(let p):
            return tap(at: p, in: context)
        case .doubleTap(let p):
            guard case .empty = context.hitTest(context.transform.toCanvas(p)) else { return [] }
            return [.openChooser(at: p)]
        case .longPress(let p):
            return [.contextMenu(at: p, hit: context.hitTest(context.transform.toCanvas(p)))]
        case .dragBegan(let p):
            // A latch left open by a broken touch stream (another recognizer stealing the touch,
            // or two `dragBegan`s with no `dragEnded` between them) must close before the new
            // press starts, or a consumer that opened an undo transaction on `beginMove` /
            // `beginWire` / `beginMarquee` / the pan is left holding it open forever.
            let abandoned = abandon(in: context)
            drag = nil
            pressPoint = p
            lastLocation = nil
            return abandoned
        case .dragChanged(let location, let translation):
            return dragChanged(location: location, translation: translation, in: context)
        case .dragEnded(let location, let translation):
            let out = dragEnded(location: location, translation: translation, in: context)
            drag = nil
            pressPoint = nil
            lastLocation = nil
            return out
        case .twoFingerPan(let translation):
            let last = lastTwoFingerTranslation ?? .zero
            lastTwoFingerTranslation = translation
            return [.pan(CGSize(width: translation.width - last.width, height: translation.height - last.height))]
        case .twoFingerPanEnded:
            lastTwoFingerTranslation = nil
            return [.endPan]
        case .pinch(let scale, let centroid):
            let last = lastPinchScale ?? 1
            lastPinchScale = scale
            guard last > 0 else { return [] }
            return [.zoom(scale / last, around: centroid)]
        case .pinchEnded:
            lastPinchScale = nil
            return [.endZoom]
        }
    }

    /// A tap never adds in pointer or lasso mode; select mode is the one that toggles. A socket is
    /// too small to aim a tap at, so it counts as its node — a wire drag needs a *drag*.
    private func tap(at p: CGPoint, in c: TouchContext) -> [CanvasIntent] {
        let hit = c.hitTest(c.transform.toCanvas(p))
        let mode: SelectionMode = c.mode == .select ? .toggle : .replace
        switch hit {
        case .node, .comment:
            return [.select(hit, mode)]
        case .socket(let ref, _):
            return [.select(.node(ref.node), mode)]
        case .wire(let ref):
            // The model holds one selected wire, so there is nothing to add to.
            return [.select(.wire(ref), .replace)]
        case .empty:
            // Select mode keeps what you have gathered: a stray tap must not throw it away.
            return c.mode == .select ? [] : [.clearSelection]
        }
    }

    private mutating func dragChanged(location: CGPoint, translation: CGSize,
                                      in c: TouchContext) -> [CanvasIntent] {
        lastLocation = location
        if let drag { return changed(drag, location: location, translation: translation, in: c) }
        guard hypot(translation.width, translation.height) >= Self.dragThreshold else { return [] }
        let start = pressPoint ?? CGPoint(x: location.x - translation.width, y: location.y - translation.height)
        let canvasStart = c.transform.toCanvas(start)
        let hit = c.hitTest(canvasStart)
        switch hit {
        case .node, .comment:
            drag = .move(hit)
            // An unselected item joins the selection *before* the move snapshots its origins;
            // an already-selected one is left alone, so dragging one of five moves all five.
            var out: [CanvasIntent] = c.isSelected(hit) ? [] : [.select(hit, .replace)]
            out.append(.beginMove(hit))
            out.append(.move(translation))
            return out
        case .socket(let ref, let isInput):
            drag = .wire
            return [.beginWire(ref, isInput: isInput), .wire(c.transform.toCanvas(location))]
        case .wire, .empty:
            if c.mode == .pointer {
                drag = .pan(last: translation)
                return [.pan(translation)]
            }
            drag = .marquee(start: canvasStart)
            return [.beginMarquee(canvasStart),
                    .marquee(Self.rect(from: canvasStart, to: c.transform.toCanvas(location)))]
        }
    }

    private mutating func changed(_ drag: Drag, location: CGPoint, translation: CGSize,
                                  in c: TouchContext) -> [CanvasIntent] {
        switch drag {
        case .move:
            return [.move(translation)]
        case .wire:
            return [.wire(c.transform.toCanvas(location))]
        case .pan(let last):
            self.drag = .pan(last: translation)
            return [.pan(CGSize(width: translation.width - last.width, height: translation.height - last.height))]
        case .marquee(let start):
            return [.marquee(Self.rect(from: start, to: c.transform.toCanvas(location)))]
        }
    }

    /// Closes whatever the current latch left open, using the last location actually seen for
    /// `.wire` and `.marquee` — `lastLocation` is always set by the time `drag` is, so this only
    /// falls back to the press point in a state that should be unreachable.
    private func abandon(in c: TouchContext) -> [CanvasIntent] {
        guard let drag else { return [] }
        let loc = lastLocation ?? pressPoint ?? .zero
        switch drag {
        case .move:
            return [.endMove]
        case .wire:
            return [.endWire(c.transform.toCanvas(loc))]
        case .pan:
            return [.endPan]
        case .marquee(let start):
            // Select mode gathers; the lasso is a one-shot selection (spec §22.2) — the same rule
            // `dragEnded` applies to a marquee that finishes normally.
            return [.endMarquee(Self.rect(from: start, to: c.transform.toCanvas(loc)), c.mode == .lasso ? .replace : .add)]
        }
    }

    private func dragEnded(location: CGPoint, translation: CGSize, in c: TouchContext) -> [CanvasIntent] {
        // Never latched: the tap (or double-tap) recognizer owns this touch, and nothing was begun
        // here that has to be ended.
        guard let drag else { return [] }
        switch drag {
        case .move:
            return [.move(translation), .endMove]
        case .wire:
            return [.endWire(c.transform.toCanvas(location))]
        case .pan:
            return [.endPan]
        case .marquee(let start):
            let rect = Self.rect(from: start, to: c.transform.toCanvas(location))
            // Select mode gathers; the lasso is a one-shot selection (spec §22.2).
            return [.endMarquee(rect, c.mode == .lasso ? .replace : .add)]
        }
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
