import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Drag payload from the palette to the canvas. Dynamic type; never leaves the app.
    nonisolated static let metalNodesNodeDef = UTType(exportedAs: "com.maxburger.metalnodes.nodedef")
    /// Pasteboard payload for `GraphClipboard` (spec §18.4). Dynamic type; never leaves the app.
    /// `UTType(EditorModel.pasteboardType)` (the failable init) returns `nil` for an unregistered
    /// identifier and would fall back to `.data`, which enables Paste for *any* pasteboard
    /// content — this exported type registers the identifier so `onPasteCommand(of:)` only
    /// enables Paste when the pasteboard actually holds our graph payload.
    nonisolated static let metalNodesGraph = UTType(exportedAs: EditorModel.pasteboardType)
}

/// What a palette row drags: just the definition id.
struct NodeDefTransfer: Codable, Transferable, Sendable {
    let defID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .metalNodesNodeDef)
    }
}
