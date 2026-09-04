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
    /// Bumped by every `start()`/`scheduleCompile()` so `awaitIdle` can tell whether a
    /// new edit landed while it was suspended (`Task` is a struct — no identity to compare).
    private var scheduleCount = 0

    public init(document: ShaderDocument, compiler: any ShaderCompiling,
                registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState()) {
        self.document = document
        self.compiler = compiler
        self.registry = registry
        self.preview = preview
    }

    /// First compile, undebounced.
    public func start() {
        scheduleCount += 1
        compileTask = Task { await self.compileNow() }
    }

    /// Waits for any pending debounce and compile. For tests and for save.
    /// Loops until quiescent: an edit landing while we're suspended reschedules
    /// work we haven't awaited yet, so a single await-pair could return early.
    public func awaitIdle() async {
        while true {
            let count = scheduleCount
            let d = debounceTask, c = compileTask
            await d?.value
            await c?.value
            if scheduleCount == count { return }   // nothing new was scheduled meanwhile
        }
    }

    public func apply(_ change: DocumentChange) {
        switch change {
        case .moveNodes(let positions):
            for (id, p) in positions { document.root.nodes[id]?.position = p }
        case .setParam(let id, let key, let value):
            document.root.nodes[id]?.params[key] = value
        case .setTitle(let id, let title):
            document.root.nodes[id]?.customTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        case .connect(let from, let to):
            document.root.connect(from, to: to)
        case .disconnect(let input):
            document.root.disconnect(input)
        case .addNode(let n):
            document.root.nodes[n.id] = n
        case .removeNodes(let ids):
            document.root.remove(nodes: ids)
            pruneSelection()
        case .insert(let nodes, let edges):
            for n in nodes { document.root.nodes[n.id] = n }
            for e in edges { document.root.connect(e.from, to: e.to) }
        case .setSettings(let s):
            document.settings = s
        case .restore(let doc):
            document = doc
            pruneSelection()
        }

        switch change.changeClass {
        case .cosmetic:
            break
        case .parameter:
            if case .setParam(let id, let key, let value) = change, var img = preview.uniforms {
                if !img.set(value, for: ParamPath(node: id, param: key)) {
                    scheduleCompile()
                }
                preview.uniforms = img
            }
        case .topology:
            scheduleCompile()
        }
    }

    /// Selection may only reference nodes that exist (spec §18.3).
    func pruneSelection() {
        viewState.selection = viewState.selection.filter { document.root.nodes[$0] != nil }
    }

    private func scheduleCompile() {
        scheduleCount += 1
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
        let registry = registry

        let result: Result<GeneratedShader, GenerationError> = await Task.detached(priority: .userInitiated) {
            generateResult(doc, registry: registry)
        }.value

        let shader: GeneratedShader
        switch result {
        case .success(let s):
            shader = s
        case .failure(let error):
            switch error {
            case .invalid(let diags):
                diagnostics = diags
            }
            preview.lastError = nil
            return                                   // keep last-good pipeline
        }
        diagnostics = []
        generatedSource = shader.source
        resolvedTypes = shader.resolved

        switch await compiler.compile(shader, generation: gen, fastMath: doc.settings.fastMath) {
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
                let sev: Diagnostic.Severity = l.severity == .error ? .error : .warning
                mapped.append(Diagnostic(sev, l.message, node: shader.lineMap.node(forLine: l.line)))
            }
            diagnostics = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
        case .superseded:
            break
        }
    }
}

/// Free function (not a closure) so the do/catch below infers `error` as the concrete
/// `GenerationError` from `ShaderGenerator.generate`'s typed throw, rather than `any Error`.
/// `nonisolated` so it actually runs on the `Task.detached` background thread instead of
/// hopping back to the main actor (this module defaults new declarations to `@MainActor`).
nonisolated private func generateResult(_ doc: ShaderDocument, registry: NodeRegistry) -> Result<GeneratedShader, GenerationError> {
    do {
        return .success(try ShaderGenerator.generate(doc, target: .fragment, registry: registry))
    } catch {
        return .failure(error)
    }
}
