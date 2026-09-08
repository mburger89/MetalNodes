import SwiftUI
import MetalNodesCore

/// What replaces the canvas while a Custom MSL definition is open (spec §24.3, §24.4). The text
/// is the definition's body verbatim; the list beneath it carries the compiler's complaints at
/// the user's own line numbers.
///
/// **The error list is the deliverable, not the gutter.** A SwiftUI `TextEditor` gives no
/// per-line decoration without dropping to `NSTextView`/`UITextView` — a platform-pair's worth of
/// work for a coloured stripe. A list beneath the editor reading `3: use of undeclared identifier
/// 'qq'` delivers "errors at the user's line" (§24.4) without it. The gutter is a §25 idea.
///
/// **Deferred, not built:** the brief's sample text also promised "clicking a row selects that
/// line." That would mean wiring `TextEditor`'s `TextSelection` binding to a character range
/// computed from `row.line`, offset-matched against exactly the same line-counting
/// `LineMap.userLine(forLine:)` used to produce `row.line` in the first place (its own doc comment
/// warns that a mismatched CRLF-normalisation between the two makes the jump land on the wrong
/// visual line, Task 9). Nothing here builds that yet — rows are inert `Text`, not buttons — for
/// two reasons together: getting the offset arithmetic right is real work, not a rename, and I
/// have no way to drive the running app and see a caret actually land where I claim it does. Fix
/// round 1, review comment I2, ruled this out of the four deviations already recorded and asked
/// it be named explicitly — recorded here, not silently left unbuilt.
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
                // Switching to a different `.msl` definition without this view ever disappearing
                // (the palette's own "Edit" row can do that, Task 17 fix round 1, I6): commit the
                // *outgoing* definition's draft, by the `old` id the closure hands us — `definition`
                // itself has already become the new one by the time this runs — before overwriting
                // `draft` with the new definition's body, or an uncommitted edit is discarded.
                .onChange(of: definition) { old, id in
                    commit(for: old)
                    draft = model.codeBody(for: id)
                }
                .onChange(of: focused) { _, now in if !now { commit(for: definition) } }
                // CRITICAL (Task 17 fix round 1): `draft` is a local snapshot, and nothing kept it
                // in step with the document changing *underneath* this view — undo, redo, or File ▸
                // Revert To Saved all rewrite `document.definitions[id]?.body` directly, and none of
                // those touch `draft`. Left alone, ⌘Z looked like a no-op (the editor still showed
                // the undone text) and then silently reapplied it on the next focus loss, since
                // `commit()` compares `draft` against the *current* body and writes right back
                // whenever they differ. Watching the body itself — the same `.onChange(of: def.name)`
                // shape `DefinitionPane`'s own name field already uses — re-seeds `draft` on any
                // change that did not originate here; a change that *did* originate here (this
                // view's own `commit`) already leaves `draft` equal to the new body, so this is a
                // no-op for that case rather than a second write.
                //
                // Dropping focus here too, not just reseeding `draft`, is load-bearing — driven live
                // (fix round 1's review demanded it, not a unit test): reseed `draft` while the
                // platform text view underneath `TextEditor` still holds an *active* editing session
                // (this view still focused) and the reseed can be visually correct for a moment and
                // then silently lost — the session's own buffered text, never told the ground moved,
                // overwrites the binding right back when that session finally ends, and the next
                // focus-loss `commit` re-applies the very body this branch just reverted. Ending the
                // session ourselves, in the same update as the reseed, is what stops the old buffer
                // from ever getting a chance to flush.
                .onChange(of: model.codeBody(for: definition)) { _, body in
                    guard body != draft else { return }
                    draft = body
                    if focused { focused = false }
                }
            Divider()
            diagnosticsList
        }
        .background(DraculaToken.background.color)
        .onDisappear { commit(for: definition) }
    }

    /// Committing on focus loss rather than per keystroke: a half-typed statement is a compile
    /// error, and recompiling on every character would fill this list with noise about text the
    /// user is still writing (the same pattern `SocketRow` and the export-name field already use).
    private func commit(for id: GroupID) {
        guard draft != model.codeBody(for: id) else { return }
        model.apply(.setDefinitionBody(id, draft))
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
