import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender
import MetalNodesUI

/// One document window: builds the window's `EditorModel` on first appearance and keeps it in step
/// with the file in both directions — model → file so `DocumentGroup` sees the edit and marks the
/// window dirty, and file → model so a change that came from outside the editor (File ▸ Revert To
/// Saved) reseeds it rather than being silently overwritten by the next edit.
///
/// The model is created lazily because `\.undoManager` is nil on the very first pass — the window
/// publishes its manager a beat later, and `adoptUndoManager` takes it while the stack is still
/// empty (spec §21.1).
struct DocumentHostView: View {
    @Binding var file: ShaderFileDocument
    let device: MTLDevice
    let compiler: ShaderCompiler
    @Environment(\.undoManager) private var undoManager
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model, device: device)
                    // Model → file. View state is persisted next to the document (spec §3), so a
                    // camera move marks the window dirty too. Each write is guarded on a real
                    // difference, so a value that arrived *from* the file is never written back.
                    .onChange(of: model.document) { _, d in if file.package.document != d { file.package.document = d } }
                    .onChange(of: model.viewState) { _, v in if file.package.viewState != v { file.package.viewState = v } }
                    // Keyed on the counter, not the bytes: `onChange` compares its value on every
                    // body evaluation, and comparing the image dictionary itself is a deep compare
                    // of every imported texture (spec §21.2).
                    .onChange(of: model.texturesVersion) { _, _ in
                        if file.package.textures != model.textures { file.package.textures = model.textures }
                    }
                    // File → model. Watched per field rather than on the whole package: a field
                    // the mirror above just wrote already equals the model's, so only a change
                    // that did *not* come from the model gets this far, and `reseed` then checks
                    // the package as a whole so one revert is one reload.
                    .onChange(of: file.package.document) { _, _ in reseed() }
                    .onChange(of: file.package.viewState) { _, _ in reseed() }
                    .onChange(of: file.package.textures) { _, _ in reseed() }
            } else {
                Color.clear.onAppear(perform: makeModel)
            }
        }
        .onChange(of: undoManager) { _, manager in
            if let manager, let model { model.adoptUndoManager(manager) }
        }
        .frame(minWidth: 960, minHeight: 620)
    }

    /// Pulls the file back into the model when the two have genuinely diverged — i.e. the file
    /// was replaced under the editor. A no-op for anything the model itself just mirrored out.
    private func reseed() {
        guard let model else { return }
        let incoming = file.package
        guard incoming.document != model.document
                || incoming.viewState != model.viewState
                || incoming.textures != model.textures else { return }
        model.reload(package: incoming)
    }

    private func makeModel() {
        // One cache per window: `AssetID`s are only unique within their own document.
        let m = EditorModel(document: file.package.document, viewState: file.package.viewState,
                            textures: file.package.textures, compiler: compiler,
                            undoManager: undoManager, textureStore: TextureStore(device: device))
        m.missingTextures = file.package.missingTextures
        m.start()
        model = m
    }
}
