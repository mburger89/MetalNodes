import SwiftUI
import MetalNodesCore

/// View ▸ Generated Code (⌘⌥C, spec §21.5): the generated MSL, Dracula-highlighted, with the
/// selected node's lines (when exactly one node is selected) shown on a `currentLine` background.
public struct CodePanel: View {
    let model: EditorModel

    public init(model: EditorModel) { self.model = model }

    /// The panel below which the header — Copy included — would be cut off. The split view is free
    /// to make the panel this short; the source simply scrolls in what is left.
    public static let minimumHeight: CGFloat = 92

    public var body: some View {
        // The header takes its own height first and the scroll view gets the remainder: a minimum
        // on the *scroll view* would instead let a short panel push the header off the top, where
        // it was clipped and its Copy button unclickable.
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView([.vertical, .horizontal]) {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: Self.minimumHeight, alignment: .top)
        .background(DraculaToken.background.color)
    }

    private var header: some View {
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
        .lineLimit(1)
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
