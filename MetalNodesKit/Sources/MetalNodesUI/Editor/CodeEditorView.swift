import SwiftUI
import MetalNodesCore

/// What replaces the canvas while a Custom MSL definition is open (spec §24.3, §24.4). The text
/// is the definition's body verbatim; the list beneath it carries the compiler's complaints at
/// the user's own line numbers.
///
/// **The error list is the deliverable, not the gutter.** A SwiftUI `TextEditor` gives no
/// per-line decoration without dropping to `NSTextView`/`UITextView` — a platform-pair's worth of
/// work for a coloured stripe. A list beneath the editor reading `3: use of undeclared identifier
/// 'qq'`, where clicking a row selects that line, delivers "errors at the user's line" (§24.4)
/// without it. The gutter is a §25 idea.
struct CodeEditorView: View {
    let model: EditorModel
    let definition: GroupID

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .background(DraculaToken.background.color)
                .focused($focused)
                .onAppear { draft = model.codeBody(for: definition) }
                .onChange(of: definition) { _, id in draft = model.codeBody(for: id) }
                .onChange(of: focused) { _, now in if !now { commit() } }
            Divider()
            diagnosticsList
        }
        .background(DraculaToken.background.color)
        .onDisappear { commit() }
    }

    /// Committing on focus loss rather than per keystroke: a half-typed statement is a compile
    /// error, and recompiling on every character would fill this list with noise about text the
    /// user is still writing (the same pattern `SocketRow` and the export-name field already use).
    private func commit() {
        guard draft != model.codeBody(for: definition) else { return }
        model.apply(.setDefinitionBody(definition, draft))
    }

    @ViewBuilder
    private var diagnosticsList: some View {
        let rows = model.codeDiagnostics(for: definition)
        if rows.isEmpty {
            HStack {
                Text("No problems").font(.caption).foregroundStyle(DraculaToken.muted.color)
                Spacer()
                Text("Click away to compile — the preview updates when the code is valid")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
            .padding(8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.line > 0 ? "\(row.line)" : "—")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(DraculaToken.muted.color)
                                .frame(width: 24, alignment: .trailing)
                            Text(row.line > 0 ? row.message : "in generated code: \(row.message)")
                                .font(.caption2)
                                .foregroundStyle(row.severity == .error
                                                 ? DraculaTheme.error.color : DraculaToken.orange.color)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 120)
        }
    }
}
