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

/// Edit / View menu items routed to the focused editor (spec §18.6). Cut/Copy/Paste/Duplicate land in Task 13.
public struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model

    public init() {}

    public var body: some Commands {
        // Undo/Redo, Delete, and the View menu's bare-key shortcuts are gated on `canvasHasFocus`
        // (rather than always enabled) so that, while a node parameter `TextField` is focused
        // (canvas is not), these menu key equivalents go disabled and let the field editor's own
        // Delete/⌘Z handling see the keystroke instead of the menu intercepting it first.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!((model?.canUndo ?? false) && (model?.canvasHasFocus ?? false)))
            Button("Redo") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!((model?.canRedo ?? false) && (model?.canvasHasFocus ?? false)))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!(model?.canvasHasFocus ?? false) || !(model?.canCopy ?? false))
            Button("Delete") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!(model?.canvasHasFocus ?? false) || ((model?.selection.isEmpty ?? true) && model?.selectedWire == nil))
        }
        CommandMenu("View") {
            Button("Zoom to Fit") { model?.requestCanvas(.fitAll) }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!(model?.canvasHasFocus ?? false))
            Button("Zoom to Selection") { model?.requestCanvas(.fitSelection) }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!(model?.canvasHasFocus ?? false))
        }
    }
}
