import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MetalNodesCore

/// The stitchable target's `.metal` + `.swift` pair, as one directory `FileWrapper` (spec §22.4).
/// `fileExporter` writes a folder in one grant, which is the same reason the Mac panel asks for a
/// folder rather than a file (see `ExportPanelMac`).
///
/// `nonisolated` because SwiftUI calls `FileDocument` off the main actor, and this module's default
/// isolation is `MainActor`.
nonisolated public struct ExportFolderDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.folder] }

    /// The folder's own name — the sanitized export name.
    public let name: String
    public let files: [ExportFile]

    public init(name: String, files: [ExportFile]) {
        self.name = name
        self.files = files
    }

    /// Export-only: nothing in the app opens one of these back.
    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    /// The wrapper the exporter writes. Split out of the `FileDocument` requirement because
    /// `FileDocumentWriteConfiguration` has no public initializer, so the tests cannot call it.
    public func makeWrapper() -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for file in files {
            let child = FileWrapper(regularFileWithContents: Data(file.contents.utf8))
            child.preferredFilename = file.name
            children[file.name] = child
        }
        let directory = FileWrapper(directoryWithFileWrappers: children)
        directory.preferredFilename = name
        return directory
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { makeWrapper() }
}

nonisolated extension UTType {
    /// Metal shading-language source. No iOS app registers `.metal`, so this is the dynamic type
    /// for the extension; the exporter names its file by it. Under the bare `.sourceCode` type the
    /// system appended `.txt` to `metalNodesShader.metal` (manual check 17).
    public static let metalSource = UTType(filenameExtension: "metal", conformingTo: .sourceCode) ?? .sourceCode
}

/// The fragment target's single `.metal` file, exported directly rather than inside a folder.
nonisolated public struct ExportTextDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.metalSource] }

    public let name: String
    public let contents: String

    public init(file: ExportFile) {
        self.name = file.name
        self.contents = file.contents
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.name = configuration.file.preferredFilename ?? "Shader.metal"
        self.contents = String(decoding: data, as: UTF8.self)
    }

    public func makeWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: Data(contents.utf8))
        wrapper.preferredFilename = name
        return wrapper
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { makeWrapper() }
}
