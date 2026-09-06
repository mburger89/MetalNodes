#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// The image well's "Choose…" (spec §21.2). Reads the bytes here rather than handing the URL back:
/// the panel's grant covers the URL only for as long as the caller holds it, and the import copies
/// the bytes into the package anyway.
enum ImagePanelMac {
    /// The chosen file's bytes and its file name, or nil when the user cancelled or it was unreadable.
    static func chooseImage() -> (data: Data, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Image"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return nil }
        return (data, url.lastPathComponent)
    }
}
#endif
