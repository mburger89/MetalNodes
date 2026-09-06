import Foundation
import CoreGraphics
import Observation
import MetalNodesCore
import MetalNodesRender

public enum CanvasRequest: Equatable, Sendable {
    case fitAll, fitSelection
    /// Add a builtin at the viewport centre (palette double-click).
    case place(defID: String)
    /// Add a group instance at the viewport centre ("My Functions" double-click, spec §20.8).
    case placeGroup(GroupID)
    /// Pan so this canvas point sits at the viewport centre (minimap click/drag, spec §21.6).
    case centerOn(CGPoint)
    /// Add a sticky note centred on the viewport (Edit ▸ Add Sticky Note, spec §21.4).
    case addSticky
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
    /// Alongside `generatedSource`, for the code panel's selected-node line highlight (spec §21.5).
    public private(set) var generatedLineMap = LineMap()
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
    /// The window's manager once a document window hands one over, else a private one.
    public private(set) var undoManager: UndoManager
    var transactionSnapshot: ShaderDocument?
    var transactionName = ""
    var transactionDepth = 0

    // MARK: Textures (spec §21.2)

    /// The imported image bytes, keyed as in `document.settings.assets`. Written by image import
    /// and by the package that opened the document; never re-encoded.
    public var textures: [AssetID: Data] = [:] {
        didSet {
            texturesVersion += 1
            // A thumbnail is only valid while the bytes it was decoded from are still the ones
            // under its id: drop the entries whose bytes changed or went away (a relink, a revert).
            thumbnailCache = thumbnailCache.filter { textures[$0.key] == oldValue[$0.key] }
            refreshTextureBindings()
        }
    }
    /// Small decoded thumbnails, one per asset, built on demand by `thumbnail(for:)`. Not observed:
    /// it is a cache of what `textures` already says, filled *during* a view's body evaluation, and
    /// every reader reaches it through `textures`, which is observed.
    @ObservationIgnored var thumbnailCache: [AssetID: CGImage] = [:]
    /// Bumped on every write to `textures`. A host mirroring the bytes into its file document can
    /// observe this instead of `textures` itself, which would deep-compare every image on each change.
    public private(set) var texturesVersion = 0
    /// Assets whose bytes were absent from the package on open: each referenced one becomes a
    /// warning diagnostic after generation, and its slot binds the placeholder.
    public var missingTextures: Set<AssetID> = []
    /// Everything the `.mnshader` package holds, assembled from the model's live state.
    public var package: ShaderPackage {
        ShaderPackage(document: document, viewState: viewState, textures: textures)
    }
    let textureStore: TextureStore?
    /// The slots of the last generated program, kept so `textures` changes can rebind without
    /// waiting for a recompile.
    private var textureSlots: [TextureSlot] = []

    public init(document: ShaderDocument, viewState: EditorViewState = EditorViewState(),
                textures: [AssetID: Data] = [:], compiler: any ShaderCompiling,
                registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState(),
                pasteboard: any Pasteboarding = SystemPasteboard(),
                undoManager: UndoManager? = nil, textureStore: TextureStore? = nil) {
        self.document = document
        self.viewState = viewState
        self.textures = textures
        self.compiler = compiler
        self.registry = registry
        self.preview = preview
        self.pasteboard = pasteboard
        self.textureStore = textureStore
        // A private manager needs `groupsByEvent` off so `commitUndo`'s own grouping is the only
        // one; the window's belongs to AppKit, which configures it, so leave that one alone.
        self.undoManager = undoManager ?? {
            let own = UndoManager()
            own.groupsByEvent = false
            return own
        }()
    }

    /// Replaces everything the package owns because the file changed underneath the editor —
    /// File ▸ Revert To Saved, or any other reseed by the document host (spec §21.1).
    ///
    /// Deliberately not an edit: nothing on the undo stack applies to the document that just
    /// arrived, so the stack is dropped rather than extended. Going through `apply(.restore(_:))`
    /// instead would register the revert as an undoable step, which would let ⌘Z resurrect the
    /// content the user just discarded.
    public func reload(package: ShaderPackage) {
        // A gesture that was open belongs to the document being replaced; its snapshot must not
        // survive to be committed against the new one.
        transactionSnapshot = nil
        transactionDepth = 0

        document = package.document
        viewState = package.viewState
        textures = package.textures
        missingTextures = package.missingTextures
        selectedWire = nil
        shapesVersion += 1                      // a whole new document: nothing cached still holds
        pruneAfterRemoval()

        undoManager.removeAllActions()
        undoStackVersion += 1
        scheduleCompile()
    }

