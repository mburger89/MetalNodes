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
        // iPad's Edit ▸ Cut / Copy / Paste / Delete / Select All (spec §22.5, and the ruling in the
        // M6 plan's Task 9: SwiftUI Commands, not a UIKit responder). macOS keeps the responder
        // selectors on the canvas — `onCommand(#selector(NSText.cut(_:)))` and friends — so its
        // pasteboard group stays the system's.
        //
        // Gated on `canvasFocused` for the same reason every other item is: while a node parameter
        // `TextField` has the focus these key equivalents go disabled, and the field's own editing
        // commands see the keystroke instead.
        #if os(iOS)
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { model?.cutSelection() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canCopy ?? false))
            Button("Copy") { model?.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canCopy ?? false))
            // At the viewport's centre, which only the canvas knows (spec §22.5).
            Button("Paste") { model?.requestCanvas(.paste) }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canPaste ?? false))
            Button("Delete") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!canvasFocused)
            Button("Select All") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!canvasFocused)
        }
        #endif
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
            // A Custom MSL node (spec §24.3): unlike Group, it needs no selection to come from —
            // it starts empty and the user writes into it. Routed through `requestCanvas`, like
            // Paste and Add Sticky Note, so it lands at the viewport's centre.
            Button("New Custom Code Node") { model?.requestCanvas(.newCustomCode) }
                .keyboardShortcut("n", modifiers: [.control, .command])
                .disabled(!canvasFocused)
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
            // Comments (spec §21.4). The note lands at the viewport's centre, which only the
            // canvas knows, so it goes through `canvasRequest` the way palette placement does.
            Divider()
            Button("Add Sticky Note") { model?.requestCanvas(.addSticky) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canvasFocused)
            Button("Frame Selection") { model?.frameSelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!canvasFocused || (model?.selection.isEmpty ?? true))
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
            // View state, not a document edit (spec §21.5) — written straight to `viewState`,
            // the same way the canvas writes its camera (not routed through `apply`, not undoable).
            Button("Generated Code") { model?.viewState.showsCode.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model == nil)
        }
    }
}
