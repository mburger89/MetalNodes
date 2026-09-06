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
    #if os(iOS)
    /// Not `\.openDocument`: that environment action is macOS-only (SwiftUI declares it
    /// `macOS 13.0+`), so the iPad opens the sample the way any other app would hand us a
    /// `.mnshader` — through the system, which routes the URL back to this app's `DocumentGroup`
    /// and opens it in its own scene.
    @Environment(\.openURL) private var openURL
    @State private var sampleError: String?
    #endif

    var body: some View {
        Group {
            if let bridge {
                EditorView(model: bridge.model, device: device)
                    // Model → file: the three observable fields the bridge mirrors. Keyed on
                    // `texturesVersion`, not the bytes (spec §21.2).
                    .onChange(of: bridge.model.document) { _, _ in bridge.mirror(into: &file.package) }
                    .onChange(of: bridge.model.viewState) { _, _ in bridge.mirror(into: &file.package) }
                    .onChange(of: bridge.model.texturesVersion) { _, _ in bridge.mirror(into: &file.package) }
                    // File → model: the bridge decides whether this is an external change.
                    .onChange(of: file.package) { _, incoming in bridge.apply(incoming) }
            } else {
                Color.clear.onAppear(perform: makeModel)
            }
        }
        .onChange(of: undoManager) { _, manager in
            if let manager, let bridge { bridge.model.adoptUndoManager(manager) }
        }
        #if os(iOS)
        // iPad has no Help menu; the sample rides the document's toolbar overflow (spec §22.4).
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Open Sample Shader", systemImage: "sparkles") { openSample() }
            }
        }
        .alert("Could not open the sample", isPresented: Binding(get: { sampleError != nil },
                                                                set: { if !$0 { sampleError = nil } })) {
            Button("OK") { sampleError = nil }
        } message: { Text(sampleError ?? "") }
        #endif
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 620)
        #endif
    }

    #if os(iOS)
    /// Writes the sample and hands its URL to the system, which opens it in this app — the
    /// document type is ours — leaving the current document open behind it, exactly what tapping
    /// the file in Files would do. A refusal is reported rather than swallowed.
    private func openSample() {
        do {
            let url = try SamplePackage.writeTemporary()
            openURL(url) { accepted in
                if !accepted { sampleError = "The system would not open \(url.lastPathComponent)." }
            }
        } catch {
            sampleError = error.localizedDescription
        }
    }
    #endif

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
