import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender
import MetalNodesUI

/// One document window: builds the window's `EditorModel` on first appearance and mirrors what
/// the model owns back into the file so `DocumentGroup` sees the edit and marks the window dirty.
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
                    // View state is persisted next to the document (spec §3), so a camera move
                    // marks the window dirty too.
                    .onChange(of: model.document) { _, d in file.package.document = d }
                    .onChange(of: model.viewState) { _, v in file.package.viewState = v }
                    .onChange(of: model.textures) { _, t in file.package.textures = t }
            } else {
                Color.clear.onAppear(perform: makeModel)
            }
        }
        .onChange(of: undoManager) { _, manager in
            if let manager, let model { model.adoptUndoManager(manager) }
        }
        .frame(minWidth: 960, minHeight: 620)
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
