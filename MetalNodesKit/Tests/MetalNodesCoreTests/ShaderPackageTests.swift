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
        text = text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
            .replacingOccurrences(of: "\"formatVersion\": 1", with: "\"formatVersion\": 99")
        wrapper.removeFileWrapper(wrapper.fileWrappers!["document.json"]!)
        wrapper.addRegularFile(withContents: Data(text.utf8), preferredFilename: "document.json")
        #expect(throws: PackageError.newerFormat(99)) { try ShaderPackage(fileWrapper: wrapper) }
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
