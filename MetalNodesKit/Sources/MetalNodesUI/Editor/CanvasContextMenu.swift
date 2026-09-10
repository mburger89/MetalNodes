import SwiftUI
import CoreGraphics
import MetalNodesCore

/// The canvas context menu (spec §22.3) — long-press on iPad, right-click on macOS, one view, so
/// the two platforms cannot drift apart. Every item enables exactly as its `EditorCommands`
/// counterpart minus the `canvasHasFocus` gate: a menu the canvas itself put on screen is proof
/// enough that the canvas, not a text field, is what the gesture addressed.
struct CanvasContextMenu: View {
    let model: EditorModel
    /// Canvas coordinates: where Paste lands and where a new sticky note is centred. A closure, not
    /// a value, because on macOS SwiftUI builds this content during the canvas's body evaluation and
    /// reuses it until the body runs again — and since M11 a pointer move no longer re-evaluates
    /// that body (spec §27.9, H2), so a point read while the content was built is the one from
    /// whenever the body last ran, a click ago. Every item therefore calls this *inside* its action,
    /// when the item is chosen and the hover point is wherever the pointer actually is.
    let canvasPoint: () -> CGPoint
    /// What the press landed on — the viewer items read the socket, and a node outside the
    /// selection becomes the selection (see `adoptedNode`). Which items exist has to be settled
    /// while the content is built, so on macOS this is the hit as of the canvas's last body
    /// evaluation; a boundary crossing under the pointer is made to be one of those (`hoverHit`).
    let hit: CanvasHit?

    /// The node a context-menu press makes the selection before any item acts: the pressed node
    /// (through its body or a socket) when it is not already selected — the way a secondary click
    /// on an unselected Finder item selects it first. `nil` leaves the selection as it is: a press
    /// on a selected node, on a comment, a wire, or empty canvas.
    nonisolated static func adoptedNode(hit: CanvasHit?, selection: Set<NodeID>) -> NodeID? {
        let pressed: NodeID? = switch hit {
        case .node(let id)?: id
        case .socket(let ref, _)?: ref.node
        default: nil
        }
        guard let pressed, !selection.contains(pressed) else { return nil }
        return pressed
    }

    /// "New Custom Code Node" only makes sense with nothing under the press — a node, socket,
    /// comment or wire already has its own menu of things to act on it (spec §24.3). Unlike
    /// `adoptedNode`, which also reads a comment, a wire and an already-selected node as "leave
    /// things alone", this is stricter: only a genuinely empty canvas (`nil` or `.empty`) shows it.
    nonisolated static func showsNewCustomCodeNode(hit: CanvasHit?) -> Bool {
        switch hit {
        case nil, .empty?: true
        default: false
        }
    }

    private var adopted: NodeID? { Self.adoptedNode(hit: hit, selection: model.selection) }

    /// The selection the items enable against — the one `act` will have installed by the time the
    /// item runs.
    private var selection: Set<NodeID> { adopted.map { [$0] } ?? model.selection }
    private var editableSelection: Set<NodeID> {
        adopted.map { model.shape(of: $0)?.isPseudo == true ? [] : [$0] } ?? model.editableSelection
    }
    private var selectedInstance: NodeID? {
        guard selection.count == 1, let id = selection.first, case .group? = model.graph.nodes[id]?.kind else { return nil }
        return id
    }
    private var canCopy: Bool { !editableSelection.isEmpty || (adopted == nil && !model.selectedComments.isEmpty) }

    /// The iPad menu is a popover this view is the content of, so each item has to close it; the
    /// macOS `.contextMenu` closes itself, and calling `dismiss()` in a window's root hierarchy
    /// there would close the *window*. Hence the platform gate rather than a bare `dismiss()`.
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private func act(_ body: () -> Void) {
        if let adopted { model.select(adopted, mode: .replace) }
        body()
        #if os(iOS)
        dismiss()
        #endif
    }

    var body: some View {
        Button("Cut") { act { model.cutSelection() } }
            .disabled(!canCopy)
        Button("Copy") { act { model.copySelection() } }
            .disabled(!canCopy)
        Button("Paste") { act { model.paste(at: canvasPoint()) } }
            .disabled(!model.canPaste)
        Button("Duplicate") { act { model.duplicateSelection() } }
            .disabled(!canCopy)
        Button("Delete") { act { model.deleteSelection() } }
            .disabled(selection.isEmpty && adopted == nil && model.selectedComments.isEmpty && model.selectedWire == nil)
        Divider()
        Button("Group") { act { model.groupSelection() } }
            .disabled(editableSelection.isEmpty)
        Button("Ungroup") { act { model.ungroupSelection() } }
            .disabled(selectedInstance == nil)
        Button("Make Unique") { act { model.makeUniqueSelection() } }
            .disabled(selectedInstance == nil)
        Button("Edit Group") { act { if let id = model.selectedInstance { model.diveIn(id) } } }
            .disabled(selectedInstance == nil)
        Button("Exit Group") { act { model.exitGroup() } }
            .disabled(!model.canExitGroup)
        Divider()
        Button("Frame Selection") { act { model.frameSelection() } }
            .disabled(selection.isEmpty)
        Button("Add Sticky Note") { act { model.addSticky(centredAt: canvasPoint()) } }
        if Self.showsNewCustomCodeNode(hit: hit) {
            Button("New Custom Code Node") { act { model.newCustomCodeDefinition(at: canvasPoint()) } }
        }
        if let ref = viewerSocket {
            Divider()
            Button(model.viewer == ref ? "Clear Viewer" : "Set Viewer") { act { model.toggleViewer(ref) } }
        }
    }

    /// What Paste, "Add Sticky Note" and "New Custom Code Node" would use if chosen right now.
    /// A SwiftUI `Button`'s action is not reachable from a test, so this is the seam that lets one
    /// assert the point is read at *choose* time rather than when the content was built.
    func pastePoint() -> CGPoint { canvasPoint() }

    /// The socket the viewer items act on. A viewer is always an *output*, so pressing an input
    /// socket — or a node body — views that node's first output, exactly what the ◉ badge and ⌘⇧V
    /// use (`firstOutput`).
    private var viewerSocket: SocketRef? {
        switch hit {
        case .socket(let ref, let isInput)?: isInput ? model.firstOutput(of: ref.node) : ref
        case .node(let id)?: model.firstOutput(of: id)
        default: nil
        }
    }
}
