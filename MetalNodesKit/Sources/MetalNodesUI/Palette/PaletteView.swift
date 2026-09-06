import SwiftUI
import MetalNodesCore

/// Left sidebar (spec §18.7): search, categorised list, drag-out, double-click to place.
public struct PaletteView: View {
    let model: EditorModel
    @State private var query = ""

    public init(model: EditorModel) { self.model = model }

    private var results: [NodeDef] { PaletteSearch.filter(query, in: model.registry.all) }

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
                Section("My Functions") {
                    Text("None yet").font(.caption).foregroundStyle(DraculaToken.muted.color)
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
}
