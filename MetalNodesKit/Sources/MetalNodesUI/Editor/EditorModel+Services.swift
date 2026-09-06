import Foundation
import MetalNodesCore

/// The three actions the platform services drive (spec §22.4). They live on the model, not in the
/// views, so the undo naming, the "one step" grouping and the export error message are single-sourced
/// and unit-testable with the in-memory doubles.
extension EditorModel {
    /// The image well's "Choose…": one undo step ("Choose Image") for the import and the assignment
    /// together (spec §21.2). A cancelled chooser opens no transaction, so nothing is registered.
    public func chooseImage(for node: NodeID, param: ParamID, from source: ImageSource,
                            using chooser: any ImageChooser) async {
        guard let picked = await chooser.choose(from: source) else { return }
        beginTransaction("Choose Image")
        if let asset = importImage(data: picked.data, name: picked.name) {
            apply(.setParam(node, param, .asset(asset)))
        }
        endTransaction()
    }

    /// The Assets list's "Relink…": re-imports a missing texture's bytes under its own id, so every
    /// node pointing at it keeps pointing at it (spec §21.2). `replaceAssetBytes` names its own
    /// undo step ("Replace Image") and refuses data that is not an image, with a notice.
    public func relinkAsset(_ id: AssetID, from source: ImageSource,
                            using chooser: any ImageChooser) async {
        guard let picked = await chooser.choose(from: source) else { return }
        replaceAssetBytes(id, data: picked.data)
    }

    /// File ▸ Export Shader… (spec §21.3, §22.4). A graph that does not generate is refused here,
    /// before any panel or picker is put on screen — the exporter is never asked.
    public func exportShader(using exporter: any Exporter) async -> ExportOutcome {
        let files: [ExportFile]
        do {
            files = try exportFiles()
        } catch {
            return .failed("The graph has errors; fix them before exporting.")
        }
        return await exporter.export(files: files,
                                     name: StitchableCodegen.sanitizedName(document.settings.exportName))
    }
}
