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
    @State private var bridge: DocumentBridge?

    var body: some View {
        Group {
            if let bridge {
                EditorView(model: bridge.model, device: device)
                    // Model → file: the three observable fields the bridge mirrors. Keyed on
                    // `texturesVersion`, not the bytes (spec §21.2).
                    .onChange(of: bridge.model.document) { _, _ in mirror() }
                    .onChange(of: bridge.model.viewState) { _, _ in mirror() }
                    .onChange(of: bridge.model.texturesVersion) { _, _ in mirror() }
                    // File → model: the bridge decides whether this is an external change.
                    .onChange(of: file.package) { _, incoming in bridge.apply(incoming) }
            } else {
                Color.clear.onAppear(perform: makeModel)
            }
        }
        .onChange(of: undoManager) { _, manager in
            if let manager, let bridge { bridge.model.adoptUndoManager(manager) }
        }
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 620)
        #endif
    }

    /// Model → file, with the window's undo registration off for the duration. `DocumentGroup`
    /// registers an undo step for every write to a `FileDocument` binding, on the very manager the
    /// model drives — so without this, a camera pan or a breadcrumb exit landed as an unnamed
    /// group on top of the model's steps, and ⌘Z reverted the file instead of the edit (the
    /// bridge then reloaded that older package and cleared the real stack). The model's own
    /// snapshots are the only history a document has (spec §18.3); the mirror is not an edit.
    private func mirror() {
        guard let bridge else { return }
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        bridge.mirror(into: &file.package)
    }

    private func makeModel() {
        // One cache per window: `AssetID`s are only unique within their own document.
        let m = EditorModel(document: file.package.document, viewState: file.package.viewState,
                            textures: file.package.textures, compiler: compiler,
                            undoManager: undoManager, textureStore: TextureStore(device: device))
        m.missingTextures = file.package.missingTextures
        m.start()
        bridge = DocumentBridge(model: m)
    }

}
