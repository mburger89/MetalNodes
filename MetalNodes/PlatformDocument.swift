import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The AppKit / UIKit document `DocumentGroup` keeps behind a `FileDocument`, reached for the one
/// thing SwiftUI gives no other way to say: "changed, but not an undo step". Both platforms track
/// changes through the window's undo manager, and a registration made only to mark a view-state
/// change would wipe the redo stack (spec §18.3); the change count is the right lever.
enum PlatformDocument {
    @MainActor
    static func markChanged(at url: URL?) {
        #if os(macOS)
        let document = url.flatMap { NSDocumentController.shared.document(for: $0) }
            ?? NSApp.keyWindow?.windowController?.document as? NSDocument
        document?.updateChangeCount(.changeDone)
        #else
        // `UIDocument` registers itself as a file presenter while it is open (that is how it
        // hears about outside edits), which is the one public list it appears in.
        guard let url else { return }
        let document = NSFileCoordinator.filePresenters.lazy
            .compactMap { $0 as? UIDocument }
            .first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
        document?.updateChangeCount(.done)
        #endif
    }
}
