import SwiftUI
import MetalNodesCore

/// Right sidebar (spec §18.8). Reuses `ParamControl`; the node body keeps its compact controls.
public struct InspectorView: View {
    let model: EditorModel
    let services: EditorServices
    @State private var titleDraft = ""
    @State private var widthDraft = ""
    @State private var heightDraft = ""
    @State private var exportNameDraft = ""
    @FocusState private var exportNameFocused: Bool

    public init(model: EditorModel, services: EditorServices = .platform) {
        self.model = model
        self.services = services
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Comments and no node: the one comment's own pane, or a count (spec §21.4).
                if model.selection.isEmpty, !model.selectedComments.isEmpty {
                    if model.selectedComments.count == 1 {
                        CommentPane(model: model, id: model.selectedComments.first!)
                    } else {
                        Text("\(model.selectedComments.count) comments selected")
                            .font(.callout).foregroundStyle(DraculaToken.muted.color)
                    }
                } else {
                    switch model.selection.count {
                    case 0: emptySelectionPane
                    case 1: nodePane(model.selection.first!)
                    default: Text("\(model.selection.count) nodes selected").font(.callout).foregroundStyle(DraculaToken.muted.color)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DraculaToken.background.color)
    }

    /// Nothing selected: the document's settings at the root, the definition's own pane inside one
    /// (spec §20.8).
    @ViewBuilder
    private var emptySelectionPane: some View {
        if case .definition(let gid) = model.activePath {
            DefinitionPane(model: model, id: gid)
        } else {
            documentSettings
        }
    }

    // MARK: Node

    @ViewBuilder
    private func nodePane(_ id: NodeID) -> some View {
        if let node = model.graph.nodes[id], let shape = model.shape(of: node) {
            if case .group = node.kind {
                InstancePane(model: model, id: id)
            } else if shape.isPseudo, case .definition(let gid) = model.activePath {
                // A pseudo-node *is* the definition's socket list (spec §20.2).
                DefinitionPane(model: model, id: gid)
            } else {
                builtinPane(id, node, shape)
            }
        } else {
            Text("Unknown node").foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func builtinPane(_ id: NodeID, _ node: NodeInstance, _ shape: NodeShape) -> some View {
        let resolved = model.resolvedTypes[id]
        HStack {
            Text(node.customTitle ?? shape.title).font(.headline)
            Spacer()
            Text(shape.category.displayName).font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(DraculaTheme.token(for: shape.category).color.opacity(0.25))
                .clipShape(Capsule())
        }
        if case .builtin(let defID) = node.kind {
            Text(defID).font(.caption.monospaced()).foregroundStyle(DraculaToken.muted.color)
        }

        TextField("Title", text: $titleDraft, prompt: Text(shape.title))
            .textFieldStyle(.roundedBorder)
            .onAppear { titleDraft = node.customTitle ?? "" }
            .onChange(of: id) { _, _ in titleDraft = node.customTitle ?? "" }
            .onChange(of: node.customTitle) { _, t in titleDraft = t ?? "" }
            .onSubmit { model.apply(.setTitle(id, titleDraft)) }

        Divider()

        ForEach(shape.inputs, id: \.name) { decl in
            let ref = SocketRef(id, decl.name)
            if let src = model.graph.source(feeding: ref) {
                HStack {
                    Text(decl.label).font(.caption)
                    Spacer()
                    Text("← \(model.socketLabel(src))").font(.caption).foregroundStyle(DraculaToken.muted.color)
                }
            } else if case .value(let dflt) = decl.default {
                let resolvedType = resolved?.inputTypes[decl.name]
                let type = resolvedType ?? (decl.type.concreteOrFloat)
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: node.params[decl.name] ?? dflt,
                             onChange: { model.apply(.setParam(id, decl.name, $0)) },
                             onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
                if model.document.settings.target == .realityKit, EditorModel.isLiveable(decl, resolvedType: resolvedType) {
                    let path = ParamPath(node: id, param: decl.name)
                    let index = model.liveParameterIndex(of: path)
                    liveToggle(index: index) { model.toggleLiveParameter(path) }
                }
            }
        }
        ForEach(shape.params, id: \.name) { p in
            let value = node.params[p.name] ?? p.defaultValue
            ParamControl(label: p.label, kind: p.kind, value: value,
                         onChange: { model.apply(.setParam(id, p.name, $0)) },
                         onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() },
                         image: model.assetThumbnail(for: value),
                         onChooseImage: { source in chooseImage(id, p.name, source) })
            if model.document.settings.target == .realityKit, EditorModel.isLiveable(p) {
                let path = ParamPath(node: id, param: p.name)
                let index = model.liveParameterIndex(of: path)
                liveToggle(index: index) { model.toggleLiveParameter(path) }
            }
            // `id: \.offset`, not `\.self`: two distinct errors on the same formula (`return a;
            // return b;`) can be byte-identical `Diagnostic` values — same severity, message,
            // node, socket, userLine — and `Diagnostic` being `Hashable` is exactly what makes
            // that collision possible. `id: \.self` would fold both into one SwiftUI row, so the
            // user would see one error where the compiler reported two (Task 15 fix round 1).
            ForEach(Array(model.diagnostics(for: id, socket: p.name).enumerated()), id: \.offset) { _, d in
                Label(d.message, systemImage: d.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(d.severity == .error ? DraculaToken.red.color : DraculaToken.yellow.color)
                    .textSelection(.enabled)
            }
        }

        // A pseudo-node's "outputs" are the definition's inputs and carry no ◉ (spec §20.8).
        if !shape.outputs.isEmpty && !shape.isPseudo {
            Divider()
            ForEach(shape.outputs, id: \.name) { decl in
                let ref = SocketRef(id, decl.name)
                let viewed = model.viewer == ref
                HStack {
                    Text(decl.label).font(.caption)
                    Text((resolved?.outputTypes[decl.name] ?? decl.type.concreteOrFloat).rawValue)
                        .font(.caption2.monospaced()).foregroundStyle(DraculaToken.muted.color)
                    Spacer()
                    Button { model.toggleViewer(ref) } label: {
                        Image(systemName: viewed ? "circle.circle.fill" : "circle.circle")
                            .foregroundStyle(viewed ? DraculaTheme.viewerFlag.color : DraculaToken.muted.color)
                    }
                    .buttonStyle(.plain)
                    .help(viewed ? "Clear viewer" : "View \(decl.label)")
                }
            }
        }

        let diags = model.diagnostics.filter { $0.node == id }
        if !diags.isEmpty {
            Divider()
            ForEach(Array(diags.enumerated()), id: \.offset) { _, d in
                Text(d.message).font(.caption)
                    .foregroundStyle(d.severity == .error ? DraculaTheme.error.color : DraculaToken.orange.color)
            }
        }
    }

    /// The "Live" checkbox beside a markable param: on while its path holds a slot in
    /// `settings.liveParameters`, labelled with the `custom_parameter()` component it lands in
    /// (spec §24.6) so `custom_parameter().z` is traceable back to this row without reading the
    /// export. `EditorModel.liveParameterComponent` is bounds-checked (a hand-edited or migrated
    /// document can carry more than four live paths — `MaterialValidation`'s rule 6 is what refuses
    /// it, not the decoder), so a path beyond the fourth is still toggleable here — the checkbox
    /// just carries no component label for one that has none.
    @ViewBuilder
    private func liveToggle(index: Int?, toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { index != nil }, set: { _ in toggle() })) {
            HStack(spacing: 4) {
                Text("Live")
                if let i = index, let component = EditorModel.liveParameterComponent(i) {
                    Text("custom_parameter().\(component)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DraculaToken.muted.color)
                }
            }
        }
        .font(.caption)
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
    }

    /// The image well's chooser: the model owns the "Choose Image" transaction (spec §21.2, §22.4),
    /// so both platforms and both sources go through one function.
    private func chooseImage(_ node: NodeID, _ param: ParamID, _ source: ImageSource) {
        Task { await model.chooseImage(for: node, param: param, from: source, using: services.imageChooser) }
    }

    // MARK: Document

    private var documentSettings: some View {
        let s = model.document.settings
        return VStack(alignment: .leading, spacing: 10) {
            Text("Document").font(.headline)
            HStack {
                Text("Preview size").font(.caption)
                TextField("W", text: $widthDraft)
                    .frame(width: 60)
                    .onAppear { widthDraft = "\(clampedDimension(s.previewSize.width))" }
                    .onChange(of: model.document.settings.previewSize) { _, size in widthDraft = "\(clampedDimension(size.width))" }
                    .onSubmit { commitPreviewSize() }
                Text("×")
                TextField("H", text: $heightDraft)
                    .frame(width: 60)
                    .onAppear { heightDraft = "\(clampedDimension(s.previewSize.height))" }
                    .onChange(of: model.document.settings.previewSize) { _, size in heightDraft = "\(clampedDimension(size.height))" }
                    .onSubmit { commitPreviewSize() }
            }
            Picker("Time", selection: Binding(get: { s.timeMode }, set: { m in var n = s; n.timeMode = m; model.apply(.setSettings(n)) })) {
                Text("Wall clock").tag(TimeMode.wallClock)
                Text("Fixed rate").tag(TimeMode.fixedRate)
            }
            .pickerStyle(.segmented)
            Toggle("Fast math", isOn: Binding(get: { s.fastMath }, set: { f in var n = s; n.fastMath = f; model.apply(.setSettings(n)) }))
                .toggleStyle(.switch)
            Text("Fast math relaxes NaN/Inf handling for speed. Off keeps IEEE semantics; changing it recompiles.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            Divider()
            Text("Output").font(.headline)
            Picker("Target", selection: Binding(get: { s.target }, set: { t in var n = s; n.target = t; model.apply(.setSettings(n)) })) {
                ForEach(OutputTarget.all, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if s.target == .realityKit {
                Picker("Lighting", selection: Binding(get: { s.lightingModel },
                                                      set: { m in var n = s; n.lightingModel = m; model.apply(.setSettings(n)) })) {
                    ForEach(MaterialLightingModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Mesh", selection: Binding(get: { model.viewState.previewMesh },
                                                  set: { model.setPreviewMesh($0) })) {
                    ForEach(PreviewMesh.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Text("The preview approximates RealityKit's lit model with Cook-Torrance GGX. It shows the material's shape, not RealityKit's exact output.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
                if s.lightingModel == .clearcoat {
                    Text("The preview approximates the coat with a second specular lobe — the roughest part of this approximation. The export uses RealityKit's real clearcoat lobe instead.")
                        .font(.caption2).foregroundStyle(DraculaToken.muted.color)
                }
                liveParametersSection
            }
            HStack {
                Text("Export name").font(.caption)
                TextField("metalNodesShader", text: $exportNameDraft)
                    .focused($exportNameFocused)
                    .onAppear { exportNameDraft = s.exportName }
                    .onChange(of: model.document.settings.exportName) { _, n in exportNameDraft = n }
                    .onChange(of: exportNameFocused) { _, focused in if !focused { commitExportName() } }
                    .onSubmit { commitExportName() }
            }
            HStack {
                // Both actions read `settings.exportName`, so an uncommitted edit must land first.
                Button("Copy Swift snippet") { commitExportName(); _ = model.copySwiftSnippet() }
                    .disabled(s.target.stitchableKind == nil && s.target != .realityKit)
                Button("Export…") { commitExportName(); model.requestExport() }
            }
            .controlSize(.small)
            if s.target == .realityKit {
                Text("Export writes the .metal file with both [[visible]] functions and a .swift snippet that builds the CustomMaterial. Parameter values are baked in; re-export after changing one.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            } else if s.target.stitchableKind != nil {
                Text("Preview renders the same function through a fragment wrapper. Export writes the .metal file and a .swift extension with the ShaderLibrary call in argument order.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            } else {
                Text("Export writes the .metal file with a header documenting the uniform layout and texture slots.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
            Divider()
            assetsList
        }
        .textFieldStyle(.roundedBorder)
    }

    /// The four (or fewer) parameters marked live, in `custom_parameter()` order — the only place
    /// all of them are visible together, and what makes `custom_parameter().z` in the export
    /// traceable back to a node without reading the generated Swift (spec §24.6).
    ///
    /// `id: \.offset`, not `\.element` (a `ParamPath`): a hand-edited or migrated document can carry
    /// the same path twice (`MaterialValidation`'s rule 6 refuses it as a diagnostic, not as a
    /// decoding failure), and two rows sharing an id would fold together — worse, "Unmark" on either
    /// would only remove the *first* occurrence (`toggleLiveParameter` finds by `firstIndex(of:)`),
    /// silently leaving the second live and the row still showing.
    ///
    /// A path past the fourth renders no row at all here (`EditorModel.liveParameterComponent`
    /// returns `nil` for it) — it is still visible and still unmarkable from the toggle beside its
    /// own control in the node's own pane, which shows "Live" with no component label for exactly
    /// this case.
    @ViewBuilder
    private var liveParametersSection: some View {
        let live = model.document.settings.liveParameters
        if !live.isEmpty {
            Divider()
            Text("Live parameters").font(.caption).bold()
            ForEach(Array(live.enumerated()), id: \.offset) { index, path in
                if let component = EditorModel.liveParameterComponent(index) {
                    HStack {
                        Text("custom_parameter().\(component)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DraculaToken.muted.color)
                        Text(liveParameterLabel(path)).font(.caption)
                        Spacer()
                        Button("Unmark") { model.toggleLiveParameter(path) }
                            .buttonStyle(.plain).font(.caption2)
                    }
                    if !EditorModel.isLiveParameterReachable(path, in: model.preview.pipeline?.shader.layout) {
                        Text("Doesn't reach the Material Output — the export won't read this slot.")
                            .font(.caption2).foregroundStyle(DraculaToken.orange.color)
                    }
                }
            }
        }
    }

    /// "Title.param" for a live parameter's path — the node's custom title if it has one, else its
    /// shape's title, the same fallback `socketLabel(_:)` uses for a source ref. A path whose node
    /// is gone can't reach here: `EditorModel.pruneLiveParameters` drops it the moment the node does.
    private func liveParameterLabel(_ path: ParamPath) -> String {
        guard let nodeID = path.instancePath.first, let (inst, _) = model.document.node(nodeID) else {
            return path.param
        }
        let title = inst.customTitle ?? model.shape(of: nodeID)?.title ?? "?"
        let paramLabel = model.shape(of: nodeID)?.params.first { $0.name == path.param }?.label ?? path.param
        return "\(title).\(paramLabel)"
    }

    /// Every imported image the package carries (spec §21.1): removable only while nothing points
    /// at it, relinkable while its bytes are the ones the package did not have.
    @ViewBuilder
    private var assetsList: some View {
        Text("Assets").font(.headline)
        if model.assetList.isEmpty {
            Text("Drop an image on the canvas, or choose one from a Texture Sample.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
        } else {
            ForEach(model.assetList) { entry in
                let missing = model.missingTextures.contains(entry.id)
                HStack(alignment: .center) {
                    // The same cached thumbnail the image well draws — no decode per body pass.
                    if let image = model.thumbnail(for: entry.id) {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.info.name).font(.caption)
                        Text(missing ? "missing" : "\(Int(entry.info.pixelSize.width)) × \(Int(entry.info.pixelSize.height))")
                            .font(.caption2)
                            // Orange, not red: a missing texture is a warning — the preview still
                            // renders, on the placeholder (spec §21.2).
                            .foregroundStyle(missing ? DraculaToken.orange.color : DraculaToken.muted.color)
                    }
                    Spacer()
                    if missing {
                        #if os(macOS)
                        Button("Relink…") { relink(entry.id, .files) }
                        #else
                        Menu("Relink…") {
                            Button("Photos…") { relink(entry.id, .photos) }
                            Button("Files…") { relink(entry.id, .files) }
                        }
                        .fixedSize()
                        #endif
                    }
                    Button("Remove") { model.removeAsset(entry.id) }
                        .disabled(model.isAssetReferenced(entry.id))
                }
                .controlSize(.small)
            }
        }
    }

    /// Re-imports a missing texture's bytes under its own id, so the warning clears and every node
    /// pointing at it keeps pointing at it.
    private func relink(_ asset: AssetID, _ source: ImageSource) {
        Task { await model.relinkAsset(asset, from: source, using: services.imageChooser) }
    }

    private func clampedDimension(_ v: CGFloat) -> Int {
        v.isFinite ? Int(min(max(v, 16), 8192)) : 512
    }

    /// Sanitises the draft and applies it. A no-op when it already matches, so it is safe to call
    /// from the buttons, from `onSubmit`, and on focus loss.
    private func commitExportName() {
        let name = StitchableCodegen.sanitizedName(exportNameDraft)
        exportNameDraft = name
        let s = model.document.settings
        guard name != s.exportName else { return }
        var n = s
        n.exportName = name
        model.apply(.setSettings(n))
    }

    private func commitPreviewSize() {
        let s = model.document.settings
        guard let w = Int(widthDraft), let h = Int(heightDraft) else {
            widthDraft = "\(clampedDimension(s.previewSize.width))"
            heightDraft = "\(clampedDimension(s.previewSize.height))"
            return
        }
        let cw = min(max(w, 16), 8192)
        let ch = min(max(h, 16), 8192)
        widthDraft = "\(cw)"
        heightDraft = "\(ch)"
        guard CGFloat(cw) != s.previewSize.width || CGFloat(ch) != s.previewSize.height else { return }
        var n = s
        n.previewSize = CGSize(width: CGFloat(cw), height: CGFloat(ch))
        model.apply(.setSettings(n))
    }
}

extension TypeRef {
    /// What the inspector labels a socket with before type resolution has an answer.
    var concreteOrFloat: SocketType {
        if case .concrete(let c) = self { return c } else { return .float }
    }
}