    /// Takes the document window's manager once SwiftUI publishes it (the environment value is
    /// nil on the first pass). Refused once anything is on the current stack, so a step already
    /// registered can never be stranded on a manager nobody drives.
    public func adoptUndoManager(_ manager: UndoManager) {
        guard manager !== undoManager, !undoManager.canUndo, !undoManager.canRedo else { return }
        undoManager = manager
        undoStackVersion += 1
    }

    /// Rebinds `preview.textures` from the last generated program's slots. Called whenever the
    /// slots, the bytes or the manifest change (spec §21.2).
    func refreshTextureBindings() {
        guard let textureStore else { return }
        preview.textures = textureStore.bindings(for: textureSlots, textures: textures)
    }

    // MARK: The active graph (spec §20.3)

    /// The graph every change and every canvas gesture is bound to: the last dived instance's
    /// definition, else the definition opened from the palette, else the root.
    public var activePath: GraphPath { viewState.activePath(in: document) }
    public var graph: Graph { document[activePath] }

    // MARK: Shapes (spec §21.8)

    /// One `NodeShape` per node of the active graph — pseudo-nodes included, since inside a
    /// definition they are nodes of that graph. Nodes with no shape (an unknown builtin, a dangling
    /// instance) have no entry.
    ///
    /// Rebuilt lazily, because the canvas asks for a shape once per node per layout pass and
    /// resolving one walks the document: the cache stands until the document changes (`shapesVersion`)
    /// or the editor moves to another graph (the path). Reading `activePath` is also what registers
    /// this accessor's observation dependency on `viewState` and `document`, so a view laying out
    /// from the cache still updates on every edit.
    public var shapes: [NodeID: NodeShape] {
        let path = activePath
        if let key = shapesCacheKey, key.version == shapesVersion, key.path == path { return shapesCache }
        let g = document[path]
        var built = [NodeID: NodeShape](minimumCapacity: g.nodes.count)
        for (id, node) in g.nodes { built[id] = document.shape(of: node, in: path, registry: registry) }
        shapesCache = built
        shapesCacheKey = (shapesVersion, path)
        shapeCacheRebuilds += 1
        return built
    }

    /// The cached shapes and the document version + graph they were built for.
    @ObservationIgnored private var shapesCache: [NodeID: NodeShape] = [:]
    @ObservationIgnored private var shapesCacheKey: (version: Int, path: GraphPath)?
    /// Bumped after every document mutation, which is what makes the cache stale. Not observed:
    /// `shapes` reads `document` anyway (through `activePath`), so views already track edits.
    @ObservationIgnored private var shapesVersion = 0
    /// How often `shapes` actually recomputed. Internal, for the tests that assert the cache holds.
    @ObservationIgnored private(set) var shapeCacheRebuilds = 0

    public func shape(of node: NodeInstance) -> NodeShape? {
        shapes[node.id] ?? document.shape(of: node, in: activePath, registry: registry)
    }

