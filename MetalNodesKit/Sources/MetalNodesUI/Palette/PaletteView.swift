import SwiftUI
import MetalNodesCore

/// Left sidebar (spec §18.7): search, categorised list, drag-out, double-click to place.
public struct PaletteView: View {
    let model: EditorModel
    @State private var query = ""

    public init(model: EditorModel) { self.model = model }

    private var results: [NodeDef] { PaletteSearch.filter(query, in: model.registry.all) }
    private var definitions: [GroupDefinition] { PaletteSearch.filterDefinitions(query, in: model.document) }

    public var body: some View {
        VStack(spacing: 0) {
            TextField("Search nodes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                ForEach(PaletteSearch.grouped(results), id: \.category) { group in
                    Section(group.category.displayName) {
                        ForEach(group.defs, id: \.id) { row($0) }
                    }
                }
                // The document's group definitions (spec §11.4, §20.8). Hidden while a search is
                // running and matches nothing, so it behaves like the builtin sections.
                let defs = definitions
                if !defs.isEmpty {
                    Section(NodeCategory.group.displayName) {
                        ForEach(defs) { definitionRow($0) }
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(NodeCategory.group.displayName) {
                        Text("None yet").font(.caption).foregroundStyle(DraculaToken.muted.color)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(DraculaToken.background.color)
    }

    private func row(_ def: NodeDef) -> some View {
        HStack(spacing: 8) {
            Circle().fill(DraculaTheme.token(for: def.category).color).frame(width: 8, height: 8)
            Text(def.title).font(.callout)
            Spacer()
        }
        .contentShape(Rectangle())
        .draggable(NodeDefTransfer(defID: def.id))
        .onTapGesture(count: 2) { model.requestCanvas(.place(defID: def.id)) }
    }

    /// "Edit" opens the definition with no instance to dive through (spec §20.6); a drag or a
    /// double-click places an instance, which `addInstance` refuses if it would recurse.
    private func definitionRow(_ def: GroupDefinition) -> some View {
        HStack(spacing: 8) {
            Circle().fill(DraculaTheme.token(for: def.accent).color).frame(width: 8, height: 8)
            Text(def.name).font(.callout).lineLimit(1)
            Spacer()
            Button("Edit") { model.editDefinition(def.id) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DraculaToken.muted.color)
                .help("Edit \(def.name)")
        }
        .contentShape(Rectangle())
        .draggable(NodeDefTransfer(groupID: def.id))
        .onTapGesture(count: 2) { model.requestCanvas(.placeGroup(def.id)) }
    }
}
