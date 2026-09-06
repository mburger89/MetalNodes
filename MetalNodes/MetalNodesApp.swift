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
        DocumentGroup(newDocument: ShaderFileDocument(package: ShaderPackage(document: .starter()))) { file in
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
    /// Writes `sample()` to a fresh temp package and opens it as a document, so Help ▸ Open Sample
    /// Shader lands in the same editor as any other file — and editing it never touches the original.
    private func openSample() {
        do {
            let directory = URL.temporaryDirectory
                .appending(path: "Samples/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "Sample.mnshader")
            try ShaderPackage(document: .sample()).fileWrapper()
                .write(to: url, options: .atomic, originalContentsURL: nil)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    #endif
}
