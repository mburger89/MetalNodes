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

    /// Every item below is gated on this so that, while a node parameter `TextField` is focused,
    /// the menu's key equivalents stay out of the field editor's way (see the note below).
    private var canvasFocused: Bool { model?.canvasHasFocus ?? false }

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export Shader…") { model?.requestExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model == nil)
        }
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
                .disabled(!((model?.canUndo ?? false) && canvasFocused))
            Button(model?.undoManager.redoMenuItemTitle ?? "Redo") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!((model?.canRedo ?? false) && canvasFocused))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canCopy ?? false))
            // Groups (spec §20.6, §20.8). Group needs ≥ 1 non-pseudo node; Ungroup, Make Unique
            // and Edit Group need exactly one selected instance; Exit Group needs a level to pop.
            Divider()
            Button("Group") { model?.groupSelection() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!canvasFocused || (model?.editableSelection.isEmpty ?? true))
            Button("Ungroup") { model?.ungroupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!canvasFocused || model?.selectedInstance == nil)
            Button("Make Unique") { model?.makeUniqueSelection() }
                .disabled(!canvasFocused || model?.selectedInstance == nil)
            Button("Edit Group") { if let id = model?.selectedInstance { model?.diveIn(id) } }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!canvasFocused || model?.selectedInstance == nil)
            Button("Exit Group") { model?.exitGroup() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!canvasFocused || !(model?.canExitGroup ?? false))
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom to Fit") { model?.requestCanvas(.fitAll) }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!canvasFocused)
            Button("Zoom to Selection") { model?.requestCanvas(.fitSelection) }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!canvasFocused)
            Divider()
            Button("Toggle Viewer") { model?.toggleViewerOnSelection() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!canvasFocused || (model?.selection.count ?? 0) != 1)
            Divider()
            Toggle("Minimap", isOn: Binding(get: { model?.viewState.showsMinimap ?? true },
                                            set: { model?.viewState.showsMinimap = $0 }))
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
