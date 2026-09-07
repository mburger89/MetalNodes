import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender
import MetalNodesUI
#if os(macOS)
import AppKit
#endif

@main
struct MetalNodesApp: App {
    private let device: MTLDevice
    private let compiler: ShaderCompiler

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is required") }
        self.device = device
        do { compiler = try ShaderCompiler(device: device) }
        catch { fatalError("Could not build the vertex stage: \(error)") }
        #if os(iOS)
        // iPad has no Help menu, and iPadOS 27 gives a `FileDocument` group no way to open a second
        // document from code (`openDocument` is macOS-only; `openURL` refuses file URLs; a
        // `DocumentGroupLaunchScene` door never learns which button made the document, and the
        // scene itself sent the document binding into an endless re-publish loop after a view-state
        // write). The sample is a file in On My iPad › MetalNodes instead, opened from the browser
        // like any other (spec §22.4, as amended by the M6 record).
        SamplePackage.installIntoDocuments()
        #endif
    }

    var body: some Scene {
        DocumentGroup(newDocument: ShaderFileDocument(package: ShaderPackage(document: LaunchFixture.document()))) { file in
            DocumentHostView(file: file.$document, device: device, compiler: compiler)
        }
        .commands {
            EditorCommands()
            #if os(macOS)
            CommandGroup(replacing: .help) {
                Button("Open Sample Shader") { openSample() }
            }
            #endif
        }
    }

    #if os(macOS)
    /// Opens the sample as a document, so Help ▸ Open Sample Shader lands in the same editor as
    /// any other file — and editing it never touches the original.
    private func openSample() {
        do {
            let url = try SamplePackage.writeTemporary()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    #endif
}
