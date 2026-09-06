import Testing
import Foundation
import UniformTypeIdentifiers
import MetalNodesCore
@testable import MetalNodesUI

/// What `fileExporter` writes on the iPad (spec §22.4). `FileDocumentWriteConfiguration` has no
/// public initializer, so the tests go through `makeWrapper()` — the function the `FileDocument`
/// requirement forwards to.
@MainActor
@Suite struct ExportDocumentsTests {
    @Test func theFolderWrapperHoldsOneRegularFilePerExportFile() throws {
        let files = [ExportFile(name: "metalNodesShader.metal", contents: "// metal\n"),
                     ExportFile(name: "metalNodesShader.swift", contents: "// swift\n")]
        let wrapper = ExportFolderDocument(name: "metalNodesShader", files: files).makeWrapper()

        #expect(ExportFolderDocument.readableContentTypes == [.folder])
        #expect(wrapper.isDirectory)
        #expect(wrapper.preferredFilename == "metalNodesShader")
        let children = try #require(wrapper.fileWrappers)
        #expect(Set(children.keys) == Set(["metalNodesShader.metal", "metalNodesShader.swift"]))
        for file in files {
            let child = try #require(children[file.name])
            #expect(child.isRegularFile)
            #expect(child.preferredFilename == file.name)
            #expect(child.regularFileContents == Data(file.contents.utf8))
        }
    }

    @Test func theTextDocumentRoundTripsItsContents() throws {
        let file = ExportFile(name: "metalNodesShader.metal", contents: "#include <metal_stdlib>\nusing namespace metal;\n")
        let document = ExportTextDocument(file: file)
        #expect(ExportTextDocument.readableContentTypes == [.sourceCode])
        #expect(document.name == "metalNodesShader.metal")

        let wrapper = document.makeWrapper()
        #expect(wrapper.isRegularFile)
        #expect(wrapper.preferredFilename == "metalNodesShader.metal")
        let data = try #require(wrapper.regularFileContents)
        #expect(String(decoding: data, as: UTF8.self) == file.contents)
    }
}
