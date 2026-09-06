#if os(iOS)
import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

/// The iPad editor (spec §22.3): the palette as the split view's sidebar, breadcrumb over canvas
/// as the detail, and the preview / inspector / code column as a trailing inspector. The inspector
/// content is passed in rather than rebuilt — it is `EditorView.previewColumn`, unchanged.
struct EditorViewPad<Inspector: View>: View {
    let model: EditorModel
    let device: MTLDevice
    let services: EditorServices
    @ViewBuilder let inspector: () -> Inspector

    /// Slide Over and a narrow Split View are compact; M6 supports regular width only (spec §22.3).
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if sizeClass == .compact {
            ContentUnavailableView("MetalNodes needs a wider window",
                                   systemImage: "rectangle.split.3x1",
                                   description: Text("Open MetalNodes full screen, or widen the Split View, to edit this shader. The document stays open."))
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                PaletteView(model: model)
                    .navigationTitle("Nodes")
                    .navigationBarTitleDisplayMode(.inline)
            } detail: {
                VStack(spacing: 0) {
                    BreadcrumbBar(model: model)
                    GraphCanvasView(model: model)
                }
                .toolbar { toolbarItems }
                .inspector(isPresented: Binding(get: { model.viewState.showsInspector },
                                                set: { model.viewState.showsInspector = $0 })) {
                    inspector()
                        .inspectorColumnWidth(380)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.requestCanvas(.openChooser) } label: {
                Label("Add Node", systemImage: "plus")
            }
            .accessibilityIdentifier("toolbar.add")

            Picker("Canvas Mode", selection: Binding(get: { model.viewState.canvasMode },
                                                     set: { model.viewState.canvasMode = $0 })) {
                Label("Pointer", systemImage: "cursorarrow").tag(CanvasMode.pointer)
                Label("Select", systemImage: "plus.square.dashed").tag(CanvasMode.select)
                Label("Lasso", systemImage: "lasso").tag(CanvasMode.lasso)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("toolbar.mode")

            // One button for both fits, like the two menu items: with a selection it frames the
            // selection, otherwise the whole graph (spec §22.3).
            Button { model.requestCanvas(model.selection.isEmpty ? .fitAll : .fitSelection) } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("toolbar.fit")

            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)

            Button { model.viewState.showsInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityIdentifier("toolbar.inspector")

            exportMenu
        }
    }

    /// Export (spec §22.4). "Export to Files…" goes through `exportRequest` → `EditorView` →
    /// `services.exporter`, the same path the macOS save panel uses; Share hands the same files to
    /// `ShareLink` from a temporary directory. The URLs are computed in the menu's content, so
    /// nothing is written to disk until the menu is actually opened.
    private var exportMenu: some View {
        Menu {
            Button("Export to Files…") { model.requestExport() }
            if let urls = shareURLs {
                ShareLink("Share…", items: urls)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("toolbar.export")
    }

    /// `nil` — so the menu shows only "Export to Files…" — when the graph has errors, or when the
    /// injected exporter is a test double rather than the Pad presenter.
    private var shareURLs: [URL]? {
        guard let pad = services.exporter as? ExporterPad,
              let files = try? model.exportFiles() else { return nil }
        return try? pad.temporaryShareURLs(files: files, name: model.document.settings.exportName)
    }
}
#endif
