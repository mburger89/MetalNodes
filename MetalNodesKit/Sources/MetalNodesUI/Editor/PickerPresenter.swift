import Foundation
import Observation

/// The bridge between an `async` service call and a SwiftUI presentation modifier (spec §22.4).
/// A picker is not a function: the caller wants `await chooser.choose(…)`, SwiftUI wants an
/// `isPresented` binding and a callback. The presenter owns both ends — `request()` raises the
/// binding and suspends, the modifier's callback calls `resolve(_:)`, which lowers the binding and
/// resumes. A second request while one is on screen is refused (nil) rather than queued, the way the
/// macOS export guard already refuses to stack panels.
@MainActor
@Observable
public final class PickerPresenter<Value: Sendable> {
    /// Bound to the modifier's `isPresented:`. Written here on request and on resolve; SwiftUI may
    /// also write it to false when the sheet is dismissed, which is why the hosts resolve nil
    /// on that transition rather than relying on a callback that may never come.
    public var isPresented = false

    /// The suspended `request()`. Deliberately unobserved: the views key off `isPresented`, and a
    /// continuation is not a value SwiftUI can diff.
    @ObservationIgnored private var continuation: CheckedContinuation<Value?, Never>?

    /// Whether a `request()` is waiting for a value.
    public var isPending: Bool { continuation != nil }

    public init() {}

    /// Presents and waits. Returns nil immediately — without presenting anything — when a request is
    /// already pending.
    public func request() async -> Value? {
        guard continuation == nil else { return nil }
        isPresented = true
        return await withCheckedContinuation { c in
            // `withCheckedContinuation` runs this body synchronously, before the suspension, so a
            // `resolve` from a callback in a later turn always finds the continuation here.
            self.continuation = c
        }
    }

    /// Ends the presentation and hands `value` to the waiting `request()`. A no-op when nothing is
    /// pending, so a modifier that reports both a completion *and* a dismissal resolves once.
    public func resolve(_ value: Value?) {
        isPresented = false
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: value)
    }
}
