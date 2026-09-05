#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MetalNodesCore

/// File ▸ Export Shader…. A single `.metal` file uses a save panel. A stitchable target's `.metal` +
/// `.swift` pair needs a folder picker instead: under App Sandbox with the user-selected-files
/// entitlement, a save panel's write grant covers only the exact URL the user picked — writing a
/// second file beside it fails with "You don't have permission…" (confirmed by hand). Picking a
/// folder via an open panel grants access to the whole directory, so both files can be written there.
enum ExportPanelMac {
    /// Returns an error message to show, or nil on success/cancel.
    static func run(files: [ExportFile]) -> String? {
        guard let metal = files.first(where: { $0.name.hasSuffix(".metal") }) else { return "Nothing to export." }
        guard let swift = files.first(where: { $0.name.hasSuffix(".swift") }) else {
            return runSingleFile(metal)
        }
        return runFolder(metal: metal, swift: swift)
    }

    private static func runSingleFile(_ metal: ExportFile) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = metal.name
        panel.allowedContentTypes = [UTType(filenameExtension: "metal") ?? .sourceCode]
        panel.canCreateDirectories = true
        panel.title = "Export Shader"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try metal.contents.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func runFolder(metal: ExportFile, swift: ExportFile) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export Shader"
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(metal.name) and \(swift.name)."
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        do {
            try metal.contents.write(to: dir.appendingPathComponent(metal.name), atomically: true, encoding: .utf8)
            try swift.contents.write(to: dir.appendingPathComponent(swift.name), atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
