import Foundation
import CoreGraphics
import Metal
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
    /// Paste at the viewport's centre (spec §22.5). iPad's Edit ▸ Paste has no pointer location to
    /// land at, and only the canvas knows where its centre is; macOS keeps pasting at the pointer
    /// through `onPasteCommand`.
    case paste
    /// Open the node chooser at the viewport's centre — the toolbar's ✛ (spec §22.3).
    case openChooser
    /// Node ▸ New Custom Code Node (⌃⌘N): a Custom MSL definition and its one instance, born at
    /// the viewport's centre — only the canvas knows where that is (spec §24.3).
    case newCustomCode
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
    // `internal(set)`, not `private(set)`: the code editor's tests (Task 17) stage a diagnostic
    // state directly — `m.diagnostics = […]` — without driving a real compile, and `@testable
    // import` only reaches as far as `internal`.
    public internal(set) var diagnostics: [Diagnostic] = []
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
    /// The recording the File menu last asked for, and a counter bumped with it: the view watches
    /// the counter, so asking twice for the same kind still raises the sheet (spec §26.5).
    public internal(set) var recordingRequest: RecordingKind?
    public internal(set) var recordingRequestCount = 0
    /// The running recording, so the progress sheet's Cancel can reach it. Not observed itself;
    /// `isRecording` is the observed mirror the menus disable on (spec §27.6).
    @ObservationIgnored public var recordingTask: Task<Void, Never>? {
        didSet { isRecording = recordingTask != nil }
    }
    /// Whether a recording is in flight. `recordingTask` is `@ObservationIgnored` — a command tree
    /// re-evaluates on observed reads only, so the menu items need this flag to go grey.
    public private(set) var isRecording = false

    // `internal`, not `private`: `EditorModel+Recording.record(...)` compiles the document's own
    // program for a recording and lives in another file.
    let compiler: any ShaderCompiling
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var compileTask: Task<Void, Never>?
    /// The last **non-superseded** compile's outcome, keyed on the program it settled: reused to
    /// skip the compiler when the generated source and fast-math flag come back unchanged (spec §19.1).
    /// The last settled compile, with the slot list its pipeline was built from: two documents can
    /// generate the same source and differ only in which asset a `tex<i>` slot names (a Texture
    /// Sample that has just been given an image), and that difference lives in the pipeline, not
    /// the text.
    /// `errors` is what that compile put in `diagnostics` on its own account — the mapped compile
    /// lines, empty on success. Kept so the shortcut below can rebuild `diagnostics` from them plus
    /// the *current* missing-texture warnings, rather than leaving a stale one standing (spec §27.8).
    private var lastCompiled: (source: String, textures: [TextureSlot], fastMath: Bool,
                               succeeded: Bool, errors: [Diagnostic])?
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
    /// The slots of the live pipeline. Read by the tests and by the missing-texture diagnostics.
    var textureSlots: [TextureSlot] { preview.program?.pipeline.shader.textures ?? [] }

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
        self.preview.mesh = viewState.previewMesh
        self.preview.orbit = viewState.orbit
        self.syncClock()
    }

    /// The 3D preview's mesh and camera (spec §23.5, §23.8). View state, never undone; mirrored
    /// into `preview` so the renderer's next frame picks it up.
    public func setPreviewMesh(_ mesh: PreviewMesh) {
        viewState.previewMesh = mesh
        preview.mesh = mesh
    }

    public func setOrbit(_ orbit: OrbitCamera) {
        viewState.orbit = orbit
        preview.orbit = orbit
    }

    /// Scroll or pinch dollies the 3D preview's camera (spec §23.5). Gated on the target the way
    /// the orbit drag is — under the 2D targets a scroll over the preview means nothing — and
    /// routed through `setOrbit`, so it is view state like the orbit: persisted, never undone.
    ///
    /// A positive `delta` pulls the camera in, matching the canvas, where a positive scroll delta
    /// zooms in. `OrbitCamera.dolly` owns the scale and the bounds.
    public func dollyPreview(by delta: Float) {
        guard document.settings.target == .realityKit, delta.isFinite else { return }
        var camera = viewState.orbit
        camera.dolly(delta)
        setOrbit(camera)
    }

    /// The pinch form. A magnification gesture reports a cumulative *factor*, so callers pass the
    /// step since the last event — `> 1` pulls in — and this converts it to the linear delta
    /// `dolly` takes, exactly: the distance ends up divided by `ratio`, still clamped by `dolly`.
    public func magnifyPreview(by ratio: Float) {
        guard ratio > 0, ratio.isFinite else { return }
        let d = viewState.orbit.distance
        dollyPreview(by: (d - d / ratio) / OrbitCamera.dollyScale)
    }

    /// Replaces everything the package owns because the file changed underneath the editor —
    /// File ▸ Revert To Saved, or any other reseed by the document host (spec §21.1).
    ///
    /// Deliberately not an edit: nothing on the undo stack applies to the document that just
    /// arrived, so the stack is dropped rather than extended. Going through `apply(.restore(_:))`
    /// instead would register the revert as an undoable step, which would let ⌘Z resurrect the
    /// content the user just discarded.
    public func reload(package: ShaderPackage) {
        // A recording belongs to the document it was started from (spec §27.6): a File ▸ Revert To
        // Saved landing mid-recording would otherwise finish rendering the pre-revert program and
        // then raise a save panel for it.
        recordingTask?.cancel()
        recordingTask = nil
        // A gesture that was open belongs to the document being replaced; its snapshot must not
        // survive to be committed against the new one.
        transactionSnapshot = nil
        transactionDepth = 0

        document = package.document
        viewState = package.viewState
        preview.mesh = viewState.previewMesh
        preview.orbit = viewState.orbit
        syncClock()
        resetPlayback()
        // The GPU cache is keyed by `AssetID` alone, and a reseed can bring different bytes under an
        // id it already holds (relink an asset, then revert): drop it all before the new bytes land,
        // so the rebind `textures` triggers decodes them afresh.
        textureStore?.evictAll()
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
    ///
    /// Whatever the window's manager already holds is dropped: the model's history is empty at this
    /// point, and the only thing that can be there is `DocumentGroup`'s own registration for a
    /// `FileDocument` write that landed before the host could switch registration off — a view-state
    /// mirror, which is never an undo step (spec §18.3).
    public func adoptUndoManager(_ manager: UndoManager) {
        guard manager !== undoManager, !undoManager.canUndo, !undoManager.canRedo else { return }
        manager.removeAllActions()
        undoManager = manager
        undoStackVersion += 1
    }

    /// Publishes `pipeline` together with the bindings its slots need — one write, so the renderer
    /// never draws a pipeline against another program's textures (spec §22.6).
    private func publish(_ pipeline: CompiledPipeline) {
        preview.program = PreviewProgram(pipeline: pipeline, textures: bindings(for: pipeline))
    }

    /// Rebuilds the live program's bindings — called whenever the bytes or the manifest change
    /// (spec §21.2). Keys off the pipeline that is drawing: a compile failure leaves the last-good
    /// pipeline live, and binding a *new* program's slots could leave one of its `tex<i>` unbound.
    func refreshTextureBindings() {
        guard let pipeline = preview.program?.pipeline else { return }
        preview.program = PreviewProgram(pipeline: pipeline, textures: bindings(for: pipeline))
    }

    /// `internal` for `EditorModel+Recording`, which binds the one-off pipeline it compiles for a
    /// recording the same way the live one is bound.
    func bindings(for pipeline: CompiledPipeline) -> [Int: MTLTexture] {
        textureStore?.bindings(for: pipeline.shader.textures, textures: textures) ?? [:]
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
    /// resolving one walks the document: the cache stands until a change that can alter a shape
    /// bumps `shapesVersion` (spec §27.9) or the editor moves to another graph (the path). Reading `activePath` is also what registers
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
    /// Bumped only for a change whose `changesShapes` is true — topology, `.setTitle`, a definition
    /// accent, a non-uniformable `.setParam`, `.restore` (spec §27.9) — which is what makes the
    /// cache stale; a node drag or a uniformable value leaves it standing. Not observed:
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
        // HARD REQUIREMENT (Task 16): a `.msl` definition's "canvas" is empty by construction
        // (`GroupDefinition.graph`'s getter) and its setter silently drops any write back into it
        // — deliberately, so a gesture can never clobber the user's code. That alone absorbs most
        // canvas edits into no-ops, but `.insert` also carries `definitions`/`assets` that land
        // regardless of the active graph's body, so a change reaching the active graph while it is
        // a `.msl` definition is refused outright here rather than leaning on that drop. Gated on
        // `isEditingCode`, not on the canvas view existing, so this holds even before Task 17's
        // code editor replaces it.
        if isEditingCode && change.touchesActiveGraph { return }
        // The mirror of Task 5's "a `.msl` body cannot become `.graph`": a `.graph` definition has
        // no body text to replace, and `perform` writes `.msl(text)` unconditionally — applied to
        // a graph id it would overwrite the whole canvas with a string. No caller does that today
        // (`CodeEditorView` mounts only for `.msl`), so this is refused here, before an undo step
        // or a recompile is spent on it, rather than trusted to stay unreachable.
        if case .setDefinitionBody(let id, _) = change, !isCustomCodeDefinition(id) {
            showNotice("Only a Custom MSL definition has code to edit")
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
        // Spec §27.2: a NaN or infinite component is stored as 0. `.setParam` is the one funnel
        // every editable value goes through, and a `TextField(value: .number)` parses "nan" quite
        // happily — left in place it makes the document unsaveable (the JSON encoder cannot write
        // one) and bakes as MSL that does not compile. Normalised here, before the graph write and
        // before the uniform patch at the bottom, so both see the same value.
        var change = change
        if case .setParam(let id, let key, let value) = change { change = .setParam(id, key, value.finite) }
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
            // A param can change a node's shape (the Expression node's formula does, spec §24.2).
            // An edge into a socket the new shape does not declare would be unreachable and
            // uninspectable — prune it here, inside the same change, so undo restores both.
            if !value.isUniformable, let n = document[path].nodes[id],
               let newShape = document.shape(of: n, in: path, registry: registry) {
                let live = Set(newShape.inputs.map(\.name))
                document[path].inputs = document[path].inputs.filter {
                    $0.key.node != id || live.contains($0.key.socket)
                }
                // A live parameter naming a socket the new shape dropped (`uv.x * k` edited to
                // `uv.x`, with `k` live) is the same dangling reference as that edge: the read
                // silently vanishes from the export while the path still holds one of four slots.
                pruneLiveParameters()
            }
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
            if let renamed = GroupOperations.renameSocket(id, kind: kind, from: old, to: new, in: document) {
                // `GroupOperations.renameSocket` carries each instance's param value across to the
                // new name; a live mark on that input follows it too, so the user's intent
                // survives a rename rather than being pruned as a socket that no longer exists.
                //
                // The name it follows to is read back from the renamed definition, never `new`:
                // `renameSocket` sanitises the text it is handed (`StitchableCodegen.sanitizedName`
                // — "my gain" is written as `my_gain`) and the inspector passes the raw text in, so
                // a path rewritten to `new` would name a socket that does not exist and be pruned
                // on the very next line — the silent unmark this follow exists to prevent. The
                // written name is the one input name the definition has now and did not have
                // before; a no-op rename (sanitised `new` equals `old`) yields none, and nothing
                // needs to move.
                let before = Set(document.definitions[id]?.inputs.map(\.name) ?? [])
                let written = renamed.definitions[id]?.inputs.map(\.name).first { !before.contains($0) }
                document = renamed
                if kind == .input, let written {
                    let doc = document
                    document.settings.liveParameters = document.settings.liveParameters.map { p in
                        guard p.param == old, let node = p.instancePath.first,
                              doc.node(node)?.node.kind == .group(id) else { return p }
                        return ParamPath(instancePath: p.instancePath, param: written)
                    }
                }
            }
            pruneAfterRemoval()                      // the viewed socket may have been the renamed one
        case .removeSocket(let id, let kind, let name):
            document = GroupOperations.removeSocket(id, kind: kind, name: name, in: document) ?? document
            pruneAfterRemoval()
        case .deleteDefinition(let id):
            document = GroupOperations.deleteDefinition(id, in: document) ?? document
            pruneAfterRemoval()
        case .setDefinitionBody(let id, let text):
            document.definitions[id]?.body = .msl(text)
        case .addDefinition(let def):
            document.definitions[def.id] = def
        case .setSettings(let s):
            // Spec §18.2: settings are cosmetic unless `fastMath` or `target` flips — both are
            // part of what gets compiled, so they need a rebuild; preview size and time mode do not.
            // Under a stitchable target `exportName` also names the generated function, so a rename
            // changes the source too (spec §19.4). The lighting model selects which setters the
            // material emits and whether the preview carries the GGX helpers at all (spec §23.8),
            // so it changes the source under the RealityKit target. `liveParameters` changes what
            // the *export* spells for a baked field (spec §24.6) — the preview never reads it
            // (`EmitEnvironment.bakedUniforms` is export-only) — but `generatedSource`/`exportSource`
            // are produced by the same compile pass, so a change here still needs one.
            recompile = s.fastMath != document.settings.fastMath
                || s.target != document.settings.target
                || (s.target.stitchableKind != nil && s.exportName != document.settings.exportName)
                || (s.target == .realityKit && s.lightingModel != document.settings.lightingModel)
                || (s.target == .realityKit && s.liveParameters != document.settings.liveParameters)
            // The timeline and the time mode are document state; the clock that plays them is
            // view state, so it has to be told (spec §26.3) — but only when one of them actually
            // moved (spec §27.5). `.setSettings` is also the vehicle for an image import, an asset
            // relink, the export-name commit and every toggle in the inspector, and `syncClock`
            // re-bases the wall-clock bookkeeping: doing that for an unrelated write drops
            // sub-frame phase mid-playback and snaps a past-the-end readout back to the duration.
            let clockMoved = s.timeline != document.settings.timeline || s.timeMode != document.settings.timeMode
            document.settings = s
            if clockMoved { syncClock() }
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
            // Undo/redo restores the settings along with everything else, so the timeline and the
            // time mode can both have moved under the clock (spec §26.3) — and just as often have
            // not, since every undoable edit comes back through here (spec §27.5).
            let clockMoved = doc.settings.timeline != document.settings.timeline
                || doc.settings.timeMode != document.settings.timeMode
            document = doc
            pruneAfterRemoval()
            if clockMoved { syncClock() }
        }
        // Anything cached off the old document is stale — but only for a change that can actually
        // reshape a node (spec §27.9): a drag applies `.moveNodes` per mouse event, and rebuilding
        // every `NodeShape` of the active graph per frame re-tokenises every Expression formula.
        // Bumped here rather than before the switch because `.removeNodes` reads `shapes` while
        // deciding what it may delete, and that read must not outlive its own edit (spec §21.8).
        if change.changesShapes { shapesVersion += 1 }

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
        pruneLiveParameters()
    }

    /// A live parameter names a node by id (spec §24.6). Once that node is gone — deleted outright,
    /// or carried off with a whole definition — pruning it is hygiene rather than a correctness
    /// fix: a dangling path requests no uniform slot (`bakedUniforms` only substitutes for a path
    /// with a matching `UniformLayout` field, and nothing asks for one on behalf of a node that no
    /// longer exists), so the export was never going to read a value nothing writes. Left unpruned
    /// it is just stale data — a setting pointing at nothing, documented and seeded by nothing
    /// (`MaterialExport.liveParameters(for:document:)` filters it out the same way) — the same
    /// reason `pruneSelection`/`pruneViewer` drop their own dangling references rather than let a
    /// gone id linger in view state or settings.
    ///
    /// Called from every case that can remove a node, the same way `pruneViewer`/`pruneSelection`
    /// are: unlike those, this is document data rather than view state, so it does not go through
    /// `.setSettings` and carries no separate undo step of its own — it lands in the same undo
    /// group as whatever removal triggered it. `reload(package:)` is the one caller where that
    /// matters: it replaces `document` wholesale and clears the undo stack in the same call, so a
    /// reverted-to file that happens to carry a dangling live parameter (hand-edited, or written by
    /// a build with a bug of its own) is silently cleaned up with nothing to undo — the in-memory
    /// document quietly diverges from the bytes just read until the next save overwrites them.
    ///
    /// The *param* half of the path can dangle too, with the node still present: an Expression's
    /// sockets are its formula's free identifiers, so editing `uv.x * k` to `uv.x` drops `k` from
    /// the node's shape (`.setParam`), and removing a definition's input drops it from every
    /// instance (`.removeSocket`). Either way the export stops reading the path — `bakedUniforms`
    /// substitutes only for a field the layout actually requests — while the setting still holds
    /// one of the four slots and documents nothing. So a path is also pruned when its node's
    /// *current* shape declares neither a param nor an input of that name. A node whose shape
    /// cannot be resolved at all (an unknown builtin, a missing definition) keeps its path: that
    /// is a validation error the user sees, not a silent reshape.
    private func pruneLiveParameters() {
        // `doc` is a snapshot read before the mutation below, not `document` itself: the removal
        // closure's own lookups must not reach back through `self.document` while
        // `document.settings.liveParameters` is under exclusive access for the `removeAll`, or the
        // runtime traps on the overlapping access.
        let doc = document
        let registry = registry
        document.settings.liveParameters.removeAll { path in
            guard let id = path.instancePath.first, let (inst, gpath) = doc.node(id) else { return true }
            guard let shape = doc.shape(of: inst, in: gpath, registry: registry) else { return false }
            return shape.param(named: path.param) == nil && shape.input(named: path.param) == nil
        }
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

        // One warning per referenced asset whose bytes the package did not carry (spec §21.2).
        // Carried onto every outcome below, since each of them replaces `diagnostics` wholesale.
        let missing = missingTextureDiagnostics(for: shader.textures)

        if let last = lastCompiled, last.source == shader.source, last.textures == shader.textures,
           last.fastMath == doc.settings.fastMath {
            // Same program as the last settled compile (typically an undo of a cosmetic edit): its
            // outcome still stands. Refresh what depends on the document and skip the compiler (§19.1).
            generatedSource = shader.source
            generatedLineMap = shader.lineMap
            resolvedTypes = shader.resolved
            // Unconditional: the warnings are about the bytes on hand *now*, so a relinked texture
            // has to lose its warning even when that settled compile failed (spec §27.8).
            diagnostics = last.errors + missing
            if last.succeeded, let p = preview.pipeline {
                preview.uniforms = UniformImage.rebuild(layout: p.shader.layout, document: document, registry: registry)
                refreshTextureBindings()
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
            publish(pipeline)
            preview.uniforms = UniformImage.rebuild(layout: pipeline.shader.layout, document: document, registry: registry)
            preview.lastError = nil
            lastCompiled = (shader.source, shader.textures, doc.settings.fastMath, true, [])
        case .failure(let message, let lines, let g):
            guard g == generation else { return }
            preview.lastError = message
            var mapped: [Diagnostic] = []
            for l in lines {
                let sev: Diagnostic.Severity = l.severity == .error ? .error : .warning
                var d = Diagnostic(sev, l.message, node: shader.lineMap.node(forLine: l.line))
                d.userLine = shader.lineMap.userLine(forLine: l.line)
                d.definition = shader.lineMap.definition(forLine: l.line)
                mapped.append(d)
            }
            let errors = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
            diagnostics = errors + missing
            lastCompiled = (shader.source, shader.textures, doc.settings.fastMath, false, errors)
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

    /// Diagnostics to show against one node, optionally narrowed to one socket or param.
    /// `Diagnostic.socket` is a plain `String?` (`Diagnostic.swift:8`) — there is no `SocketID`
    /// type. Passing `nil` returns every diagnostic on the node, socket-scoped ones included.
    public func diagnostics(for node: NodeID, socket: String? = nil) -> [Diagnostic] {
        diagnostics.filter { $0.node == node && (socket == nil || $0.socket == socket) }
    }

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

    // MARK: The code editor (spec §24.3, §24.4, Task 17)

    /// A `.msl` definition's body text, verbatim — never hardened or rewritten (Global
    /// Constraints). Empty for a `.graph` definition or an unknown id.
    public func codeBody(for id: GroupID) -> String {
        if case .msl(let s)? = document.definitions[id]?.body { return s }
        return ""
    }

    /// The error list under the code editor. `userLine` is 1-based in the user's own text; a
    /// diagnostic without one came from generated scaffolding and sorts to the top as line 0.
    /// A diagnostic naming *another* definition is not this editor's problem and is dropped;
    /// one naming no definition at all is kept, because a body that fails to compile often
    /// reports against the function's signature line rather than inside the spliced text.
    public func codeDiagnostics(for id: GroupID)
        -> [(line: Int, message: String, severity: Diagnostic.Severity)] {
        diagnostics
            .filter { $0.definition == nil || $0.definition == id }
            .map { (line: $0.userLine ?? 0, message: $0.message, severity: $0.severity) }
            .sorted { $0.line < $1.line }
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
