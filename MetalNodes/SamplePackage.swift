import Foundation
import MetalNodesCore

/// Help ▸ Open Sample Shader (macOS) and the document toolbar's item (iPad), spec §22.4. The
/// sample is written to a fresh temporary package and opened as an ordinary document, so editing
/// it never touches anything the user owns and both platforms open the identical file.
enum SamplePackage {
    static func writeTemporary() throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: "Samples/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Sample.mnshader")
        try ShaderPackage(document: .sample()).fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }
}
