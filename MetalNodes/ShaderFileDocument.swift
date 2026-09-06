import SwiftUI
import UniformTypeIdentifiers
import MetalNodesCore

nonisolated extension UTType {
    /// The `.mnshader` package (spec §21.1). Exported by this app — see the target's Info.plist.
    static let metalNodesShader = UTType(exportedAs: "com.maxburger.metalnodes.shader")
}

/// The `DocumentGroup`'s document: a thin `FileDocument` over `ShaderPackage`, which owns the
/// whole read/write story (spec §21.1). Reading maps a `PackageError` straight through, so the
/// standard open panel shows its `errorDescription`.
nonisolated struct ShaderFileDocument: FileDocument {
    static let readableContentTypes = [UTType.metalNodesShader]

    var package: ShaderPackage

    init(package: ShaderPackage) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        package = try ShaderPackage(fileWrapper: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try package.fileWrapper()
    }
}
