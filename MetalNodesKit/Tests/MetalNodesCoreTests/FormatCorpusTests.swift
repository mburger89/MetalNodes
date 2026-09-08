import Foundation
import Testing
@testable import MetalNodesCore

/// The backward-compatibility gate (handoff §15.5 item 1).
///
/// `Fixtures/formatVersion1/` holds nine `.mnshader` packages written by the M7 encoder at
/// `ddc6527`, the commit before M8. Every later build must open them and generate exactly the
/// bytes recorded beside each one. Nothing here may be re-saved with the current encoder —
/// `fixturesAreStillFormatVersion1` guards that — but a golden **may** be replaced when codegen
/// changes on purpose; the commit that does so is the record of the change.
///
/// What the goldens record:
/// - The six Fragment/SwiftUI documents: bytes identical to what the M7 build produced.
/// - `matGroup` and `realityKitMaterial`: M8 output. M8 added four Material Output sockets
///   (clearcoat, clearcoat roughness, clearcoat normal, custom attribute), which renumbers the
///   preview's uniform fields, adds a `customAttribute` interpolant, and extends the export header.
///   The M7 bytes are kept in `m7-baseline/` so the delta stays inspectable.
/// - `matAspect`: refused. An aspect-mode UV under RealityKit was accepted by M7 and is refused by
///   M8 (spec §24.10, handoff §15.5 item 4). `aspectUVUnderRealityKitIsRefused` pins the message.
@Suite struct FormatCorpusTests {
    static let openable = ["fragmentSys", "matGroup", "realityKitMaterial", "sample",
                           "sampleWithGroup", "starter", "stitchGroup", "textured"]
    static let refused = ["matAspect"]
    static var corpusNames: [String] { openable + refused }

    static var corpus: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
                .appendingPathComponent("formatVersion1")
        }
    }

    static func package(_ name: String) throws -> ShaderPackage {
        let url = try corpus.appendingPathComponent("\(name).mnshader")
        return try ShaderPackage(fileWrapper: FileWrapper(url: url))
    }

    static func expected(_ file: String) throws -> String {
        try String(contentsOf: corpus.appendingPathComponent(file), encoding: .utf8)
    }

    static func goldens(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: corpus.path)
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".mnshader") }
    }

    @Test func corpusIsComplete() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.corpus.path)
            .filter { $0.hasSuffix(".mnshader") }
            .map { String($0.dropLast(".mnshader".count)) }
        #expect(names.sorted() == Self.corpusNames.sorted())
    }

    /// If this fails, someone re-saved a fixture with the current encoder and the corpus no longer
    /// tests what it claims to. Restore the file from git; never regenerate it.
    @Test(arguments: corpusNames) func fixturesAreStillFormatVersion1(_ name: String) throws {
        let json = try Data(contentsOf: Self.corpus.appendingPathComponent("\(name).mnshader/document.json"))
        struct Probe: Decodable { let formatVersion: Int }
        #expect(try JSONDecoder().decode(Probe.self, from: json).formatVersion == 1)
        #expect(ShaderDocument.currentFormatVersion > 1)
    }

    @Test(arguments: corpusNames) func decodes(_ name: String) throws {
        let pkg = try Self.package(name)
        #expect(pkg.missingTextures.isEmpty)
        #expect(!pkg.document.root.nodes.isEmpty)
    }

    @Test(arguments: openable) func opensWithoutDiagnostics(_ name: String) throws {
        let doc = try Self.package(name).document
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
        #expect(diags.isEmpty, Comment(rawValue: "\(name): \(diags)"))
    }

    @Test(arguments: openable) func previewMSLIsByteIdentical(_ name: String) throws {
        let doc = try Self.package(name).document
        let shader = try ShaderGenerator.generate(doc, target: doc.settings.target)
        #expect(shader.source == (try Self.expected("\(name).preview.metal")), Comment(rawValue: name))
    }

    @Test(arguments: openable) func exportFilesAreByteIdentical(_ name: String) throws {
        let doc = try Self.package(name).document
        let files = try ShaderExport.files(for: doc)
        let onDisk = try Self.goldens(prefix: "\(name).export.").map { String($0.dropFirst("\(name).export.".count)) }
        #expect(Set(files.map(\.name)) == Set(onDisk), Comment(rawValue: name))
        for f in files {
            #expect(f.contents == (try Self.expected("\(name).export.\(f.name)")), Comment(rawValue: "\(name)/\(f.name)"))
        }
    }

    /// Spec §24.10 reverses §23.10: aspect-mode UV needs `resolution`, which a RealityKit material
    /// cannot supply, so the document is refused rather than silently degraded. The message is
    /// pinned here because handoff §15.5 item 4 owes it an actionable hint (switch UV to
    /// Normalized); changing the message means updating this line on purpose.
    @Test(arguments: refused) func aspectUVUnderRealityKitIsRefused(_ name: String) throws {
        let doc = try Self.package(name).document
        #expect(doc.settings.target == .realityKit)
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(diags.count == 1)
        #expect(diags.first?.severity == .error)
        #expect(diags.first?.message == "UV reads resolution, which the RealityKit Material target does not provide — this node needs the Fragment (preview) or SwiftUI target")
        #expect(diags.first?.node != nil)
        #expect(try Self.goldens(prefix: "\(name).").isEmpty, "a refused document has no goldens")
    }

    /// The other direction: a document from a future format is refused with the message a person
    /// can act on, not "The shader could not be read".
    @Test func newerFormatIsRefusedByName() throws {
        let url = try Self.corpus.appendingPathComponent("starter.mnshader")
        let wrapper = try FileWrapper(url: url)
        let docWrapper = try #require(wrapper.fileWrappers?[ShaderPackage.documentFileName])
        var json = String(decoding: try #require(docWrapper.regularFileContents), as: UTF8.self)
        let future = ShaderDocument.currentFormatVersion + 1
        json = json.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : \(future)")
        wrapper.removeFileWrapper(docWrapper)
        wrapper.addRegularFile(withContents: Data(json.utf8), preferredFilename: ShaderPackage.documentFileName)
        #expect(throws: PackageError.newerFormat(future)) { try ShaderPackage(fileWrapper: wrapper) }
        #expect(PackageError.newerFormat(future).errorDescription
                == "This shader was saved by a newer version of MetalNodes")
    }
}
