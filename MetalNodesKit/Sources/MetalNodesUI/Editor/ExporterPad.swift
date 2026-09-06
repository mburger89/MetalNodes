#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Observation
import MetalNodesCore

/// Which document `fileExporter` is being handed. A stitchable target's file pair goes out as one
/// folder; the fragment target's single `.metal` goes out as itself (spec §22.4).
public enum ExportPadDocument: Sendable {
    case folder(ExportFolderDocument)
    case text(ExportTextDocument)
}

/// The iPad's File ▸ Export Shader… (spec §22.4): builds the document, raises the presenter, and
/// waits for `fileExporter`'s completion. `ExporterPadHost` is what actually presents it.
@Observable
public final class ExporterPad: Exporter {
    public let presenter = PickerPresenter<ExportOutcome>()
    /// What the host should present, and the file name it should default to. Nil between exports.
    public private(set) var pending: (document: ExportPadDocument, name: String)?

    public init() {}

    public func export(files: [ExportFile], name: String) async -> ExportOutcome {
        guard !presenter.isPending else { return .cancelled }
        guard let first = files.first else { return .failed("Nothing to export.") }
        // One file is exported as itself under its own name; a pair needs the folder, whose name is
        // the export name.
        pending = files.count == 1
            ? (.text(ExportTextDocument(file: first)), first.name)
            : (.folder(ExportFolderDocument(name: name, files: files)), name)
        let outcome = await presenter.request() ?? .cancelled
        pending = nil
        return outcome
    }

    /// The document the folder exporter presents, and nil while a text export is pending — the two
    /// `fileExporter` modifiers are told apart by these.
    public var folderDocument: ExportFolderDocument? {
        guard let pending, case .folder(let d) = pending.document else { return nil }
        return d
    }

    public var textDocument: ExportTextDocument? {
        guard let pending, case .text(let d) = pending.document else { return nil }
        return d
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

    /// The same files on disk, for the toolbar's `ShareLink` (Task 8). A share sheet takes URLs, not
    /// documents, so the files are written under `tmp/Exports/<uuid>/<name>/` — a fresh folder per
    /// share, so two shares never race over one path, and the system reclaims `tmp`.
    public func temporaryShareURLs(files: [ExportFile], name: String) throws -> [URL] {
        let directory = URL.temporaryDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files.map { file in
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            try Data(file.contents.utf8).write(to: url, options: .atomic)
            return url
        }
    }
}

/// Attaches the two exporters. Optional for the same reason `ImageChooserPadHost` is: the tests
/// inject `MemoryExporter`, and then this is a pass-through.
public struct ExporterPadHost: ViewModifier {
    let exporter: ExporterPad?

    public init(exporter: ExporterPad?) { self.exporter = exporter }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let exporter {
            attach(content, exporter)
        } else {
            content
        }
    }

    private func attach(_ content: Content, _ exporter: ExporterPad) -> some View {
        content
            .fileExporter(isPresented: isPresented(exporter, folder: true),
                          document: exporter.folderDocument,
                          contentTypes: [.folder],
                          defaultFilename: exporter.pending?.name,
                          onCompletion: { exporter.finish($0) },
                          onCancellation: { exporter.finish(.cancelled) })
            .fileExporter(isPresented: isPresented(exporter, folder: false),
                          document: exporter.textDocument,
                          contentTypes: [.sourceCode],
                          defaultFilename: exporter.pending?.name,
                          onCompletion: { exporter.finish($0) },
                          onCancellation: { exporter.finish(.cancelled) })
    }

    /// One presenter drives two modifiers, so each takes the flag only while *its* document is the
    /// pending one. The setter never resolves: `onCompletion` and `onCancellation` between them
    /// cover every dismissal, and resolving here would race a save with a `.cancelled`.
    private func isPresented(_ exporter: ExporterPad, folder: Bool) -> Binding<Bool> {
        Binding(get: { exporter.presenter.isPresented && (folder ? exporter.folderDocument != nil : exporter.textDocument != nil) },
                set: { if !$0 { exporter.presenter.isPresented = false } })
    }
}
#endif
