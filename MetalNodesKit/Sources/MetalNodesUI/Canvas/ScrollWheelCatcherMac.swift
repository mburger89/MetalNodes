#if os(macOS)
import SwiftUI
import AppKit

/// SwiftUI has no scroll-wheel modifier, and an overlay that hit-tests would swallow clicks.
/// This zero-visual view installs a local event monitor and forwards scroll events whose
/// location falls inside its bounds (spec §18.6). `isFlipped` makes coordinates top-left
/// origin, matching SwiftUI.
struct ScrollWheelCatcher: NSViewRepresentable {
    typealias Handler = (_ delta: CGSize, _ location: CGPoint, _ commandHeld: Bool, _ precise: Bool) -> Void
    let onScroll: Handler

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: Handler = { _, _, _, _ in }
        // `deinit` is nonisolated even though this class defaults to `@MainActor` (module default
        // isolation); `NSView`s are only ever created/torn down on the main thread in practice, so
        // this is safe to touch from there.
        nonisolated(unsafe) private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // never intercept clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // `assumeIsolated`'s result crosses back out of the MainActor closure, so it must be
                // `Sendable`; `NSEvent` isn't, so we return a `Bool` (handled or not) instead and let
                // the caller (already on the main thread — local monitors only ever fire there) decide
                // whether to swallow the original event.
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Returns `true` if the event was consumed (should be swallowed).
        private func handle(_ e: NSEvent) -> Bool {
            guard e.window === window else { return false }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            onScroll(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY), p,
                     e.modifierFlags.contains(.command), e.hasPreciseScrollingDeltas)
            return true
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
#endif
