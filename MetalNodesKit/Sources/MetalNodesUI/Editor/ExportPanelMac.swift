#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MetalNodesCore

/// File ▸ Export Shader…. A single `.metal` file uses a save panel. A stitchable target's `.metal` +
/// `.swift` pair needs a folder picker instead: under App Sandbox with the user-selected-files
/// entitlement, a save panel's write grant covers only the exact URL the user picked — writing a
/// second file beside it fails with "You don't have permission…" (confirmed by hand). Picking a
/// folder via an open panel grants access to the whole directory, so both files can be written there.
public final class ExportPanelMac: Exporter {
    public init() {}

    /// `name` is the iPad's folder name; the panels ask the user for the destination themselves.
    public func export(files: [ExportFile], name: String) async -> ExportOutcome { runPanels(files: files) }

    func runPanels(files: [ExportFile]) -> ExportOutcome {
        guard let metal = files.first(where: { $0.name.hasSuffix(".metal") }) else { return .failed("Nothing to export.") }
        guard let swift = files.first(where: { $0.name.hasSuffix(".swift") }) else {
            return runSingleFile(metal)
        }
        return runFolder(metal: metal, swift: swift)
    }

    private func runSingleFile(_ metal: ExportFile) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = metal.name
        panel.allowedContentTypes = [UTType(filenameExtension: "metal") ?? .sourceCode]
        panel.canCreateDirectories = true
        panel.title = "Export Shader"
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try metal.contents.write(to: url, atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runFolder(metal: ExportFile, swift: ExportFile) -> ExportOutcome {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export Shader"
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(metal.name) and \(swift.name)."
        guard panel.runModal() == .OK, let dir = panel.url else { return .cancelled }
        // An open panel grants the folder, so nothing warns about replacing what is already there
        // the way a save panel would — ask before clobbering.
        let existing = [metal.name, swift.name].filter {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        if !existing.isEmpty, !confirmReplace(existing) { return .cancelled }
        do {
            try metal.contents.write(to: dir.appendingPathComponent(metal.name), atomically: true, encoding: .utf8)
            try swift.contents.write(to: dir.appendingPathComponent(swift.name), atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True when the user chose Replace.
    private func confirmReplace(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace existing files?"
        alert.informativeText = names.count == 1
            ? "“\(names[0])” already exists in this folder. Replacing it overwrites its current contents."
            : "\(names.joined(separator: " and ")) already exist in this folder. Replacing them overwrites their current contents."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
