import SwiftUI

public struct EditorModelKey: FocusedValueKey {
    public typealias Value = EditorModel
}

public extension FocusedValues {
    var editorModel: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}

/// Edit / View menu items routed to the focused editor (spec §18.6). Cut/Copy/Paste/Delete/Select All
/// are the standard items, routed to the canvas via onCommand/onPasteCommand/onDeleteCommand;
/// Duplicate is a custom item here, and the zoom items join the standard View menu.
public struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model

    public init() {}

    public var body: some Commands {
        // Undo/Redo, Delete, and the View menu's bare-key shortcuts are gated on `canvasHasFocus`
        // (rather than always enabled) so that, while a node parameter `TextField` is focused
        // (canvas is not), these menu key equivalents go disabled and let the field editor's own
        // Delete/⌘Z handling see the keystroke instead of the menu intercepting it first.
        // The titles name the step ("Undo Move"): `commitUndo` sets an action name on every group,
        // and `UndoManager` composes the menu title from it. Reading `canUndo`/`canRedo` in the
        // same body is what re-evaluates these — they touch `undoStackVersion` (spec §18.6).
        CommandGroup(replacing: .undoRedo) {
            Button(model?.undoManager.undoMenuItemTitle ?? "Undo") { model?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!((model?.canUndo ?? false) && (model?.canvasHasFocus ?? false)))
            Button(model?.undoManager.redoMenuItemTitle ?? "Redo") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!((model?.canRedo ?? false) && (model?.canvasHasFocus ?? false)))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!(model?.canvasHasFocus ?? false) || !(model?.canCopy ?? false))
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom to Fit") { model?.requestCanvas(.fitAll) }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!(model?.canvasHasFocus ?? false))
            Button("Zoom to Selection") { model?.requestCanvas(.fitSelection) }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!(model?.canvasHasFocus ?? false))
            Divider()
            Button("Toggle Viewer") { model?.toggleViewerOnSelection() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!(model?.canvasHasFocus ?? false) || (model?.selection.count ?? 0) != 1)
        }
    }
}
