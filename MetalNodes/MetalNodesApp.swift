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
        #if os(iOS)
        // The iPad launch screen (title, Create Document, the document browser). With it in place
        // the editor's split view owns the one navigation bar over a document; without it
        // `DocumentGroup` stacks its own bar above that one.
        //
        // No sample door here: iPadOS 27 gives a `FileDocument` group no way to open a second
        // document from code or to tell its launch-screen buttons apart (`openDocument` is
        // macOS-only, `openURL` refuses file URLs, `NewDocumentButton`'s `prepareDocumentURL` never
        // runs and its `contentType` is ignored). The sample is a file instead — installed into
        // On My iPad › MetalNodes at launch (`SamplePackage.installIntoDocuments`) and opened from
        // the browser like any other (spec §22.4, as amended by the M6 record).
        DocumentGroupLaunchScene("MetalNodes") {
            NewDocumentButton("Create Document")
        }
        #endif
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
