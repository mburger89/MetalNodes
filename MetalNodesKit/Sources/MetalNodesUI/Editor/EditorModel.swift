import Foundation
import Observation
import MetalNodesCore
import MetalNodesRender

public enum CanvasRequest: Equatable, Sendable {
    case fitAll, fitSelection
    /// Add a builtin at the viewport centre (palette double-click).
    case place(defID: String)
}

@MainActor
@Observable
public final class EditorModel {
    public private(set) var document: ShaderDocument
    public var viewState = EditorViewState()
    /// The one selected wire, by its input socket. Transient (not view state, not undo).
    public var selectedWire: SocketRef?
    /// One-shot requests from menus/commands to the canvas view, which consumes and clears them.
    public var canvasRequest: CanvasRequest?
    public func requestCanvas(_ r: CanvasRequest) { canvasRequest = r }
    /// Bumped whenever the undo stack changes, so `canUndo`/`canRedo` (which forward to the
    /// non-`@Observable` `UndoManager`) trigger SwiftUI updates (menu `.disabled(...)`).
    public var undoStackVersion = 0
    /// Whether the canvas (as opposed to a node's parameter field) is the focused responder.
    /// Gates menu-command keyboard shortcuts so they don't steal keystrokes from text fields.
    public var canvasHasFocus = false
    public let preview: PreviewState
    public let registry: NodeRegistry
    public let pasteboard: any Pasteboarding
    public nonisolated static let pasteboardType = "com.maxburger.metalnodes.graph"
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var generatedSource = ""
    public private(set) var resolvedTypes: [NodeID: ResolvedNode] = [:]
    public var debounceInterval: Duration = .milliseconds(150)

    private let compiler: any ShaderCompiling
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var compileTask: Task<Void, Never>?
    /// The last **non-superseded** compile's outcome, keyed on the program it settled: reused to
    /// skip the compiler when the generated source and fast-math flag come back unchanged (spec §19.1).
    private var lastCompiled: (source: String, fastMath: Bool, succeeded: Bool)?
    /// Bumped by every `start()`/`scheduleCompile()` so `awaitIdle` can tell whether a
    /// new edit landed while it was suspended (`Task` is a struct — no identity to compare).
    private var scheduleCount = 0

    // MARK: Undo (spec §18.3) — see EditorModel+Undo.swift
    public let undoManager = UndoManager()
    var transactionSnapshot: ShaderDocument?
    var transactionName = ""
    var transactionDepth = 0

    public init(document: ShaderDocument, compiler: any ShaderCompiling,
                registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState(),
                pasteboard: any Pasteboarding = SystemPasteboard()) {
        self.document = document
        self.compiler = compiler
        self.registry = registry
        self.preview = preview
        self.pasteboard = pasteboard
        undoManager.groupsByEvent = false
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
        if case .restore = change {             // undo/redo path: no transaction, no registration
            perform(change)
            return
        }
        if transactionSnapshot != nil {
            perform(change)
        } else {
            let before = document
            perform(change)
            commitUndo(before: before, name: change.undoName)
        }
    }

    private func perform(_ change: DocumentChange) {
        // Set by a case that is topology for a reason `changeClass` cannot see on its own.
        var recompile = false
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
            _ = pruneViewer()
        case .insert(let nodes, let edges):
            for n in nodes { document.root.nodes[n.id] = n }
            for e in edges { document.root.connect(e.from, to: e.to) }
        case .setSettings(let s):
            // Spec §18.2: settings are cosmetic unless `fastMath` or `target` flips — both are
            // part of what gets compiled, so they need a rebuild; preview size and time mode do not.
            recompile = s.fastMath != document.settings.fastMath || s.target != document.settings.target
            document.settings = s
        case .restore(let doc):
            document = doc
            pruneSelection()
            _ = pruneViewer()
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
            recompile = true
        }
        if recompile { scheduleCompile() }
    }

    /// Selection may only reference nodes that exist (spec §18.3).
    func pruneSelection() {
        viewState.selection = viewState.selection.filter { document.root.nodes[$0] != nil }
    }

    func scheduleCompile() {
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

        let viewer = viewState.viewer
        let result: Result<GeneratedShader, GenerationError> = await Task.detached(priority: .userInitiated) {
            generateResult(doc, target: doc.settings.target, viewer: viewer, registry: registry)
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

        if let last = lastCompiled, last.source == shader.source, last.fastMath == doc.settings.fastMath {
            // Same program as the last settled compile (typically an undo of a cosmetic edit): its
            // outcome still stands. Refresh what depends on the document and skip the compiler (§19.1).
            generatedSource = shader.source
            resolvedTypes = shader.resolved
            if last.succeeded, let p = preview.pipeline {
                diagnostics = []
                preview.uniforms = UniformImage.rebuild(layout: p.shader.layout, document: document, registry: registry)
            }
            return
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
            lastCompiled = (shader.source, doc.settings.fastMath, true)
        case .failure(let message, let lines, let g):
            guard g == generation else { return }
            preview.lastError = message
            var mapped: [Diagnostic] = []
            for l in lines {
                let sev: Diagnostic.Severity = l.severity == .error ? .error : .warning
                mapped.append(Diagnostic(sev, l.message, node: shader.lineMap.node(forLine: l.line)))
            }
            diagnostics = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
            lastCompiled = (shader.source, doc.settings.fastMath, false)
        case .superseded:
            break
        }
    }

    public var errorNodes: Set<NodeID> { Set(diagnostics.filter { $0.severity == .error }.compactMap(\.node)) }

    /// "Title.socket" for a source ref, used by the inspector's "← source" labels and the
    /// viewer picker. Falls back to the node's custom title, then its definition's title.
    public func socketLabel(_ ref: SocketRef) -> String {
        guard let n = document.root.nodes[ref.node], case .builtin(let d) = n.kind else { return ref.socket }
        return "\(n.customTitle ?? registry[d]?.title ?? d).\(ref.socket)"
    }
}

/// Free function (not a closure) so the do/catch below infers `error` as the concrete
/// `GenerationError` from `ShaderGenerator.generate`'s typed throw, rather than `any Error`.
/// `nonisolated` so it actually runs on the `Task.detached` background thread instead of
/// hopping back to the main actor (this module defaults new declarations to `@MainActor`).
nonisolated private func generateResult(_ doc: ShaderDocument, target: OutputTarget, viewer: SocketRef?,
                                        registry: NodeRegistry) -> Result<GeneratedShader, GenerationError> {
    do {
        return .success(try ShaderGenerator.generate(doc, target: target, viewer: viewer, registry: registry))
    } catch {
        return .failure(error)
    }
}
