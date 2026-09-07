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

    /// What one `mirror(into:)` wrote. The host tells a view-state-only write apart: the model's
    /// own undo step has already marked the document changed for anything else.
    public struct Written: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let document = Written(rawValue: 1)
        public static let viewState = Written(rawValue: 2)
        public static let textures = Written(rawValue: 4)
        public static let missingTextures = Written(rawValue: 8)
    }

    /// Model → file. Writes each field only when it differs, so a value that arrived *from* the
    /// file is never written back (which would mark the window dirty for nothing).
    @discardableResult
    public func mirror(into file: inout ShaderPackage) -> Written {
        var wrote: Written = []
        if file.document != model.document { file.document = model.document; wrote.insert(.document) }
        if file.viewState != model.viewState { file.viewState = model.viewState; wrote.insert(.viewState) }
        if file.textures != model.textures { file.textures = model.textures; wrote.insert(.textures) }
        if file.missingTextures != model.missingTextures { file.missingTextures = model.missingTextures; wrote.insert(.missingTextures) }
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
