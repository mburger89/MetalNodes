import Foundation

/// What File ▸ Export Video… / Export Image Sequence… / Snapshot PNG… produce (spec §26.5).
public enum RecordingKind: Sendable, CaseIterable, Equatable {
    case video, imageSequence, snapshot

    public var title: String {
        switch self {
        case .video: "Export Video"
        case .imageSequence: "Export Image Sequence"
        case .snapshot: "Snapshot PNG"
        }
    }
    /// A video and a snapshot are one file; a sequence is a folder.
    public var isFolder: Bool { self == .imageSequence }
    public var fileExtension: String { self == .video ? "mp4" : "png" }
}

/// Moves a finished recording from its temporary location to where the user wants it: save/open
/// panels on the Mac, `fileExporter` on the iPad, a recorder in tests. The session renders to a
/// temporary URL first so rendering never needs a security-scoped grant (spec §26.5).
@MainActor
public protocol RecordingDestination: AnyObject {
    /// `temporary` is a file (video, snapshot) or a directory (sequence); the implementation moves
    /// or copies it and may ignore `suggestedName`.
    func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome
}

/// Records every placement and answers `outcome` — the recording half of `MemoryExporter`.
///
/// Like the real destinations it *moves* what it is handed out of the scratch directory, into one
/// of its own under `tmp`: the recording removes the scratch as soon as `place` returns, so a
/// double that only noted the temporary URL would hand its caller a path to a deleted file.
@MainActor
public final class MemoryRecordingDestination: RecordingDestination {
    public var outcome: ExportOutcome = .saved
    /// Where each recording ended up, in the order it was placed.
    public private(set) var placed: [(url: URL, kind: RecordingKind, suggestedName: String)] = []
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetalNodes-recorded-\(UUID().uuidString)")

    public init() {}

    public func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome {
        let kept = root.appendingPathComponent(suggestedName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: kept)
        } catch {
            return .failed(error.localizedDescription)
        }
        placed.append((kept, kind, suggestedName))
        return outcome
    }

    /// Removes everything this double kept. The tests that read a placed file call it in a `defer`.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
