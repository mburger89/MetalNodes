import SwiftUI
import MetalNodesCore

/// Right sidebar (spec §18.8). Reuses `ParamControl`; the node body keeps its compact controls.
public struct InspectorView: View {
    let model: EditorModel
    @State private var titleDraft = ""
    @State private var widthDraft = ""
    @State private var heightDraft = ""

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch model.selection.count {
                case 0: documentSettings
                case 1: nodePane(model.selection.first!)
                default: Text("\(model.selection.count) nodes selected").font(.callout).foregroundStyle(DraculaToken.muted.color)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DraculaToken.background.color)
    }

    // MARK: Node

    @ViewBuilder
    private func nodePane(_ id: NodeID) -> some View {
        if let node = model.document.root.nodes[id], case .builtin(let defID) = node.kind, let def = model.registry[defID] {
            let resolved = model.resolvedTypes[id]
            HStack {
                Text(node.customTitle ?? def.title).font(.headline)
                Spacer()
                Text(def.category.rawValue.capitalized).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DraculaTheme.token(for: def.category).color.opacity(0.25))
                    .clipShape(Capsule())
            }
            Text(def.id).font(.caption.monospaced()).foregroundStyle(DraculaToken.muted.color)

            TextField("Title", text: $titleDraft, prompt: Text(def.title))
                .textFieldStyle(.roundedBorder)
                .onAppear { titleDraft = node.customTitle ?? "" }
                .onChange(of: id) { _, _ in titleDraft = node.customTitle ?? "" }
                .onChange(of: node.customTitle) { _, t in titleDraft = t ?? "" }
                .onSubmit { model.apply(.setTitle(id, titleDraft)) }

            Divider()

            ForEach(def.inputs, id: \.name) { decl in
                let ref = SocketRef(id, decl.name)
                if let src = model.document.root.source(feeding: ref) {
                    HStack {
                        Text(decl.label).font(.caption)
                        Spacer()
                        Text("← \(sourceLabel(src))").font(.caption).foregroundStyle(DraculaToken.muted.color)
                    }
                } else if case .value(let dflt) = decl.default {
                    let type = resolved?.inputTypes[decl.name] ?? (decl.type.concreteOrFloat)
                    ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                                 value: node.params[decl.name] ?? dflt,
                                 onChange: { model.apply(.setParam(id, decl.name, $0)) },
                                 onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
                }
            }
            ForEach(def.params, id: \.name) { p in
                ParamControl(label: p.label, kind: p.kind, value: node.params[p.name] ?? p.defaultValue,
                             onChange: { model.apply(.setParam(id, p.name, $0)) },
                             onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
            }

            let diags = model.diagnostics.filter { $0.node == id }
            if !diags.isEmpty {
                Divider()
                ForEach(Array(diags.enumerated()), id: \.offset) { _, d in
                    Text(d.message).font(.caption)
                        .foregroundStyle(d.severity == .error ? DraculaTheme.error.color : DraculaToken.orange.color)
                }
            }
        } else {
            Text("Unknown node").foregroundStyle(DraculaToken.muted.color)
        }
    }

    private func sourceLabel(_ src: SocketRef) -> String {
        guard let n = model.document.root.nodes[src.node], case .builtin(let d) = n.kind else { return src.socket }
        return "\(n.customTitle ?? model.registry[d]?.title ?? d).\(src.socket)"
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
        }
        .textFieldStyle(.roundedBorder)
    }

    private func clampedDimension(_ v: CGFloat) -> Int {
        v.isFinite ? Int(min(max(v, 16), 8192)) : 512
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

private extension TypeRef {
    var concreteOrFloat: SocketType {
        if case .concrete(let c) = self { return c } else { return .float }
    }
}
