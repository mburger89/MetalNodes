import SwiftUI
import UniformTypeIdentifiers
import MetalNodesCore

nonisolated extension UTType {
    /// The `.mnshader` package (spec §21.1). Exported by this app — see the target's Info.plist.
    static let metalNodesShader = UTType(exportedAs: "com.maxburger.metalnodes.shader")
}

/// The `DocumentGroup`'s document: a thin `FileDocument` over `ShaderPackage`, which owns the
/// whole read/write story (spec §21.1). Reading rewraps a `PackageError` as a Cocoa-domain error
/// carrying its `errorDescription` as the failure reason: AppKit's document machinery replaces any
/// other domain — and a Cocoa error's own description — with "The document could not be opened",
/// and only the failure reason and recovery suggestion survive into the alert. Until the in-app
/// checklist opened a format-3 file (item 13, 2026-09-08) the "saved by a newer version" message
/// had never reached a person.
nonisolated struct ShaderFileDocument: FileDocument {
    static let readableContentTypes = [UTType.metalNodesShader]

    var package: ShaderPackage

    init(package: ShaderPackage) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        do {
            package = try ShaderPackage(fileWrapper: configuration.file)
        } catch {
            // NSDocument rewrites a Cocoa file-read error's *description* to "The document could
            // not be opened." and appends the failure reason, so the message travels as the reason.
            let reason = error.errorDescription ?? String(describing: error)
            let suggestion: String = switch error {
            case .newerFormat: "Update MetalNodes to open it."
            default: "The package may be damaged or was not written by MetalNodes."
            }
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedFailureReasonErrorKey: reason + ".",
                NSLocalizedRecoverySuggestionErrorKey: suggestion,
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try package.fileWrapper()
    }
}
