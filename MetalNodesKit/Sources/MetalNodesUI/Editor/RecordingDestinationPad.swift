#if os(iOS)
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The iPad's recording destination (spec §26.5): the session writes the video, the sequence folder
/// or the snapshot into a scratch directory, and this hands it to `fileExporter`, which asks the
/// user where it goes. Mirrors `ExporterPad` — the presenter bridges the `async place(_:kind:_:)`
/// call to the presentation modifier, and `RecordingDestinationPadHost` is what presents it.
@Observable
public final class RecordingDestinationPad: RecordingDestination {
    public let presenter = PickerPresenter<ExportOutcome>()
    /// What the host should present. Nil between recordings.
    public private(set) var pending: (wrapper: FileWrapper, name: String, isFolder: Bool)?

    public init() {}

    public func place(_ temporary: URL, kind: RecordingKind, suggestedName: String) async -> ExportOutcome {
        guard !presenter.isPending else { return .cancelled }
        let wrapper: FileWrapper
        do {
            // `.immediate` reads the bytes now, while the scratch directory is still there: the
            // recording removes it as soon as this call returns.
            wrapper = try FileWrapper(url: temporary, options: .immediate)
        } catch {
            return .failed(error.localizedDescription)
        }
        wrapper.preferredFilename = suggestedName
        pending = (wrapper, suggestedName, kind.isFolder)
        let outcome = await presenter.request() ?? .cancelled
        pending = nil
        return outcome
    }

    /// The type `fileExporter` writes: the folder for a sequence, else the file's own type.
    var contentType: UTType {
        guard let pending else { return .data }
        if pending.isFolder { return .folder }
        return pending.name.hasSuffix(".mp4") ? .mpeg4Movie : .png
    }

    /// Ends the presentation with `outcome` and drops the document.
    func finish(_ outcome: ExportOutcome) {
        pending = nil
        presenter.resolve(outcome)
    }

    /// `fileExporter`'s completion, mapped onto the outcome the alert reads.
    func finish(_ result: Result<URL, any Error>) {
        switch result {
        case .success: finish(.saved)
        case .failure(let error): finish(.failed(error.localizedDescription))
        }
    }
}

/// The one wrapper `fileExporter` writes, whatever the recording was: a `.mp4`, a `.png` or the
/// sequence's directory. `nonisolated` because SwiftUI calls `FileDocument` off the main actor,
/// and this module's default isolation is `MainActor`.
nonisolated struct RecordingFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .mpeg4Movie, .folder] }

    /// Already read into memory by `RecordingDestinationPad.place(_:kind:suggestedName:)`.
    let wrapper: FileWrapper

    init(wrapper: FileWrapper) { self.wrapper = wrapper }

    /// Export-only: nothing in the app opens one of these back.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }
}

/// Attaches the recording exporter. Optional for the same reason `ExporterPadHost` is: the tests
/// inject `MemoryRecordingDestination`, and then this is a pass-through.
public struct RecordingDestinationPadHost: ViewModifier {
    let destination: RecordingDestinationPad?

    public init(destination: RecordingDestinationPad?) { self.destination = destination }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let destination {
            attach(content, destination)
        } else {
            content
        }
    }

    /// The plural `contentTypes:` overload, because it is the one that also reports a cancellation
    /// — without that callback the awaiting `place(_:kind:suggestedName:)` would never resume.
    private func attach(_ content: Content, _ destination: RecordingDestinationPad) -> some View {
        content.fileExporter(isPresented: isPresented(destination),
                             document: destination.pending.map { RecordingFileDocument(wrapper: $0.wrapper) },
                             contentTypes: [destination.contentType],
                             defaultFilename: destination.pending?.name,
                             onCompletion: { destination.finish($0) },
                             onCancellation: { destination.finish(.cancelled) })
    }

    /// The modifier takes the flag only while a document is actually pending. The setter never
    /// resolves: `onCompletion` and `onCancellation` between them cover every dismissal, and
    /// resolving here would race a save with a `.cancelled` — the shape `ExporterPadHost` uses.
    private func isPresented(_ destination: RecordingDestinationPad) -> Binding<Bool> {
        Binding(get: { destination.presenter.isPresented && destination.pending != nil },
                set: { if !$0 { destination.presenter.isPresented = false } })
    }
}
#endif
