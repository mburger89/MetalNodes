import CoreTransferable
import UniformTypeIdentifiers
import MetalNodesCore

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

/// What a palette row drags: a builtin's id, or — from "My Functions" — a definition's
/// `GroupID` (spec §20.8). Exactly one is set; both are optional so an older payload that
/// carries only `defID` still decodes.
struct NodeDefTransfer: Codable, Transferable, Sendable {
    let defID: String?
    let groupID: GroupID?

    init(defID: String) { self.defID = defID; self.groupID = nil }
    init(groupID: GroupID) { self.defID = nil; self.groupID = groupID }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .metalNodesNodeDef)
    }
}
