import Foundation
import MetalNodesCore

/// What File ▸ New — and, on iPad, the document browser's Create Document — starts from. Normally
/// the starter graph; `-mnFixture <name>` on the command line swaps in a deterministic document so
/// the XCUITests can address nodes and sockets by their ids (spec §22.8). `UserDefaults` sees the
/// launch arguments through `NSArgumentDomain`, so no parsing is needed.
enum LaunchFixture {
    static func document() -> ShaderDocument {
        switch UserDefaults.standard.string(forKey: "mnFixture") {
        case "sample": .sample()
        case "textured": .textured()
        default: .starter()
        }
    }
}
