import Foundation
import MetalNodesCore

/// The model ↔ file mirror, out of the window (spec §22.6). The host owns a `FileDocument` it
/// cannot show this module; the bridge owns everything about *when* a field moves between the two,
/// so both directions are unit-testable without a window.
@MainActor
public final class DocumentBridge {
    public let model: EditorModel

    public init(model: EditorModel) { self.model = model }

    /// Everything the package holds, from the model's live state — `missingTextures` included, so a
    /// reseed from this package re-imposes the same missing set the model has now.
    public var package: ShaderPackage {
        var p = model.package
        p.missingTextures = model.missingTextures
        return p
    }

    /// Model → file. Writes each field only when it differs, so a value that arrived *from* the
    /// file is never written back (which would mark the window dirty for nothing). True if anything
    /// was written.
    @discardableResult
    public func mirror(into file: inout ShaderPackage) -> Bool {
        var wrote = false
        if file.document != model.document { file.document = model.document; wrote = true }
        if file.viewState != model.viewState { file.viewState = model.viewState; wrote = true }
        if file.textures != model.textures { file.textures = model.textures; wrote = true }
        if file.missingTextures != model.missingTextures { file.missingTextures = model.missingTextures; wrote = true }
        return wrote
    }

    /// File → model. A no-op for a package equal to what the model already holds (the mirror's own
    /// writes come back through here); anything else is an external change — File ▸ Revert To Saved
    /// — and reseeds the model, undo stack and all. True if it reloaded.
    @discardableResult
    public func apply(_ incoming: ShaderPackage) -> Bool {
        guard incoming.document != model.document
                || incoming.viewState != model.viewState
                || incoming.textures != model.textures else { return false }
        model.reload(package: incoming)
        return true
    }
}
