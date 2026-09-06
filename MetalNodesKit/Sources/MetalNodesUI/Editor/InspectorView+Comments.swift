import SwiftUI
import MetalNodesCore

/// Inspector pane for the one selected comment (spec §21.4): a note's text and accent, a frame's
/// title and accent.
struct CommentPane: View {
    let model: EditorModel
    let id: CommentID

    var body: some View {
        switch id {
        case .sticky(let s): StickyPane(model: model, id: s)
        case .frame(let f): FramePane(model: model, id: f)
        }
    }
}

/// The note's text is multi-line, so it commits on focus loss or ⌘↩ rather than on Return —
/// Return types a newline into the note.
private struct StickyPane: View {
    let model: EditorModel
    let id: StickyID
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        if let note = model.graph.stickies[id] {
            Text("Note").font(.headline)
            TextEditor(text: $draft)
                .font(.caption)
                .frame(minHeight: 120)
                .focused($editing)
                .onAppear { draft = note.text }
                .onChange(of: id) { _, _ in draft = note.text }
                // An undo, or an edit from anywhere else, re-seeds the field — but not while it is
                // being typed into, which would fight the cursor.
                .onChange(of: note.text) { _, t in if !editing { draft = t } }
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    commit()
                    editing = false
                    return .handled
                }
            Text("⌘↩ commits; so does clicking away.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            AccentPicker(accent: note.accent) { setAccent($0) }
        } else {
            Text("Unknown note").foregroundStyle(DraculaToken.muted.color)
        }
    }

    /// Both writers read the note back from the model rather than from the value the body closed
    /// over: clicking the picker first drops focus, which commits the draft, and `note` is that
    /// edit's *previous* text.
    private func commit() {
        guard let current = model.graph.stickies[id], draft != current.text else { return }
        model.apply(.updateSticky(id, text: draft, accent: current.accent))
    }

    private func setAccent(_ accent: DraculaAccent) {
        guard let current = model.graph.stickies[id] else { return }
        model.apply(.updateSticky(id, text: current.text, accent: accent))
    }
}

private struct FramePane: View {
    let model: EditorModel
    let id: FrameID
    @State private var draft = ""

    var body: some View {
        if let frame = model.graph.frames[id] {
            Text("Frame").font(.headline)
            TextField("Title", text: $draft, prompt: Text(frame.title))
                .textFieldStyle(.roundedBorder)
                .onAppear { draft = frame.title }
                .onChange(of: id) { _, _ in draft = frame.title }
                .onChange(of: frame.title) { _, t in draft = t }
                .onSubmit { commit() }
            AccentPicker(accent: frame.accent) { setAccent($0) }
        } else {
            Text("Unknown frame").foregroundStyle(DraculaToken.muted.color)
        }
    }

    /// Reads the frame back from the model for the same reason `StickyPane` does.
    private func commit() {
        guard let current = model.graph.frames[id] else { return }
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current.title else { draft = current.title; return }
        model.apply(.updateFrame(id, title: title, accent: current.accent))
    }

    private func setAccent(_ accent: DraculaAccent) {
        guard let current = model.graph.frames[id] else { return }
        model.apply(.updateFrame(id, title: current.title, accent: accent))
    }
}

/// The accent menu both comment panes share, laid out like the definition pane's.
/// The closure is a plain main-actor value and is wrapped, not passed, into the binding: Swift 6.2's
/// IR generation crashes on the thunk for a `@MainActor @Sendable` closure used as `Binding.set`.
private struct AccentPicker: View {
    let accent: DraculaAccent
    let onChange: (DraculaAccent) -> Void

    var body: some View {
        Picker("Accent", selection: Binding(get: { accent }, set: { onChange($0) })) {
            ForEach(DraculaAccent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }
}
