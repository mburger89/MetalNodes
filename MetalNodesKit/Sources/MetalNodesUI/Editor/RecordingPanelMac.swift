#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// File ▸ Export Video… / Export Image Sequence… / Snapshot PNG… on the Mac (spec §26.5).
///
/// The session never renders into the chosen location: it writes into a scratch directory and this
/// moves the finished file (or folder) across afterwards. Under App Sandbox a save panel's write
/// grant covers only the exact URL the user picked — an `AVAssetWriter` writing there directly
/// would also need to create its own temporary siblings — and a folder of PNGs needs a directory
/// grant, which only an open panel gives. Moving once at the end needs neither.
public final class RecordingPanelMac: RecordingDestination {
    public init() {}

    public func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome {
        kind.isFolder ? placeFolder(temporary, suggestedName: suggestedName)
                      : placeFile(temporary, kind: kind, suggestedName: suggestedName)
    }

    private func placeFile(_ temporary: URL, kind: RecordingKind, suggestedName: String) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = kind == .video ? [.mpeg4Movie] : [.png]
        panel.canCreateDirectories = true
        panel.title = kind.title
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        // The save panel has already asked about replacing, so nothing asks a second time.
        return install(temporary, at: url)
    }

    private func placeFolder(_ temporary: URL, suggestedName: String) -> ExportOutcome {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = RecordingKind.imageSequence.title
        panel.prompt = "Export"
        panel.message = "Choose a folder for the image sequence."
        guard panel.runModal() == .OK, let dir = panel.url else { return .cancelled }
        let target = dir.appendingPathComponent(suggestedName)
        // An open panel grants the folder, so nothing warns about replacing what is already there
        // the way a save panel would — ask before clobbering, exactly as `ExportPanelMac` does.
        if FileManager.default.fileExists(atPath: target.path), !confirmReplace(suggestedName) {
            return .cancelled
        }
        return install(temporary, at: target)
    }

    /// Puts the finished recording at `url`, replacing whatever is there.
    ///
    /// `replaceItemAt` rather than remove-then-move: a move across volumes is a copy followed by a
    /// delete and can fail half way, and deleting first would then have destroyed the user's
    /// existing file with nothing to put in its place. `replaceItemAt` swaps atomically where it
    /// can and leaves the original untouched when it cannot. `moveItem` covers the (much more
    /// common) case where nothing is there to replace — `replaceItemAt` needs an original.
    private func install(_ temporary: URL, at url: URL) -> ExportOutcome {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True when the user chose Replace.
    private func confirmReplace(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace existing folder?"
        alert.informativeText = "“\(name)” already exists in this folder. Replacing it overwrites its current contents."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
