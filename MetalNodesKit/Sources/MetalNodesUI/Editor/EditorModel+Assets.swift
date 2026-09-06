import Foundation
import CoreGraphics
import ImageIO
import MetalNodesCore

/// Image import and the asset manifest (spec §21.2). Bytes live in `textures`, keyed by the
/// `AssetID` the document's `settings.assets` manifest names; the manifest is document data and
/// therefore undoable, the bytes are not (undoing an import leaves them in the package, harmless
/// — the writer drops whatever the manifest no longer names).
extension EditorModel {
    /// One row of the inspector's Assets list.
    public struct AssetEntry: Identifiable, Sendable, Hashable {
        public let id: AssetID
        public let info: AssetInfo
    }

    /// The manifest as a stable list: by name, then by id so two images sharing a name still order
    /// deterministically.
    public var assetList: [AssetEntry] {
        document.settings.assets
            .map { AssetEntry(id: $0.key, info: $0.value) }
            .sorted {
                $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending
                    || ($0.info.name == $1.info.name && $0.id.raw.uuidString < $1.id.raw.uuidString)
            }
    }

    /// The bytes a `.asset` parameter value points at, for the image well's thumbnail.
    public func assetData(for value: ParamValue) -> Data? {
        guard case .asset(let id) = value, let id else { return nil }
        return textures[id]
    }

    // MARK: Import

    /// Copies `data` into the document as a new asset and returns its id. The manifest entry goes
    /// through `apply(.setSettings(_:))`, so an open transaction folds it into the caller's undo
    /// step. Refuses data no image decoder recognises, with a notice.
    public func importImage(data: Data, name: String) -> AssetID? {
        guard let size = pixelSize(of: data) else {
            showNotice("That file is not an image")
            return nil
        }
        let id = AssetID()
        var settings = document.settings
        settings.assets[id] = AssetInfo(name: name, pixelSize: size, fileExtension: fileExtension(of: name))
        apply(.setSettings(settings))
        textures[id] = data
        return id
    }

    /// Re-imports `data` under an id the manifest already holds: the relink of a texture whose bytes
    /// the package did not carry (spec §21.2). Keeps the manifest name — only the pixel size and the
    /// bytes are new — and recompiles so the "missing" warning goes away.
    @discardableResult
    public func replaceAssetBytes(_ id: AssetID, data: Data) -> Bool {
        guard var info = document.settings.assets[id] else { return false }
        guard let size = pixelSize(of: data) else {
            showNotice("That file is not an image")
            return false
        }
        info.pixelSize = size
        var settings = document.settings
        settings.assets[id] = info
        beginTransaction("Replace Image")
        apply(.setSettings(settings))
        endTransaction()

        textures[id] = data
        missingTextures.remove(id)
        // The store caches by id, so the stale (or placeholder) texture has to go before the rebind.
        textureStore?.evict(id)
        refreshTextureBindings()
        // Nothing in the source changed, so no classification would have asked for this — but the
        // missing-texture warnings are produced by generation, and one of them has just gone stale.
        scheduleCompile()
        return true
    }

    // MARK: Nodes

    /// Points `node`'s `asset` parameter at `asset` (or at nothing).
    public func assignAsset(_ asset: AssetID?, to node: NodeID) {
        apply(.setParam(node, "asset", .asset(asset)))
    }

    /// A canvas image drop: import the bytes and place a Texture Sample already pointing at them,
    /// as one undo step. Nil (and nothing applied) when the data is not an image.
    @discardableResult
    public func addTextureNode(imageData: Data, name: String, at point: CGPoint) -> NodeID? {
        beginTransaction("Add Texture")
        defer { endTransaction() }                  // registers nothing when the import was refused
        guard let asset = importImage(data: imageData, name: name),
              let node = addNode(defID: "texture.sample", at: point) else { return nil }
        assignAsset(asset, to: node)
        return node
    }

    /// The same, for a file dropped on the canvas. Non-file URLs (a link dragged out of a browser)
    /// and unreadable files are refused rather than fetched.
    @discardableResult
    public func addTextureNode(contentsOf url: URL, at point: CGPoint) -> NodeID? {
        guard url.isFileURL else { return nil }
        // A drop from the Finder arrives with a sandbox extension that has to be claimed before the
        // read; a URL from our own open panel is already accessible and simply says no here.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return addTextureNode(imageData: data, name: url.lastPathComponent, at: point)
    }

    // MARK: Manifest

    /// Whether any node in any graph points at `asset` — what gates removal (spec §21.1).
    public func isAssetReferenced(_ asset: AssetID) -> Bool {
        func references(_ graph: Graph) -> Bool {
            graph.nodes.values.contains { $0.params.values.contains(.asset(asset)) }
        }
        return references(document.root) || document.definitions.values.contains { references($0.graph) }
    }

    /// Drops the manifest entry and the bytes. Refused, with a notice, while any node still points
    /// at the asset: the inspector disables the button, this is the guard behind it.
    @discardableResult
    public func removeAsset(_ asset: AssetID) -> Bool {
        guard document.settings.assets[asset] != nil else { return false }
        guard !isAssetReferenced(asset) else {
            showNotice("That image is still in use")
            return false
        }
        var settings = document.settings
        settings.assets[asset] = nil
        beginTransaction("Remove Asset")
        apply(.setSettings(settings))
        endTransaction()
        textures[asset] = nil
        textureStore?.evict(asset)
        return true
    }

    // MARK: Decoding

    /// The image's size in pixels, or nil when no installed decoder recognises the bytes.
    /// ImageIO only reads the header here — the pixels are decoded on the GPU path by `TextureStore`.
    private func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// What `textures/<AssetID>.<ext>` is written as: the file's own extension, lowercased, and
    /// `png` for a name that carries none (controller ruling).
    private func fileExtension(of name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext.isEmpty ? "png" : ext
    }
}
