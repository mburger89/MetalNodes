import Foundation
import Observation
import MetalNodesCore
import MetalNodesRender

public enum CanvasRequest: Equatable, Sendable {
    case fitAll, fitSelection
    /// Add a builtin at the viewport centre (palette double-click).
    case place(defID: String)
    /// Add a group instance at the viewport centre ("My Functions" double-click, spec §20.8).
    case placeGroup(GroupID)
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
    /// A transient message for the preview pane's diagnostics strip (a refused recursive
    /// placement, spec §20.8). Cleared after 3 s.
    public var notice: String?
    /// Bumped by File ▸ Export Shader…; the macOS view presents the save panel on change.
    public private(set) var exportRequest = 0
    public func requestExport() { exportRequest += 1 }

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

    // MARK: The active graph (spec §20.3)

    /// The graph every change and every canvas gesture is bound to: the last dived instance's
    /// definition, else the definition opened from the palette, else the root.
    public var activePath: GraphPath { viewState.activePath(in: document) }
    public var graph: Graph { document[activePath] }
    public func shape(of node: NodeInstance) -> NodeShape? { document.shape(of: node, in: activePath, registry: registry) }
    public func shape(of id: NodeID) -> NodeShape? { document.shape(of: id, registry: registry) }

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
        let path = activePath
        switch change {
        case .moveNodes(let positions):
            for (id, p) in positions { document[path].nodes[id]?.position = p }
        case .setParam(let id, let key, let value):
            document[path].nodes[id]?.params[key] = value
        case .setTitle(let id, let title):
            document[path].nodes[id]?.customTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        case .connect(let from, let to):
            document[path].connect(from, to: to)
        case .disconnect(let input):
            document[path].disconnect(input)
        case .addNode(let n):
            document[path].nodes[n.id] = n
        case .removeNodes(let ids):
            // Pseudo-nodes are part of their definition's shape and cannot be deleted (spec §20.8).
            document[path].remove(nodes: ids.filter { shape(of: $0)?.isPseudo != true })
            pruneAfterRemoval()
        case .insert(let nodes, let edges, let definitions):
            // Reuse, import or insert what the payload brought, then retarget the instances (spec §20.7).
            let plan = ClipboardMerge.plan(definitions: definitions, into: document)
            for d in plan.insert { document.definitions[d.id] = d }
            for n in ClipboardMerge.apply(plan, to: nodes) { document[path].nodes[n.id] = n }
            for e in edges { document[path].connect(e.from, to: e.to) }
        case .groupSelection(let ids, let name):
            if let r = GroupOperations.group(ids, in: path, of: document, registry: registry, name: name) {
                document = r.document
                viewState.selection = [r.instance]
            }
        case .ungroup(let id):
            if let r = GroupOperations.ungroup(id, in: path, of: document) {
                document = r.document
                viewState.selection = r.nodes
                pruneAfterRemoval()
            }
        case .makeUnique(let id):
            if let r = GroupOperations.makeUnique(id, in: path, of: document) { document = r.document }
        case .renameDefinition(let id, let name):
            document = GroupOperations.rename(id, to: name, in: document) ?? document
        case .setDefinitionAccent(let id, let accent):
            document = GroupOperations.setAccent(id, accent, in: document) ?? document
        case .addSocket(let id, let kind, let decl):
            document = GroupOperations.addSocket(id, kind: kind, decl: decl, in: document) ?? document
        case .renameSocket(let id, let kind, let old, let new):
            document = GroupOperations.renameSocket(id, kind: kind, from: old, to: new, in: document) ?? document
        case .removeSocket(let id, let kind, let name):
            document = GroupOperations.removeSocket(id, kind: kind, name: name, in: document) ?? document
        case .deleteDefinition(let id):
            document = GroupOperations.deleteDefinition(id, in: document) ?? document
            pruneAfterRemoval()
        case .setSettings(let s):
            // Spec §18.2: settings are cosmetic unless `fastMath` or `target` flips — both are
            // part of what gets compiled, so they need a rebuild; preview size and time mode do not.
            // Under a stitchable target `exportName` also names the generated function, so a rename
            // changes the source too (spec §19.4).
            recompile = s.fastMath != document.settings.fastMath
                || s.target != document.settings.target
                || (s.target.stitchableKind != nil && s.exportName != document.settings.exportName)
            document.settings = s
        case .restore(let doc):
            document = doc
            pruneAfterRemoval()
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

    /// Anything gone from the document drops out of view state, innermost reference first: the
    /// editing stack decides the active path, which decides what a selection may name (spec §20.3).
    private func pruneAfterRemoval() {
        pruneEditingStack()
        pruneSelection()
        _ = pruneViewer()
    }

    /// Selection may only reference nodes of the active graph (spec §18.3, §20.3).
    func pruneSelection() {
        let g = graph
        viewState.selection = viewState.selection.filter { g.nodes[$0] != nil }
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

        // A viewer inside a definition is reached through the instances dived through and/or the
        // definition opened from the palette; one in the root is the ordinary program (spec §20.5).
        let viewer = viewState.viewer
        let inDefinition = viewer.flatMap { document.node($0.node)?.path != .root } ?? false
        let viewerPath = inDefinition ? viewState.editingStack : []
        let viewerDefinition = inDefinition ? viewState.editingDefinition : nil
        let result: Result<GeneratedShader, GenerationError> = await Task.detached(priority: .userInitiated) {
            generateResult(doc, target: doc.settings.target, viewer: viewer, viewerPath: viewerPath,
                           viewerDefinition: viewerDefinition, registry: registry)
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

    public func exportFiles() throws(GenerationError) -> [ExportFile] {
        try ShaderExport.files(for: document, registry: registry)
    }

    /// Puts the `.swift` snippet on the pasteboard as plain text. False for the fragment target.
    @discardableResult
    public func copySwiftSnippet() -> Bool {
        guard let files = try? exportFiles(), let swift = files.first(where: { $0.name.hasSuffix(".swift") }) else { return false }
        pasteboard.write(Data(swift.contents.utf8), type: "public.utf8-plain-text")
        return true
    }

    /// "Title.socket" for a source ref, used by the inspector's "← source" labels and the
    /// viewer picker. Falls back to the node's custom title, then its shape's title. Resolves
    /// document-wide, so it also labels a socket inside a definition (spec §20.3).
    public func socketLabel(_ ref: SocketRef) -> String {
        guard let n = document.node(ref.node)?.node, let s = shape(of: ref.node) else { return ref.socket }
        return "\(n.customTitle ?? s.title).\(ref.socket)"
    }
}

/// Free function (not a closure) so the do/catch below infers `error` as the concrete
/// `GenerationError` from `ShaderGenerator.generate`'s typed throw, rather than `any Error`.
/// `nonisolated` so it actually runs on the `Task.detached` background thread instead of
/// hopping back to the main actor (this module defaults new declarations to `@MainActor`).
nonisolated private func generateResult(_ doc: ShaderDocument, target: OutputTarget, viewer: SocketRef?,
                                        viewerPath: [NodeID], viewerDefinition: GroupID?,
                                        registry: NodeRegistry) -> Result<GeneratedShader, GenerationError> {
    do {
        return .success(try ShaderGenerator.generate(doc, target: target, viewer: viewer, viewerPath: viewerPath,
                                                     viewerDefinition: viewerDefinition, registry: registry))
    } catch {
        return .failure(error)
    }
}
