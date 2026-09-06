import SwiftUI
import CoreGraphics
import MetalNodesCore

/// The canvas context menu (spec §22.3) — long-press on iPad, right-click on macOS, one view, so
/// the two platforms cannot drift apart. Every item enables exactly as its `EditorCommands`
/// counterpart minus the `canvasHasFocus` gate: a menu the canvas itself put on screen is proof
/// enough that the canvas, not a text field, is what the gesture addressed.
struct CanvasContextMenu: View {
    let model: EditorModel
    /// Canvas coordinates: where Paste lands and where a new sticky note is centred.
    let canvasPoint: CGPoint
    /// What the press landed on, for the viewer items. `nil` on macOS, where the menu comes from
    /// the pointer and the ◉ badge is one click away anyway.
    let hit: CanvasHit?

    /// The iPad menu is a popover this view is the content of, so each item has to close it; the
    /// macOS `.contextMenu` closes itself, and calling `dismiss()` in a window's root hierarchy
    /// there would close the *window*. Hence the platform gate rather than a bare `dismiss()`.
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private func act(_ body: () -> Void) {
        body()
        #if os(iOS)
        dismiss()
        #endif
    }

    var body: some View {
        Button("Cut") { act { model.cutSelection() } }
            .disabled(!model.canCopy)
        Button("Copy") { act { model.copySelection() } }
            .disabled(!model.canCopy)
        Button("Paste") { act { model.paste(at: canvasPoint) } }
            .disabled(!model.canPaste)
        Button("Duplicate") { act { model.duplicateSelection() } }
            .disabled(!model.canCopy)
        Button("Delete") { act { model.deleteSelection() } }
            .disabled(model.selection.isEmpty && model.selectedComments.isEmpty && model.selectedWire == nil)
        Divider()
        Button("Group") { act { model.groupSelection() } }
            .disabled(model.editableSelection.isEmpty)
        Button("Ungroup") { act { model.ungroupSelection() } }
            .disabled(model.selectedInstance == nil)
        Button("Make Unique") { act { model.makeUniqueSelection() } }
            .disabled(model.selectedInstance == nil)
        Button("Edit Group") { act { if let id = model.selectedInstance { model.diveIn(id) } } }
            .disabled(model.selectedInstance == nil)
        Button("Exit Group") { act { model.exitGroup() } }
            .disabled(!model.canExitGroup)
        Divider()
        Button("Frame Selection") { act { model.frameSelection() } }
            .disabled(model.selection.isEmpty)
        Button("Add Sticky Note") { act { model.addSticky(centredAt: canvasPoint) } }
        if let ref = viewerSocket {
            Divider()
            Button(model.viewer == ref ? "Clear Viewer" : "Set Viewer") { act { model.toggleViewer(ref) } }
        }
    }

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
