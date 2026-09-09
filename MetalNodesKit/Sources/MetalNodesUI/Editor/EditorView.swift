import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

public struct EditorView: View {
    let model: EditorModel
    let device: MTLDevice
    let services: EditorServices
    @State private var exportError: String?
    /// A chooser is on screen; a second request must not stack another one behind it.
    @State private var exporting = false
    @State private var lastOrbitTranslation: CGSize = .zero
    /// The previous `MagnifyGesture` factor, so a pinch dollies by its step rather than its total.
    @State private var lastMagnification: CGFloat?

    public init(model: EditorModel, device: MTLDevice, services: EditorServices = .platform) {
        self.model = model
        self.device = device
        self.services = services
    }

    public var body: some View {
        split
            .background(DraculaToken.background.color)
            .preferredColorScheme(.dark)
            .tint(DraculaToken.purple.color)
            .focusedSceneValue(\.editorModel, model)
            .onChange(of: model.exportRequest) { _, _ in
                // A modal panel must not run inside SwiftUI's update transaction (it returns
                // immediately without showing); hop to the next main-actor turn first. The iPad's
                // `fileExporter` needs the same hop for its `isPresented` write.
                Task { @MainActor in
                    guard !exporting else { return }
                    exporting = true
                    defer { exporting = false }
                    if case .failed(let message) = await model.exportShader(using: services.exporter) {
                        exportError = message
                    }
                }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
            .padHosts(services)
    }

    /// macOS: three columns in an `HSplitView`. iPad: `EditorViewPad` (spec §22.3), which takes
    /// this same `previewColumn` as its trailing inspector.
    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            PaletteView(model: model).frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
            canvasColumn.frame(minWidth: 480)
            previewColumn.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        EditorViewPad(model: model, device: device, services: services) { previewColumn }
        #endif
    }

    private var canvasColumn: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model)
            if model.isEditingCode, case .definition(let id) = model.activePath {
                CodeEditorView(model: model, definition: id)
            } else {
                GraphCanvasView(model: model)
            }
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
                CodePanel(model: model).frame(height: 260)
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
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    guard model.document.settings.target != .realityKit else { return }
                                    if case .active(let p) = phase { setMouse(p, in: geo.size) }
                                }
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { g in
                                        if model.document.settings.target == .realityKit {
                                            applyOrbitDrag(g)
                                        } else {
                                            setMouse(g.location, in: geo.size)
                                        }
                                    }
                                    .onEnded { _ in lastOrbitTranslation = .zero })
                                // Pinch dollies the camera (spec §23.5), gated on the target the way
                                // the orbit drag is, and simultaneous so the drag still gets its
                                // events — the shape the canvas's own zoom uses.
                                .simultaneousGesture(dollyGesture)
                            #if os(macOS)
                            // The scroll wheel's half. `ScrollWheelCatcher` hit-tests to `nil`, so
                            // it takes no clicks from the drag gesture underneath it; it is the same
                            // catcher the canvas pans and zooms with (spec §18.6).
                            if model.document.settings.target == .realityKit {
                                ScrollWheelCatcher { delta, _, _, precise in
                                    // A wheel notch reports a handful of points and a trackpad
                                    // hundreds of fine ones — the 10× split the canvas's zoom makes.
                                    model.dollyPreview(by: Float(delta.height) * (precise ? 1 : 10))
                                }
                                .frame(width: geo.size.width, height: geo.size.height)
                            }
                            #endif
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DraculaToken.surface.color))
            PlaybackControls(model: model)
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
            InspectorView(model: model, services: services)
        }
        .padding(10)
    }

    private func setMouse(_ p: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        model.preview.mouse = SIMD2(Float(min(max(p.x / size.width, 0), 1)), Float(1 - min(max(p.y / size.height, 0), 1)))
    }

    /// Orbits the 3D preview. `DragGesture` reports cumulative translation, so the delta is the
    /// difference from the last event — the same shape the canvas's pan uses.
    private func applyOrbitDrag(_ g: DragGesture.Value) {
        let dx = Float(g.translation.width - lastOrbitTranslation.width)
        let dy = Float(g.translation.height - lastOrbitTranslation.height)
        lastOrbitTranslation = g.translation
        var camera = model.viewState.orbit
        camera.orbit(dx: dx, dy: dy)
        model.setOrbit(camera)
    }

    /// Pinch-to-dolly (spec §23.5). `MagnifyGesture` reports a *cumulative* factor, so the step is
    /// the ratio against the last event — the same "delta since last" shape `applyOrbitDrag(_:)`
    /// uses for the drag's cumulative translation. Gated on the target inside `model.magnifyPreview`.
    private var dollyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let previous = lastMagnification ?? 1
                lastMagnification = g.magnification
                guard previous > 0 else { return }
                model.magnifyPreview(by: Float(g.magnification / previous))
            }
            .onEnded { _ in lastMagnification = nil }
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

/// The preview control row (spec §26.3): scrubber, frame counter, loop toggle. The renderer
/// writes `preview.clock` on every draw, so any view reading `preview.clock.*` re-evaluates at
/// refresh rate — kept as its own small `View` so only this row re-renders, not the whole
/// `EditorView` body.
private struct PlaybackControls: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Button(model.preview.clock.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
            Button("Reset") { model.resetPlayback() }
            // The scrubber (spec §26.3): dragging pauses and moves; releasing does not resume.
            // A duration under half a frame still passes `setTimeline`'s `> 0` guard and rounds
            // `frameCount` to 1, so the range floor is pinned to 1 rather than letting it collapse
            // to `0...0`; the slider is disabled outright when there is nothing to scrub across.
            Slider(value: Binding(get: { Double(model.preview.clock.frame) },
                                  set: { model.scrub(to: Int($0.rounded())) }),
                   in: 0...Double(max(model.preview.clock.timeline.frameCount - 1, 1)), step: 1)
                .controlSize(.mini)
                .disabled(model.preview.clock.timeline.frameCount < 2)
            Text("\(model.preview.clock.frame + 1) / \(model.preview.clock.timeline.frameCount)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)
            Text(String(format: "%.2f s", model.preview.clock.mode == .wallClock && !model.preview.clock.timeline.loops
                        ? model.preview.clock.elapsedSeconds : Double(model.preview.clock.time)))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 56, alignment: .trailing)
            Toggle("Loop", isOn: Binding(get: { model.document.settings.timeline.loops },
                                         set: { on in var t = model.document.settings.timeline; t.loops = on; model.setTimeline(t) }))
                .toggleStyle(.switch).controlSize(.mini)
            Text("gen \(model.preview.pipeline?.generation ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(DraculaToken.muted.color)
        }
        .controlSize(.small)
    }
}

private extension View {
    /// The iPad pickers' single attachment point (spec §22.4): the presenters are per-window state,
    /// so their modifiers go on the window's root view exactly once. A no-op on macOS, and a
    /// pass-through whenever the injected services are not the Pad ones (the tests' doubles).
    @ViewBuilder
    func padHosts(_ services: EditorServices) -> some View {
        #if os(iOS)
        modifier(ImageChooserPadHost(chooser: services.imageChooser as? ImageChooserPad))
            .modifier(ExporterPadHost(exporter: services.exporter as? ExporterPad))
        #else
        self
        #endif
    }
}
