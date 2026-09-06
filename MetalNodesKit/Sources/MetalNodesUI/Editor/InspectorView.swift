import SwiftUI
import MetalNodesCore

/// Right sidebar (spec §18.8). Reuses `ParamControl`; the node body keeps its compact controls.
public struct InspectorView: View {
    let model: EditorModel
    @State private var titleDraft = ""
    @State private var widthDraft = ""
    @State private var heightDraft = ""
    @State private var exportNameDraft = ""
    @FocusState private var exportNameFocused: Bool

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // One comment and no node: the comment's own pane (spec §21.4).
                if model.selection.isEmpty, model.selectedComments.count == 1 {
                    CommentPane(model: model, id: model.selectedComments.first!)
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
                let type = resolved?.inputTypes[decl.name] ?? (decl.type.concreteOrFloat)
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: node.params[decl.name] ?? dflt,
                             onChange: { model.apply(.setParam(id, decl.name, $0)) },
                             onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
            }
        }
        ForEach(shape.params, id: \.name) { p in
            let value = node.params[p.name] ?? p.defaultValue
            ParamControl(label: p.label, kind: p.kind, value: value,
                         onChange: { model.apply(.setParam(id, p.name, $0)) },
                         onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() },
                         image: model.assetThumbnail(for: value),
                         onChooseImage: chooseImageAction(for: id, param: p.name))
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

    /// The image well's "Choose…": one undo step ("Choose Image") for the import and the assignment
    /// together (spec §21.2). Nil where there is no open panel, which hides the button.
    private func chooseImageAction(for node: NodeID, param: ParamID) -> (() -> Void)? {
        #if os(macOS)
        return {
            guard let picked = ImagePanelMac.chooseImage() else { return }
            model.beginTransaction("Choose Image")
            if let asset = model.importImage(data: picked.data, name: picked.name) {
                model.apply(.setParam(node, param, .asset(asset)))
            }
            model.endTransaction()
        }
        #else
        return nil
        #endif
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
                    .disabled(s.target.stitchableKind == nil)
                #if os(macOS)
                Button("Export…") { commitExportName(); model.requestExport() }
                #endif
            }
            .controlSize(.small)
            if s.target.stitchableKind != nil {
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
                    if missing, let relink = relinkAction(for: entry.id) {
                        Button("Relink…", action: relink)
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
    private func relinkAction(for asset: AssetID) -> (() -> Void)? {
        #if os(macOS)
        return {
            guard let picked = ImagePanelMac.chooseImage() else { return }
            model.replaceAssetBytes(asset, data: picked.data)
        }
        #else
        return nil
        #endif
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
