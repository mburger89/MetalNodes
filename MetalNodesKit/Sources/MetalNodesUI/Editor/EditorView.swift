import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

public struct EditorView: View {
    let model: EditorModel
    let device: MTLDevice
    @State private var exportError: String?
    /// A panel is on screen; a second request must not stack another one behind it.
    @State private var exporting = false

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
            .onChange(of: model.exportRequest) { _, _ in
                #if os(macOS)
                // A modal panel must not run inside SwiftUI's update transaction (it returns
                // immediately without showing); hop to the next main-actor turn first.
                Task { @MainActor in
                    guard !exporting else { return }
                    exporting = true
                    defer { exporting = false }
                    do { exportError = ExportPanelMac.run(files: try model.exportFiles()) }
                    catch { exportError = "The graph has errors; fix them before exporting." }
                }
                #endif
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
    }

    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            PaletteView(model: model).frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
            canvasColumn.frame(minWidth: 480)
            previewColumn.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        HStack(spacing: 0) {
            PaletteView(model: model).frame(width: 220)
            canvasColumn
            previewColumn.frame(width: 420)
        }
        #endif
    }

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model)
            GraphCanvasView(model: model)
        }
    }

    /// The generated-code panel (spec §21.5) lives below the preview, in a draggable split on
    /// macOS and a plain stack on iPad; `showsCode` (View ▸ Generated Code, ⌘⌥C) toggles it.
    @ViewBuilder
    private var previewColumn: some View {
        #if os(macOS)
        // Both panes state a minimum and can grow, which is what lets the divider actually move;
        // the preview keeps the priority, so opening the panel takes the code panel's ideal height
        // and no more.
        VSplitView {
            previewPane
                .frame(minHeight: 220, maxHeight: .infinity)
                .layoutPriority(1)
            if model.viewState.showsCode {
                CodePanel(model: model)
                    .frame(minHeight: CodePanel.minimumHeight, idealHeight: 260, maxHeight: .infinity)
            }
        }
        #else
        VStack(spacing: 0) {
            previewPane
            if model.viewState.showsCode {
                CodePanel(model: model).frame(minHeight: CodePanel.minimumHeight, idealHeight: 260)
            }
        }
        #endif
    }

    private var previewPane: some View {
        VStack(spacing: 8) {
            PreviewView(state: model.preview, device: device)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let p) = phase { setMouse(p, in: geo.size) }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in setMouse(g.location, in: geo.size) })
                    }
                }
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
            if let v = model.viewer {
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").foregroundStyle(DraculaTheme.viewerFlag.color)
                    Text("Viewing \(model.socketLabel(v))").font(.caption).lineLimit(1)
                    if model.viewedType == .float || model.viewedType == .int {
                        TextField("Min", value: rangeBinding(lower: true), format: .number.precision(.fractionLength(2))).frame(width: 56)
                        TextField("Max", value: rangeBinding(lower: false), format: .number.precision(.fractionLength(2))).frame(width: 56)
                    }
                    Spacer()
                    Button("Clear") { model.setViewer(nil) }
                }
                .controlSize(.small)
                .textFieldStyle(.roundedBorder)
            }
            // A refused recursive placement, shown for 3 s (spec §20.8) — an error-class message.
            if let n = model.notice {
                Text(n).font(.caption).foregroundStyle(DraculaTheme.error.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            diagnosticsList
            Divider()
            InspectorView(model: model)
        }
        .padding(10)
    }

    private func setMouse(_ p: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        model.preview.mouse = SIMD2(Float(min(max(p.x / size.width, 0), 1)), Float(1 - min(max(p.y / size.height, 0), 1)))
    }

    private func rangeBinding(lower: Bool) -> Binding<Float> {
        Binding(
            get: { lower ? model.preview.viewerRange.lowerBound : model.preview.viewerRange.upperBound },
            set: { x in
                let r = model.preview.viewerRange
                let lo = lower ? x : r.lowerBound, hi = lower ? r.upperBound : x
                model.preview.viewerRange = lo...max(hi, lo + 0.0001)
            })
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
