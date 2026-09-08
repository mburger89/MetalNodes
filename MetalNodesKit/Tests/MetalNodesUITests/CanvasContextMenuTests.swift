import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

/// The one rule the context menu adds on top of its Edit-menu twins (spec §22.3): a press on a node
/// that is not selected makes it the selection before any item acts.
@Suite struct CanvasContextMenuTests {
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
}
