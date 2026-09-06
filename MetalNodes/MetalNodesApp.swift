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
