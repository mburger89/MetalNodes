import SwiftUI
import MetalNodesCore

/// View ▸ Generated Code (⌘⌥C, spec §21.5): the generated MSL, Dracula-highlighted, with the
/// selected node's lines (when exactly one node is selected) shown on a `currentLine` background.
public struct CodePanel: View {
    let model: EditorModel

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Generated Code").font(.caption).foregroundStyle(DraculaToken.muted.color)
                if isStale {
                    Text("(stale)").font(.caption).foregroundStyle(DraculaToken.muted.color)
                }
                Spacer()
                Button("Copy") {
                    model.pasteboard.write(Data(model.generatedSource.utf8), type: "public.utf8-plain-text")
                }
                .controlSize(.small)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160)
        }
        .padding(10)
        .background(DraculaToken.background.color)
    }

    /// The generation validated but produced no fresh source (spec §21.5 controller ruling): the
    /// panel keeps showing the last good source rather than going blank. Distinguishable from an
    /// ordinary Metal compile failure — which *does* refresh `generatedSource` — because only the
    /// graph-invalid path leaves `preview.lastError` at `nil` while an error diagnostic stands.
    private var isStale: Bool {
        model.preview.lastError == nil && model.diagnostics.contains { $0.severity == .error }
    }

    private var highlighted: AttributedString {
        MSLHighlighter.attributed(model.generatedSource, highlightLines: highlightLines)
    }

    private var highlightLines: Set<Int> {
        guard let only = model.selection.count == 1 ? model.selection.first : nil else { return [] }
        var lines = Set<Int>()
        for range in model.generatedLineMap.lines(for: only) { lines.formUnion(range) }
        return lines
    }
}
