import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

/// The one rule the context menu adds on top of its Edit-menu twins (spec §22.3): a press on a node
/// that is not selected makes it the selection before any item acts.
@Suite @MainActor struct CanvasContextMenuTests {
    let a = NodeID(), b = NodeID()

    @Test func anUnselectedNodeUnderThePressIsAdopted() {
        #expect(CanvasContextMenu.adoptedNode(hit: .node(a), selection: []) == a)
        #expect(CanvasContextMenu.adoptedNode(hit: .node(a), selection: [b]) == a)
        #expect(CanvasContextMenu.adoptedNode(hit: .socket(SocketRef(a, "out"), isInput: false), selection: [b]) == a)
    }

    @Test func aSelectedNodeCommentWireOrEmptyCanvasLeavesTheSelectionAlone() {
        #expect(CanvasContextMenu.adoptedNode(hit: .node(a), selection: [a, b]) == nil)
        #expect(CanvasContextMenu.adoptedNode(hit: .socket(SocketRef(a, "out"), isInput: false), selection: [a]) == nil)
        #expect(CanvasContextMenu.adoptedNode(hit: .comment(.sticky(StickyID())), selection: [b]) == nil)
        #expect(CanvasContextMenu.adoptedNode(hit: .wire(SocketRef(a, "out")), selection: [b]) == nil)
        #expect(CanvasContextMenu.adoptedNode(hit: .empty, selection: [b]) == nil)
        #expect(CanvasContextMenu.adoptedNode(hit: nil, selection: [b]) == nil)
    }

    /// "New Custom Code Node" (Task 16) belongs to the empty-canvas section: it has no selection
    /// to act on, so it only makes sense with nothing under the press.
    @Test func newCustomCodeNodeAppearsOnlyOnTheEmptyCanvas() {
        #expect(CanvasContextMenu.showsNewCustomCodeNode(hit: nil))
        #expect(CanvasContextMenu.showsNewCustomCodeNode(hit: .empty))
        #expect(!CanvasContextMenu.showsNewCustomCodeNode(hit: .node(a)))
        #expect(!CanvasContextMenu.showsNewCustomCodeNode(hit: .socket(SocketRef(a, "out"), isInput: false)))
        #expect(!CanvasContextMenu.showsNewCustomCodeNode(hit: .comment(.sticky(StickyID()))))
        #expect(!CanvasContextMenu.showsNewCustomCodeNode(hit: .wire(SocketRef(a, "out"))))
    }

    /// SwiftUI builds the macOS menu's content during the canvas's body evaluation and reuses it
    /// until the body runs again, and since M11 a pointer move no longer re-evaluates that body
    /// (spec §27.9, H2) — so a point read while the content was built is the one from whenever the
    /// body last ran, and Paste lands at the last click rather than under the cursor. The point must
    /// therefore be read when an item is chosen: here the closure's source changes after the menu is
    /// constructed, and what Paste would use changes with it.
    @Test func thePointIsReadWhenAnItemIsChosenNotWhenTheMenuIsBuilt() {
        var pointer = CGPoint(x: 10, y: 20)
        let menu = CanvasContextMenu(model: EditorModel(document: ShaderDocument(),
                                                        compiler: RecordingCompiler()),
                                     canvasPoint: { pointer },
                                     hit: .empty)
        #expect(menu.pastePoint() == CGPoint(x: 10, y: 20))
        pointer = CGPoint(x: 300, y: 400)      // the pointer moved after the menu was built
        #expect(menu.pastePoint() == CGPoint(x: 300, y: 400))
    }
}
