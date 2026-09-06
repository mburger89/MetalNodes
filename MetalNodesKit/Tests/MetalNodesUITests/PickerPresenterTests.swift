import Testing
import Foundation
@testable import MetalNodesUI

/// The continuation behind the iPad's pickers (spec §22.4). Platform-neutral, so it is tested on
/// whichever platform the suite runs on — no picker, no window.
@MainActor
@Suite struct PickerPresenterTests {
    /// Lets a task that only awaits the presenter reach its continuation. Bounded, so a broken
    /// implementation fails the test instead of hanging the suite.
    private func waitUntilPending<Value: Sendable>(_ p: PickerPresenter<Value>) async {
        var spins = 0
        while !p.isPending, spins < 1000 {
            await Task.yield()
            spins += 1
        }
        #expect(p.isPending)
    }

    @Test func requestResolvesWithTheValue() async {
        let p = PickerPresenter<Int>()
        #expect(!p.isPresented)
        let request = Task { await p.request() }
        await waitUntilPending(p)
        #expect(p.isPresented)                     // the modifier's `isPresented` binding is true
        p.resolve(7)
        #expect(await request.value == 7)
        #expect(!p.isPresented)                    // …and false again once the value is in
        #expect(!p.isPending)
    }

    @Test func resolvingNilResumesWithNil() async {
        let p = PickerPresenter<Int>()
        let request = Task { await p.request() }
        await waitUntilPending(p)
        p.resolve(nil)                             // dismissed without picking anything
        #expect(await request.value == nil)
        #expect(!p.isPresented)
    }

    @Test func aSecondRequestWhilePendingIsRefusedAndLeavesTheFirstWaiting() async {
        let p = PickerPresenter<Int>()
        let first = Task { await p.request() }
        await waitUntilPending(p)

        #expect(await p.request() == nil)          // refused, without suspending
        #expect(p.isPending)                       // the first request is untouched…
        #expect(p.isPresented)

        p.resolve(3)
        #expect(await first.value == 3)            // …and still the one that gets the value
    }

    @Test func resolvingWithNothingPendingIsANoOp() {
        let p = PickerPresenter<Int>()
        p.resolve(1)
        #expect(!p.isPending)
        #expect(!p.isPresented)
    }
}
