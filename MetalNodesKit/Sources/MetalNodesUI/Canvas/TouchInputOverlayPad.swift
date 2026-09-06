#if os(iOS)
import SwiftUI
import UIKit

/// The iPad canvas's single touch target (spec §22.2). It covers the whole viewport above the
/// content and owns every canvas touch except the interactive rects the node and comment views
/// report — those it hands straight back to SwiftUI by failing its own hit test.
///
/// It only *reports*: the recognizer callbacks become `TouchEvent`s and `GraphCanvasView` decides
/// what they mean through `TouchIntentMapper`, so nothing about selection, wiring or undo lives in
/// UIKit.
struct TouchInputOverlay: UIViewRepresentable {
    let transform: CanvasTransform
    /// Canvas-space rects SwiftUI must keep (param controls, the ◉ badge, resize handles).
    let interactiveRects: [CGRect]
    let onEvent: (TouchEvent) -> Void

    /// The box the representable pushes fresh values into on every update: the `UIView` outlives
    /// each `TouchInputOverlay` value, so it must never capture one.
    final class Coordinator {
        var transform: CanvasTransform
        var interactiveRects: [CGRect]
        var onEvent: (TouchEvent) -> Void

        init(transform: CanvasTransform, interactiveRects: [CGRect], onEvent: @escaping (TouchEvent) -> Void) {
            self.transform = transform
            self.interactiveRects = interactiveRects
            self.onEvent = onEvent
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: transform, interactiveRects: interactiveRects, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> TouchOverlayView {
        let view = TouchOverlayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: TouchOverlayView, context: Context) {
        context.coordinator.transform = transform
        context.coordinator.interactiveRects = interactiveRects
        context.coordinator.onEvent = onEvent
        view.coordinator = context.coordinator
    }
}

/// A one-finger pan that remembers where the finger actually went down.
///
/// `UIPanGestureRecognizer` measures its translation from where *recognition* began, not from the
/// touch-down point, so `location - translation` at `.began` is already a slop's worth into the
/// drag — and `hit(at:)` resolves a socket within `SocketView.hitSize / 2`, which is that same
/// distance. A wire drag started on a socket therefore resolved as empty canvas and panned instead
/// (spec §22.2). Recording the touch itself removes the guess.
private final class TrackingPanGestureRecognizer: UIPanGestureRecognizer {
    /// Where the first touch of this gesture went down, in the recognizer's view.
    private(set) var initialLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if initialLocation == nil, let touch = touches.first, let view {
            initialLocation = touch.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        initialLocation = nil
    }
}

/// The overlay's view. Six recognizers, all with `cancelsTouchesInView = false` so a touch that
/// falls through to SwiftUI (an interactive rect) is unaffected, and all accepting Pencil touches —
/// a Pencil is a precise finger (spec §22.2).
final class TouchOverlayView: UIView {
    var coordinator: TouchInputOverlay.Coordinator?

    /// Held so the delegate can allow exactly one simultaneous pair: the two-finger pan and the
    /// pinch, which are one gesture to the user.
    private let twoFingerPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let touchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                      NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let pan = TrackingPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2

        pinch.addTarget(self, action: #selector(handlePinch(_:)))

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Otherwise the first tap of a double-tap selects before the chooser opens.
        tap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = TouchIntentMapper.dragThreshold

        for recognizer in [pan, twoFingerPan, pinch, tap, doubleTap, longPress] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = touchTypes
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TouchOverlayView is never loaded from a nib") }

    /// SwiftUI keeps the touches that land in an interactive rect — a param control, the ◉ badge, a
    /// comment's resize handle — and the overlay takes everything else (spec §22.2). The rects are
    /// canvas-space, so the point converts through the same transform the canvas draws with.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        guard let coordinator else { return self }
        let canvasPoint = coordinator.transform.toCanvas(point)
        if coordinator.interactiveRects.contains(where: { $0.contains(canvasPoint) }) { return nil }
        return self
    }

    // MARK: Recognizers → events (viewport coordinates)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: self)
        let t = g.translation(in: self)
        let translation = CGSize(width: t.x, height: t.y)
        switch g.state {
        case .began:
            // Where the finger went *down* — the point the mapper resolves the drag's hit from.
            // `TrackingPanGestureRecognizer` recorded it from the touch; subtracting the
            // translation is only a fallback, and is off by the recognizer's slop.
            let recorded = (g as? TrackingPanGestureRecognizer)?.initialLocation
            send(.dragBegan(recorded ?? CGPoint(x: location.x - t.x, y: location.y - t.y)))
        case .changed:
            send(.dragChanged(location: location, translation: translation))
        case .ended, .cancelled, .failed:
            // A cancelled drag must still end: the mapper's latch closes the canvas's transaction.
            send(.dragEnded(location: location, translation: translation))
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began, .changed:
            send(.twoFingerPan(CGSize(width: t.x, height: t.y)))
        case .ended, .cancelled, .failed:
            send(.twoFingerPanEnded)
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            send(.pinch(scale: g.scale, centroid: g.location(in: self)))
        case .ended, .cancelled, .failed:
            send(.pinchEnded)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        send(.tap(g.location(in: self)))
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        send(.doubleTap(g.location(in: self)))
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        send(.longPress(g.location(in: self)))
    }

    private func send(_ event: TouchEvent) { coordinator?.onEvent(event) }
}

extension TouchOverlayView: UIGestureRecognizerDelegate {
    /// Only the two-finger pan and the pinch run together — a two-finger gesture that both moves
    /// and spreads is one motion. Everything else stays exclusive, so a tap can never fire in the
    /// middle of a drag.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = Set([ObjectIdentifier(g), ObjectIdentifier(other)])
        return pair == Set([ObjectIdentifier(twoFingerPan), ObjectIdentifier(pinch)])
    }
}
#endif
