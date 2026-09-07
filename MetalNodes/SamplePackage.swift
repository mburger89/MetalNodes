import Foundation
import MetalNodesCore

/// Help ▸ Open Sample Shader (macOS), spec §22.4. Each sample is written to a fresh temporary
/// package and opened as an ordinary document, so editing it never touches anything the user
/// owns. On iPad the same packages are files in On My iPad › MetalNodes (`installIntoDocuments`),
/// so both platforms open the identical graphs.
enum SamplePackage {
    static func writeTemporary(_ document: ShaderDocument = .sample(), filename: String = "Sample.mnshader") throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: "Samples/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename)
        try ShaderPackage(document: document).fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    #if os(iOS)
    /// Writes `Documents/<filename>` — On My iPad › MetalNodes, where the launch screen's browser
    /// lists it — unless one is already there: a copy the user has edited is theirs to keep. A
    /// failure here costs the sample, not the app, so it is not reported.
    static func installIntoDocuments(_ document: ShaderDocument = .sample(), filename: String = "Sample.mnshader") {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true) else { return }
        let url = documents.appending(path: filename)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? ShaderPackage(document: document).fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
    }
    #endif
}
