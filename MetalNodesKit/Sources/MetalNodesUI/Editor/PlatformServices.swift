import Foundation
import MetalNodesCore

/// The bytes of a chosen image and the file name they came in under (spec §22.4). The bytes travel,
/// not the URL: a panel's or a picker's grant covers the URL only while the caller holds it, and
/// the import copies the bytes into the package anyway.
public struct PickedImage: Sendable, Equatable {
    public let data: Data
    public let name: String
    public init(data: Data, name: String) {
        self.data = data
        self.name = name
    }
}

/// Where the user is asked for an image. The Mac has one open panel and ignores this; the iPad
/// offers Photos and Files as two separate buttons (spec §22.4).
public enum ImageSource: Sendable, CaseIterable {
    case files, photos
}

/// The image well's "Choose…" and the Assets list's "Relink…", behind a protocol so both are
/// testable in memory — the `Pasteboarding` pattern (spec §18.4) applied to the picker.
@MainActor
public protocol ImageChooser: AnyObject {
    /// The chosen bytes, or nil when the user cancelled, the file was unreadable, or a chooser is
    /// already on screen (a second request never stacks a second panel).
    func choose(from source: ImageSource) async -> PickedImage?
}

/// What File ▸ Export Shader… ended up doing. `.failed` carries the message the alert shows.
public enum ExportOutcome: Sendable, Equatable {
    case saved, cancelled, failed(String)
}

/// File ▸ Export Shader…, behind a protocol: `NSSavePanel`/`NSOpenPanel` on the Mac, `fileExporter`
/// on the iPad, an in-memory recorder in the tests (spec §22.4).
@MainActor
public protocol Exporter: AnyObject {
    /// `name` is the base name the destination should take — the folder for a stitchable target's
    /// file pair. Implementations that ask the system for a destination (both panels) may ignore it.
    func export(files: [ExportFile], name: String) async -> ExportOutcome
}

// MARK: Test doubles

/// Hands out `next` and records what it was asked for.
@MainActor
public final class MemoryImageChooser: ImageChooser {
    /// What the next `choose(from:)` returns. Nil is a cancel.
    public var next: PickedImage?
    public private(set) var requests: [ImageSource] = []

    public init(next: PickedImage? = nil) { self.next = next }

    public func choose(from source: ImageSource) async -> PickedImage? {
        requests.append(source)
        return next
    }
}

/// Records every export and answers `outcome`.
@MainActor
public final class MemoryExporter: Exporter {
    public var outcome: ExportOutcome = .saved
    public private(set) var exported: [(files: [ExportFile], name: String)] = []

    public init() {}

    public func export(files: [ExportFile], name: String) async -> ExportOutcome {
        exported.append((files, name))
        return outcome
    }
}

// MARK: Injection

/// The services one editor window runs with, injected through `EditorView`'s initializer so a test
/// (or a preview) can hand it doubles instead of panels.
@MainActor
public struct EditorServices {
    public var imageChooser: any ImageChooser
    public var exporter: any Exporter
    /// Where a finished recording is put (spec §26.5). Defaulted so every call site that predates
    /// M10 still compiles; the tests hand it `MemoryRecordingDestination` explicitly.
    public var recordingDestination: any RecordingDestination

    public init(imageChooser: any ImageChooser, exporter: any Exporter,
                recordingDestination: any RecordingDestination = MemoryRecordingDestination()) {
        self.imageChooser = imageChooser
        self.exporter = exporter
        self.recordingDestination = recordingDestination
    }

    /// What the app runs with on this platform.
    public static var platform: EditorServices {
        #if os(macOS)
        EditorServices(imageChooser: ImagePanelMac(), exporter: ExportPanelMac(),
                       recordingDestination: RecordingPanelMac())
        #else
        EditorServices(imageChooser: ImageChooserPad(), exporter: ExporterPad(),
                       recordingDestination: RecordingDestinationPad())
        #endif
    }
}
