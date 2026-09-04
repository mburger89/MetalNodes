import SwiftUI
import MetalNodesCore

/// The ⇧A / double-click / wire-drop node chooser (spec §18.7).
struct NodeSearchPopover: View {
    let defs: [NodeDef]
    let onPick: (NodeDef) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var results: [NodeDef] { PaletteSearch.filter(query, in: defs) }

    var body: some View {
        VStack(spacing: 6) {
            TextField("Add node…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { pick() }
                .onChange(of: query) { _, _ in highlighted = 0 }
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, def in
                        HStack(spacing: 8) {
                            Circle().fill(DraculaTheme.token(for: def.category).color).frame(width: 8, height: 8)
                            Text(def.title)
                            Spacer()
                            Text(def.category.rawValue).font(.caption2).foregroundStyle(DraculaToken.muted.color)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .listRowBackground(i == highlighted ? DraculaToken.surface.color : Color.clear)
                        .onTapGesture { highlighted = i; pick() }
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: highlighted) { _, h in proxy.scrollTo(h) }
            }
        }
        .padding(8)
        .frame(width: 280, height: 340)
        .background(DraculaToken.background.color)
        .onAppear { fieldFocused = true }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func pick() {
        guard results.indices.contains(highlighted) else { return }
        onPick(results[highlighted])
    }
}