    /// Document-wide, so the inspector and the viewer picker can name a node inside another graph;
    /// the active graph's nodes come from the cache.
    public func shape(of id: NodeID) -> NodeShape? {
        shapes[id] ?? document.shape(of: id, registry: registry)
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
        let path = activePath
        // A manifest edit (import, removal, re-import) rebinds the preview's slots even though the
        // bytes did not move — `.setSettings` and `.restore` both carry one (spec §21.2).
        let assetsBefore = document.settings.assets
        switch change {
        case .moveNodes(let positions):
            // One graph write for the whole drag frame, not one per node.
            var g = document[path]
            for (id, p) in positions { g.nodes[id]?.position = p }
            document[path] = g
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
        case .insert(let nodes, let edges, let definitions, let assets, let stickies, let frames):
            // Reuse, import or insert what the payload brought, then retarget the instances (spec §20.7).
            let plan = ClipboardMerge.plan(definitions: definitions, into: document)
            for d in plan.insert { document.definitions[d.id] = d }
            // One graph write for the whole paste, not one per node and one per wire.
            var g = document[path]
            for n in ClipboardMerge.apply(plan, to: nodes) { g.nodes[n.id] = n }
            for e in edges { g.connect(e.from, to: e.to) }
            for s in stickies { g.stickies[s.id] = s }
            for f in frames { g.frames[f.id] = f }
            document[path] = g
            // Spec §13, §21.2: add what the destination lacks; an id it already has keeps its
            // own manifest entry and bytes, never overwritten.
            for (id, asset) in assets where document.settings.assets[id] == nil {
                document.settings.assets[id] = asset.info
                textures[id] = asset.data
            }
        case .groupSelection(let ids, let name):
            if let r = GroupOperations.group(ids, in: path, of: document, registry: registry, name: name) {
                document = r.document
                // The grouped nodes left the active graph: prune *after* selecting the new
                // instance, so it survives and only a viewer on what moved is dropped.
                viewState.selection = [r.instance]
                pruneAfterRemoval()
            }
        case .ungroup(let id):
            if let r = GroupOperations.ungroup(id, in: path, of: document) {
                document = r.document
                viewState.selection = r.nodes
                pruneAfterRemoval()
            }
        case .makeUnique(let id):
            // The instance now points at a copy with fresh inner ids, so a viewer routed through
            // it no longer resolves.
            if let r = GroupOperations.makeUnique(id, in: path, of: document) {
                document = r.document
                pruneAfterRemoval()
            }
        case .renameDefinition(let id, let name):
            document = GroupOperations.rename(id, to: name, in: document) ?? document
        case .setDefinitionAccent(let id, let accent):
            document = GroupOperations.setAccent(id, accent, in: document) ?? document
        case .addSocket(let id, let kind, let decl):
            document = GroupOperations.addSocket(id, kind: kind, decl: decl, in: document) ?? document
        case .renameSocket(let id, let kind, let old, let new):
            document = GroupOperations.renameSocket(id, kind: kind, from: old, to: new, in: document) ?? document
            pruneAfterRemoval()                      // the viewed socket may have been the renamed one
        case .removeSocket(let id, let kind, let name):
            document = GroupOperations.removeSocket(id, kind: kind, name: name, in: document) ?? document
            pruneAfterRemoval()
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
        case .addSticky(let note):
            document[path].stickies[note.id] = note
        case .updateSticky(let id, let text, let accent):
            document[path].stickies[id]?.text = text
            document[path].stickies[id]?.accent = accent
        case .addFrame(let frame):
            document[path].frames[frame.id] = frame
        case .updateFrame(let id, let title, let accent):
            document[path].frames[id]?.title = title
            document[path].frames[id]?.accent = accent
        case .moveComments(let origins):
            // One graph write for the whole drag frame, as `.moveNodes` does.
            var g = document[path]
            for (id, p) in origins { g[comment: id]?.origin = p }
            document[path] = g
        case .resizeComment(let id, let rect):
            document[path][comment: id] = rect
        case .removeComments(let ids):
            var g = document[path]
            for id in ids { g.remove(comment: id) }
            document[path] = g
            pruneCommentSelection()
        case .restore(let doc):
            document = doc
            pruneAfterRemoval()
        }
        // Every mutation above has landed, so anything cached off the old document is stale. Bumped
        // here rather than before the switch because `.removeNodes` reads `shapes` while deciding
        // what it may delete, and that read must not outlive its own edit (spec §21.8).
        shapesVersion += 1

        if document.settings.assets != assetsBefore { refreshTextureBindings() }

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
        pruneCommentSelection()
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

        // The route recorded when the viewer was set, not wherever the editor has navigated since
        // (spec §20.5, ruling R13). Empty and nil for a viewer in the root.
        let viewer = viewState.viewer
        let viewerPath = viewState.viewerPath
        let viewerDefinition = viewState.viewerDefinition
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

        // The slots this program binds; a `textures` change rebinds against these without a recompile.
        textureSlots = shader.textures
        refreshTextureBindings()
        // One warning per referenced asset whose bytes the package did not carry (spec §21.2).
        // Carried onto every outcome below, since each of them replaces `diagnostics` wholesale.
        let missing = missingTextureDiagnostics(for: shader.textures)

        if let last = lastCompiled, last.source == shader.source, last.fastMath == doc.settings.fastMath {
            // Same program as the last settled compile (typically an undo of a cosmetic edit): its
            // outcome still stands. Refresh what depends on the document and skip the compiler (§19.1).
            generatedSource = shader.source
            generatedLineMap = shader.lineMap
            resolvedTypes = shader.resolved
            if last.succeeded, let p = preview.pipeline {
                diagnostics = missing
                preview.uniforms = UniformImage.rebuild(layout: p.shader.layout, document: document, registry: registry)
            }
            return
        }
        diagnostics = missing
        generatedSource = shader.source
        generatedLineMap = shader.lineMap
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
            diagnostics = (mapped.isEmpty ? [Diagnostic(.error, message)] : mapped) + missing
            lastCompiled = (shader.source, doc.settings.fastMath, false)
        case .superseded:
            break
        }
    }

    /// A warning per slot whose asset is in `missingTextures`, named from the document's manifest
    /// (spec §21.2: the manifest entry survives, the preview shows the placeholder).
    private func missingTextureDiagnostics(for slots: [TextureSlot]) -> [Diagnostic] {
        slots.compactMap { slot in
            guard let asset = slot.asset, missingTextures.contains(asset),
                  let info = document.settings.assets[asset] else { return nil }
            return Diagnostic(.warning, "Texture “\(info.name)” is missing")
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
