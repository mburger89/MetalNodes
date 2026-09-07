#if os(iOS)
import SwiftUI
import Metal
import CoreTransferable
import UniformTypeIdentifiers
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
        // The sidebar column's own bar keeps its collapse button; with the detail bar hidden this
        // is the way back once it is collapsed.
        ToolbarItem(placement: .topBarLeading) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Label("Nodes", systemImage: "sidebar.leading")
            }
            .accessibilityIdentifier("toolbar.palette")
        }
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
    /// `services.exporter`, the same path the macOS save panel uses; Share hands the share sheet an
    /// `ExportShareItem`, which carries the document and generates on demand. `Menu`'s content is a
    /// plain (non-escaping) builder that SwiftUI runs during `body`, so nothing here may generate
    /// code or touch the file system: copying the document value is all this costs.
    private var exportMenu: some View {
        Menu {
            Button("Export to Files…") { model.requestExport() }
            if canShare {
                ShareLink("Share…",
                          item: ExportShareItem(document: model.document, registry: model.registry),
                          preview: SharePreview(StitchableCodegen.sanitizedName(model.document.settings.exportName)))
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("toolbar.export")
    }

    /// Share is offered only under the Pad exporter — an injected test double gets the menu without
    /// it — and only while the graph has no errors, so the failure case stays where §22.4 puts it:
    /// the "The graph has errors" alert of Export to Files…. Both reads are cheap; `diagnostics` is
    /// already computed for the preview, and neither runs codegen.
    private var canShare: Bool {
        services.exporter is ExporterPad && !model.diagnostics.contains { $0.severity == .error }
    }
}

/// What Share… hands the share sheet (spec §22.4): the document itself, not files. Codegen and the
/// disk write happen inside the file representation — off the main actor, when the sheet asks for
/// the payload — never during `body`, which SwiftUI re-evaluates on every document change (a node
/// drag emits one per frame). The folder is what travels, so a stitchable target's `.metal` and
/// `.swift` arrive together and the fragment target's single `.metal` arrives inside a folder named
/// for the export, exactly as `ExportFolderDocument` writes it.
nonisolated struct ExportShareItem: Transferable, Sendable {
    let document: ShaderDocument
    let registry: NodeRegistry

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { item in
            let files = try ShaderExport.files(for: item.document, registry: item.registry)
            let folder = try ExporterPad.temporaryShareFolder(
                files: files, name: StitchableCodegen.sanitizedName(item.document.settings.exportName))
            // The folder is ours, freshly written under `tmp` and never mutated afterwards, so the
            // system can read it in place instead of copying it.
            return SentTransferredFile(folder, allowAccessingOriginalFile: true)
        }
    }
}
#endif
