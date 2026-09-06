import Foundation

/// Failure modes for reading a `.mnshader` package (spec §21.1).
public enum PackageError: Error, Equatable, LocalizedError {
    case notAPackage
    case missingDocument
    case undecodable(String)
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .notAPackage: "This is not a MetalNodes shader package."
        case .missingDocument: "The package has no document.json."
        case .undecodable(let why): "The shader could not be read: \(why)"
        case .newerFormat: "This shader was saved by a newer version of MetalNodes"
        }
    }
}

/// The `.mnshader` package as a value: everything read from and written to a `FileWrapper`
/// (spec §21.1). Foundation-only so it lives in Core alongside the document it wraps.
public struct ShaderPackage: Sendable, Equatable {
    public static let documentFileName = "document.json"
    public static let viewFileName = "view.json"
    public static let texturesDirectory = "textures"

    public var document: ShaderDocument
    public var viewState: EditorViewState
    public var textures: [AssetID: Data]
    /// Assets present in `document.settings.assets` whose bytes were absent from `textures/`
    /// on read (spec §21.1: the manifest entry stays, the preview renders the placeholder).
    public private(set) var missingTextures: Set<AssetID> = []

    public init(document: ShaderDocument, viewState: EditorViewState = EditorViewState(), textures: [AssetID: Data] = [:]) {
        self.document = document
        self.viewState = viewState
        self.textures = textures
    }

    /// `<uuid lowercased>.<ext>`, e.g. `3f9c….png` (spec §21.1).
    public static func fileName(for asset: AssetID, info: AssetInfo) -> String {
        "\(asset.raw.uuidString.lowercased()).\(info.fileExtension)"
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    /// Just enough of `document.json` to gate on `formatVersion` before attempting the full
    /// decode, so a package from a newer app version reports `newerFormat` rather than whatever
    /// unrelated decoding error its unfamiliar shape would otherwise produce.
    private struct VersionProbe: Decodable { let formatVersion: Int }

    public init(fileWrapper wrapper: FileWrapper) throws(PackageError) {
        guard wrapper.isDirectory, let files = wrapper.fileWrappers else { throw .notAPackage }
        guard let docData = files[Self.documentFileName]?.regularFileContents else { throw .missingDocument }

        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: docData),
           probe.formatVersion > ShaderDocument.currentFormatVersion {
            throw .newerFormat(probe.formatVersion)
        }
        do {
            document = try JSONDecoder().decode(ShaderDocument.self, from: docData)
        } catch {
            throw .undecodable(String(describing: error))
        }

        viewState = files[Self.viewFileName]?.regularFileContents
            .flatMap { try? JSONDecoder().decode(EditorViewState.self, from: $0) } ?? EditorViewState()

        var loadedTextures: [AssetID: Data] = [:]
        var missing = Set<AssetID>()
        let textureFiles = files[Self.texturesDirectory]?.fileWrappers ?? [:]
        for (id, info) in document.settings.assets {
            if let data = textureFiles[Self.fileName(for: id, info: info)]?.regularFileContents {
                loadedTextures[id] = data
            } else {
                missing.insert(id)
            }
        }
        textures = loadedTextures
        missingTextures = missing
    }

    public func fileWrapper() throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        root.addRegularFile(withContents: try Self.encoder.encode(document), preferredFilename: Self.documentFileName)
        root.addRegularFile(withContents: try Self.encoder.encode(viewState), preferredFilename: Self.viewFileName)

        let texturesWrapper = FileWrapper(directoryWithFileWrappers: [:])
        texturesWrapper.preferredFilename = Self.texturesDirectory
        for (id, info) in document.settings.assets {
            if let data = textures[id] {
                texturesWrapper.addRegularFile(withContents: data, preferredFilename: Self.fileName(for: id, info: info))
            }
        }
        root.addFileWrapper(texturesWrapper)
        return root
    }
}
