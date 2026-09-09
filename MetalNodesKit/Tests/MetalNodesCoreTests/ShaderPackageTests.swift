import Foundation
import CoreGraphics
import Testing
@testable import MetalNodesCore

@Suite struct ShaderPackageTests {
    private func png() -> Data { Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]) }   // bytes are opaque to the package

    @Test func roundTripsDocumentViewAndTextures() throws {
        var doc = ShaderDocument.sample()
        let a = AssetID()
        doc.settings.assets[a] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 4, height: 4), fileExtension: "png")
        var view = EditorViewState(); view.cameras[.root] = Camera(pan: CGSize(width: 3, height: 4), zoom: 2)
        let pkg = ShaderPackage(document: doc, viewState: view, textures: [a: png()])
        let wrapper = try pkg.fileWrapper()
        #expect(wrapper.isDirectory)
        #expect(Set(wrapper.fileWrappers!.keys) == ["document.json", "view.json", "textures"])
        #expect(wrapper.fileWrappers!["textures"]!.fileWrappers!.keys.contains("\(a.raw.uuidString.lowercased()).png"))
        let back = try ShaderPackage(fileWrapper: wrapper)
        #expect(back.document == doc)
        #expect(back.viewState == view)
        #expect(back.textures == [a: png()])
        #expect(back.missingTextures.isEmpty)
    }

    @Test func jsonIsSortedAndIndented() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        let text = String(decoding: wrapper.fileWrappers!["document.json"]!.regularFileContents!, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"definitions\""))
    }

    @Test func missingViewAndTexturesAreTolerated() throws {
        var doc = ShaderDocument.sample()
        let a = AssetID()
        doc.settings.assets[a] = AssetInfo(name: "gone.png", pixelSize: .zero, fileExtension: "png")
        let wrapper = try ShaderPackage(document: doc, viewState: EditorViewState(), textures: [:]).fileWrapper()
        wrapper.removeFileWrapper(wrapper.fileWrappers!["view.json"]!)
        let back = try ShaderPackage(fileWrapper: wrapper)
        #expect(back.viewState == EditorViewState())
        #expect(back.missingTextures == [a])
    }

    @Test func unreadableViewFallsBackButUnreadableDocumentFails() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        wrapper.removeFileWrapper(wrapper.fileWrappers!["view.json"]!)
        wrapper.addRegularFile(withContents: Data("nope".utf8), preferredFilename: "view.json")
        #expect(try ShaderPackage(fileWrapper: wrapper).viewState == EditorViewState())
        wrapper.removeFileWrapper(wrapper.fileWrappers!["document.json"]!)
        wrapper.addRegularFile(withContents: Data("nope".utf8), preferredFilename: "document.json")
        #expect(throws: PackageError.self) { try ShaderPackage(fileWrapper: wrapper) }
    }

    @Test func newerFormatIsRefused() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        var text = String(decoding: wrapper.fileWrappers!["document.json"]!.regularFileContents!, as: UTF8.self)
        // Spelled from the constant rather than the literal it happens to be, so bumping the
        // format version (M8 made it 2) cannot silently turn this rewrite into a no-op.
        let current = ShaderDocument.currentFormatVersion
        text = text.replacingOccurrences(of: "\"formatVersion\" : \(current)", with: "\"formatVersion\" : 99")
            .replacingOccurrences(of: "\"formatVersion\": \(current)", with: "\"formatVersion\": 99")
        wrapper.removeFileWrapper(wrapper.fileWrappers!["document.json"]!)
        wrapper.addRegularFile(withContents: Data(text.utf8), preferredFilename: "document.json")
        #expect(throws: PackageError.newerFormat(99)) { try ShaderPackage(fileWrapper: wrapper) }
    }

    @Test func aCorruptDocumentReportsTheReasonNotADump() throws {
        let a = NodeID()
        let json = """
        {"formatVersion":2,"settings":{},"definitions":[],"root":{"nodes":[
          {"id":"\(a.raw.uuidString)","kind":{"builtin":{"_0":"input.uv"}},"position":[0,0],"params":{},"collapsed":false},
          {"id":"\(a.raw.uuidString)","kind":{"builtin":{"_0":"input.uv"}},"position":[0,0],"params":{},"collapsed":false}],"edges":[]}}
        """
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            ShaderPackage.documentFileName: FileWrapper(regularFileWithContents: Data(json.utf8)),
        ])
        #expect(throws: PackageError.self) { try ShaderPackage(fileWrapper: wrapper) }
        do { _ = try ShaderPackage(fileWrapper: wrapper) } catch {
            #expect(error.errorDescription?.contains("duplicate node id") == true, "\(error)")
        }
    }

    @Test func anAssetExtensionIsSanitisedOnDecode() throws {
        let info = try JSONDecoder().decode(AssetInfo.self, from: Data(#"{"name":"x","pixelSize":[1,1],"fileExtension":"png/../y"}"#.utf8))
        #expect(info.fileExtension == "pngy")
        let empty = try JSONDecoder().decode(AssetInfo.self, from: Data(#"{"name":"x","pixelSize":[1,1],"fileExtension":"../"}"#.utf8))
        #expect(empty.fileExtension == "bin")
    }

    @Test func strayFilesAreIgnoredAndUnmanifestedTexturesDropped() throws {
        // `.sample()` mints fresh NodeIDs on every call, so a fresh document is captured once
        // and reused for both the package and the expectation rather than calling `.sample()` twice.
        let doc = ShaderDocument.sample()
        let wrapper = try ShaderPackage(document: doc, viewState: EditorViewState(), textures: [AssetID(): png()]).fileWrapper()
        #expect(wrapper.fileWrappers!["textures"]!.fileWrappers!.isEmpty)      // not in the manifest → not written
        wrapper.addRegularFile(withContents: Data(), preferredFilename: ".DS_Store")
        #expect(try ShaderPackage(fileWrapper: wrapper).document == doc)
    }
}
