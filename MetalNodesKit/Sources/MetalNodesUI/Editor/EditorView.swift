import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

public struct EditorView: View {
    let model: EditorModel
    let device: MTLDevice

    public init(model: EditorModel, device: MTLDevice) {
        self.model = model
        self.device = device
    }

    public var body: some View {
        split
            .background(DraculaToken.background.color)
            .preferredColorScheme(.dark)
            .tint(DraculaToken.purple.color)
            .focusedSceneValue(\.editorModel, model)
    }

    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            PaletteView(model: model).frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
            GraphCanvasView(model: model).frame(minWidth: 480)
            previewPane.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        HStack(spacing: 0) {
            PaletteView(model: model).frame(width: 220)
            GraphCanvasView(model: model)
            previewPane.frame(width: 420)
        }
        #endif
    }

    private var previewPane: some View {
        VStack(spacing: 8) {
            PreviewView(state: model.preview, device: device)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DraculaToken.surface.color))
            HStack {
                Button(model.preview.isPlaying ? "Pause" : "Play") { model.preview.isPlaying.toggle() }
                Button("Reset") { model.preview.resetRequested = true }
                Spacer()
                Text("gen \(model.preview.pipeline?.generation ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DraculaToken.muted.color)
            }
            .controlSize(.small)
            diagnosticsList
            Divider()
            InspectorView(model: model)
        }
        .padding(10)
    }

    private var diagnosticsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let err = model.preview.lastError {
                Text(err).font(.caption2.monospaced()).foregroundStyle(DraculaTheme.error.color).lineLimit(6)
            }
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, d in
                Text(d.message).font(.caption).foregroundStyle(d.severity == .error ? DraculaTheme.error.color : DraculaToken.orange.color)
            }
            if model.diagnostics.isEmpty && model.preview.lastError == nil {
                Text("No problems").font(.caption).foregroundStyle(DraculaToken.muted.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
