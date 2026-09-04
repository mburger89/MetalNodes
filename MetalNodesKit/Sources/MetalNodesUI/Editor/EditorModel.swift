import Foundation
import Observation
import MetalNodesCore
import MetalNodesRender

@MainActor
@Observable
public final class EditorModel {
    public private(set) var document: ShaderDocument
    public var viewState = EditorViewState()
    public let preview: PreviewState
    public let registry: NodeRegistry
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var generatedSource = ""
    public private(set) var resolvedTypes: [NodeID: ResolvedNode] = [:]
    public var debounceInterval: Duration = .milliseconds(150)

    private let compiler: any ShaderCompiling
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var compileTask: Task<Void, Never>?

    public init(document: ShaderDocument, compiler: any ShaderCompiling,
                registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState()) {
        self.document = document
        self.compiler = compiler
        self.registry = registry
        self.preview = preview
    }

    /// First compile, undebounced.
    public func start() {
        compileTask = Task { await self.compileNow() }
    }

    /// Waits for any pending debounce and compile. For tests and for save.
    public func awaitIdle() async {
        await debounceTask?.value
        await compileTask?.value
    }

    public func apply(_ change: DocumentChange) {
        switch change {
        case .moveNode(let id, let p):
            document.root.nodes[id]?.position = p
        case .setParam(let id, let key, let value):
            document.root.nodes[id]?.params[key] = value
        case .connect(let from, let to):
            document.root.connect(from, to: to)
        case .disconnect(let input):
            document.root.disconnect(input)
        case .addNode(let n):
            document.root.nodes[n.id] = n
        case .removeNode(let id):
            document.root.remove(node: id)
        }

        switch change.changeClass {
        case .cosmetic:
            break
        case .parameter:
            if case .setParam(let id, let key, let value) = change, var img = preview.uniforms {
                img.set(value, for: ParamPath(node: id, param: key))
                preview.uniforms = img
            }
        case .topology:
            scheduleCompile()
        }
    }

    private func scheduleCompile() {
        debounceTask?.cancel()
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            self.compileTask = Task { await self.compileNow() }
            await self.compileTask?.value
        }
    }

    private func compileNow() async {
        generation += 1
        let gen = generation
        let doc = document

        let shader: GeneratedShader
        do {
            shader = try ShaderGenerator.generate(doc, target: .fragment, registry: registry)
        } catch GenerationError.invalid(let diags) {
            diagnostics = diags
            return                                   // keep last-good pipeline
        } catch {
            diagnostics = [Diagnostic(.error, "\(error)")]
            return
        }
        diagnostics = []
        generatedSource = shader.source
        resolvedTypes = shader.resolved

        switch await compiler.compile(shader, generation: gen) {
        case .success(let pipeline):
            guard pipeline.generation == generation else { return }
            preview.pipeline = pipeline
            preview.uniforms = UniformImage.rebuild(layout: pipeline.shader.layout, document: document, registry: registry)
            preview.lastError = nil
        case .failure(let message, let lines, let g):
            guard g == generation else { return }
            preview.lastError = message
            var mapped: [Diagnostic] = []
            for l in lines {
                if let node = shader.lineMap.node(forLine: l.line) {
                    mapped.append(Diagnostic(.error, l.message, node: node))
                }
            }
            diagnostics = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
        case .superseded:
            break
        }
    }
}
