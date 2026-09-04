import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Drag payload from the palette to the canvas. Dynamic type; never leaves the app.
    nonisolated static let metalNodesNodeDef = UTType(exportedAs: "com.maxburger.metalnodes.nodedef")
}

/// What a palette row drags: just the definition id.
struct NodeDefTransfer: Codable, Transferable, Sendable {
    let defID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .metalNodesNodeDef)
    }
}
