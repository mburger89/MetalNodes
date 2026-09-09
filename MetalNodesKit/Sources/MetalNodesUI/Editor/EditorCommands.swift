import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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

    /// `canvasFocused`, extended to the code editor (Task 17 fix round 2). `canvasHasFocus` is
    /// correctly `false` there — `GraphCanvasView` really is unmounted while a `.msl` definition
    /// is open (fix round 1's Critical 2 fix) — but Exit Group (⌘↑) still needs a keyboard path
    /// from inside the code editor: it is the only way out once the canvas that would otherwise
    /// hold focus is gone. **Deliberately not used for Undo/Redo — see the comment at their
    /// `CommandGroup`, fix round 3.**
    private var canvasFocusedOrEditingCode: Bool { canvasFocused || (model?.isEditingCode ?? false) }

    #if os(macOS)
    /// True while an AppKit text view (a `TextField`'s field editor, a `TextEditor`'s `NSTextView`)
    /// is the key window's first responder. `NSTextView` is an `NSText`, so one check covers both.
    private var textViewIsFirstResponder: Bool { NSApp.keyWindow?.firstResponder is NSText }
    private var undoDisabled: Bool { model == nil }
    private var redoDisabled: Bool { model == nil }

    private func undoCommand() {
        if textViewIsFirstResponder { _ = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        if canvasFocused, model?.canUndo == true { model?.undo() }
    }

    private func redoCommand() {
        if textViewIsFirstResponder { _ = NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        if canvasFocused, model?.canRedo == true { model?.redo() }
    }
    #else
    private var undoDisabled: Bool { !((model?.canUndo ?? false) && canvasFocused) }
    private var redoDisabled: Bool { !((model?.canRedo ?? false) && canvasFocused) }
    private func undoCommand() { model?.undo() }
    private func redoCommand() { model?.redo() }
    #endif

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export Shader…") { model?.requestExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model == nil)
            // Recording (spec §26.5). No key equivalents: each opens a sheet that asks for a size,
            // and none of them is frequent enough to earn a shortcut.
            Divider()
            ForEach(RecordingKind.allCases, id: \.self) { kind in
                Button("\(kind.title)…") { model?.requestRecording(kind) }
                    .disabled(model == nil)
            }
        }
        // Delete and the View menu's bare-key shortcuts are gated on `canvasHasFocus` (rather than
        // always enabled) so that, while a node parameter `TextField` is focused (canvas is not),
        // those menu key equivalents go disabled and let the field editor's own Delete handling
        // see the keystroke instead of the menu intercepting it first. Undo/Redo are gated the
        // same way on iPadOS; on macOS they are handled by the paragraph below instead.
        // The titles name the step ("Undo Move"): `commitUndo` sets an action name on every group,
        // and `UndoManager` composes the menu title from it. Reading `canUndo`/`canRedo` in the
        // same body is what re-evaluates these — they touch `undoStackVersion` (spec §18.6).
        //
        // macOS (spec §25.2, handoff §15.5 item 9): the items stay enabled, and the *action*
        // decides. With a text view as first responder — a node parameter field, the inspector's
        // formula field, the code editor — ⌘Z is forwarded down the responder chain as `undo:`,
        // so the field editor's own text undo fires; nothing reaches the model, which is what
        // keeps ruling 26's data-loss path closed (a document undo can never reseed the code
        // editor's draft mid-keystroke, because it is never called from here while one is
        // focused). Otherwise the document undo runs exactly as before, gated on the canvas.
        // Before M9 the items were *disabled* while a field was focused, and a disabled menu item
        // swallows its key equivalent — ⌘Z did nothing at all inside any text view.
        //
        // iPadOS keeps the pre-M9 gating (recorded as unverified in handoff §16): UIKit's text
        // views route ⌘Z through their own key commands, and this milestone verifies macOS only.
        CommandGroup(replacing: .undoRedo) {
            Button(model?.undoManager.undoMenuItemTitle ?? "Undo") { undoCommand() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoDisabled)
            Button(model?.undoManager.redoMenuItemTitle ?? "Redo") { redoCommand() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoDisabled)
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
                .disabled(!canvasFocusedOrEditingCode || !(model?.canExitGroup ?? false))
            Divider()
            // A Custom MSL node (spec §24.3): unlike Group, it needs no selection to come from —
            // it starts empty and the user writes into it. Routed through `requestCanvas`, like
            // Paste and Add Sticky Note, so it lands at the viewport's centre.
            Button("New Custom Code Node") { model?.requestCanvas(.newCustomCode) }
                .keyboardShortcut("n", modifiers: [.control, .command])
                .disabled(!canvasFocused)
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
            Divider()
            // Playback (spec §26.3): bare keys, gated on the canvas like every other bare key.
            // Bare Space is already the canvas's hold-to-pan latch (GraphCanvasView's
            // `.onKeyPress(.space, ...)`); a menu equivalent on the same key would win first on
            // macOS and silently kill pan, so Play/Pause binds to `p` instead. The title is a
            // static "Play/Pause" — reading `preview.clock.isPlaying` here would invalidate the
            // whole command tree on every drawn frame while playing.
            Button("Play/Pause") { model?.togglePlayback() }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!canvasFocused)
            Button("Previous Frame") { model?.stepPlayback(by: -1) }
                .keyboardShortcut(",", modifiers: [])
                .disabled(!canvasFocused)
            Button("Next Frame") { model?.stepPlayback(by: 1) }
                .keyboardShortcut(".", modifiers: [])
                .disabled(!canvasFocused)
            Button("Reset Playback") { model?.resetPlayback() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(!canvasFocused)
        }
    }
}
