import SwiftUI
import MetalNodesCore

/// Inspector pane for a selected group instance (spec §20.8): the instance's title, the definition
/// it points at with the three operations, and its exposed sockets.
struct InstancePane: View {
    let model: EditorModel
    let id: NodeID
    @State private var titleDraft = ""

    var body: some View {
        if let node = model.graph.nodes[id], case .group(let gid) = node.kind,
           let def = model.document.definitions[gid] {
            content(node, def)
        } else {
            Text("Unknown group").foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func content(_ node: NodeInstance, _ def: GroupDefinition) -> some View {
        let resolved = model.resolvedTypes[id]
        HStack {
            Text(node.customTitle ?? def.name).font(.headline)
            Spacer()
            Circle().fill(DraculaTheme.token(for: def.accent).color).frame(width: 10, height: 10)
        }
        // The definition is renamed in its own pane, not here: one instance must not retitle it.
        Text(def.name).font(.caption.monospaced()).foregroundStyle(DraculaToken.muted.color)

        TextField("Title", text: $titleDraft, prompt: Text(def.name))
            .textFieldStyle(.roundedBorder)
            .onAppear { titleDraft = node.customTitle ?? "" }
            .onChange(of: id) { _, _ in titleDraft = node.customTitle ?? "" }
            .onChange(of: node.customTitle) { _, t in titleDraft = t ?? "" }
            .onSubmit { model.apply(.setTitle(id, titleDraft)) }

        HStack {
            Button("Edit Group") { model.diveIn(id) }
            Button("Make Unique") { model.makeUniqueSelection() }
            Button("Ungroup") { model.ungroupSelection() }
        }
        .controlSize(.small)

        if !def.inputs.isEmpty {
            Divider()
            ForEach(def.inputs, id: \.name) { decl in
                let ref = SocketRef(id, decl.name)
                if let src = model.graph.source(feeding: ref) {
                    HStack {
                        Text(decl.label).font(.caption)
                        Spacer()
                        Text("← \(model.socketLabel(src))").font(.caption).foregroundStyle(DraculaToken.muted.color)
                    }
                } else if case .value(let dflt) = decl.default {
                    // Unwired exposed inputs are per-instance uniform slots (spec §20.4).
                    let type = resolved?.inputTypes[decl.name] ?? decl.type.concreteOrFloat
                    ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                                 value: node.params[decl.name] ?? dflt,
                                 onChange: { model.apply(.setParam(id, decl.name, $0)) },
                                 onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
                } else {
                    HStack {
                        Text(decl.label).font(.caption)
                        Spacer()
                        Text("required").font(.caption2).foregroundStyle(DraculaToken.muted.color)
                    }
                }
            }
        }

        if !def.outputs.isEmpty {
            Divider()
            ForEach(def.outputs, id: \.name) { decl in
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
}

/// Inspector pane for the definition being edited (spec §20.8): name, accent, the socket lists with
/// rename and remove, and deletion once no instance is left.
struct DefinitionPane: View {
    let model: EditorModel
    let id: GroupID
    @State private var nameDraft = ""

    var body: some View {
        if let def = model.document.definitions[id] {
            content(def)
        } else {
            Text("Unknown group").foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func content(_ def: GroupDefinition) -> some View {
        let used = GroupOperations.isUsed(id, in: model.document)
        HStack {
            Text("Definition").font(.headline)
            Spacer()
            Circle().fill(DraculaTheme.token(for: def.accent).color).frame(width: 10, height: 10)
        }
        TextField("Name", text: $nameDraft, prompt: Text(def.name))
            .textFieldStyle(.roundedBorder)
            .onAppear { nameDraft = def.name }
            .onChange(of: id) { _, _ in nameDraft = def.name }
            .onChange(of: def.name) { _, n in nameDraft = n }
            .onSubmit { commitName(def) }
        Picker("Accent", selection: Binding(get: { def.accent }, set: { model.apply(.setDefinitionAccent(id, $0)) })) {
            ForEach(DraculaAccent.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.menu)
        .font(.caption)

        socketList("Inputs", kind: .input, decls: def.inputs)
        socketList("Outputs", kind: .output, decls: def.outputs)

        Divider()
        Button("Delete definition") { model.apply(.deleteDefinition(id)) }
            .controlSize(.small)
            .disabled(used)
        if used {
            Text("Still in use. Delete every instance first.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
        }
    }

    /// Sockets are added by wiring into a pseudo-node's `+` (spec §20.6); this pane renames and removes.
    @ViewBuilder
    private func socketList(_ title: String, kind: SocketKind, decls: [SocketDecl]) -> some View {
        Divider()
        Text(title).font(.caption.bold()).foregroundStyle(DraculaToken.muted.color)
        if decls.isEmpty {
            Text("None").font(.caption2).foregroundStyle(DraculaToken.muted.color)
        } else {
            ForEach(decls, id: \.name) { SocketRow(model: model, group: id, kind: kind, decl: $0) }
        }
    }

    private func commitName(_ def: GroupDefinition) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != def.name else { nameDraft = def.name; return }
        model.apply(.renameDefinition(id, name))
    }
}

/// One row of the definition pane's socket lists: rename on submit, `−` to remove.
private struct SocketRow: View {
    let model: EditorModel
    let group: GroupID
    let kind: SocketKind
    let decl: SocketDecl
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $draft, prompt: Text(decl.name))
                .textFieldStyle(.roundedBorder)
                .onAppear { draft = decl.name }
                .onSubmit { commit() }
            Text(typeLabel).font(.caption2.monospaced()).foregroundStyle(DraculaToken.muted.color)
            Button { model.apply(.removeSocket(group, kind, decl.name)) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DraculaToken.muted.color)
            .help("Remove \(decl.label)")
        }
    }

    private var typeLabel: String {
        switch decl.type {
        case .concrete(let c): c.rawValue
        case .generic(let g): g
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != decl.name else { draft = decl.name; return }
        model.apply(.renameSocket(group, kind, from: decl.name, to: name))
        // A clash — or a name that sanitises to the one it already has — leaves the definition
        // untouched and this row alive, so put the field back to the name it still carries. On a
        // successful rename the row is rebuilt under the new name and this write goes with it.
        draft = decl.name
    }
}
