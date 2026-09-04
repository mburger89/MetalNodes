import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender
import MetalNodesUI

@main
struct MetalNodesApp: App {
    private let device: MTLDevice
    @State private var model: EditorModel

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is required") }
        self.device = device
        let compiler: ShaderCompiler
        do { compiler = try ShaderCompiler(device: device) }
        catch { fatalError("Could not build the vertex stage: \(error)") }
        _model = State(initialValue: EditorModel(document: .sample(), compiler: compiler))
    }

    var body: some Scene {
        WindowGroup("MetalNodes") {
            EditorView(model: model, device: device)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { model.start() }
        }
    }
}
