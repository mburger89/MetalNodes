#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Foundation
import Observation

/// The iPad's image well chooser (spec §22.4): "Photos…" opens a `PhotosPicker`, "Files…" a
/// document picker. Both are SwiftUI presentation modifiers, so the chooser holds one
/// `PickerPresenter` each and `EditorView` attaches `ImageChooserPadHost` once for the whole window.
///
/// `PhotosPicker` needs no usage description and no authorization: the picker runs out of process
/// and hands back only what the user chose.
@Observable
public final class ImageChooserPad: ImageChooser {
    public let photos = PickerPresenter<PickedImage>()
    public let files = PickerPresenter<PickedImage>()

    public init() {}

    public func choose(from source: ImageSource) async -> PickedImage? {
        switch source {
        case .photos: await photos.request()
        case .files: await files.request()
        }
    }
}

/// Attaches both pickers. Takes an optional so `EditorView` can hand it
/// `services.imageChooser as? ImageChooserPad` — nil for the in-memory double, and then this is a
/// pass-through.
public struct ImageChooserPadHost: ViewModifier {
    let chooser: ImageChooserPad?
    @State private var photoItem: PhotosPickerItem?
    /// A photo's bytes arrive asynchronously, *after* the picker has already dismissed itself. The
    /// dismissal must not be read as a cancel while this is true.
    @State private var loadingPhoto = false

    public init(chooser: ImageChooserPad?) { self.chooser = chooser }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let chooser {
            attach(content, chooser)
        } else {
            content
        }
    }

    private func attach(_ content: Content, _ chooser: ImageChooserPad) -> some View {
        @Bindable var photos = chooser.photos
        @Bindable var files = chooser.files
        return content
            .photosPicker(isPresented: $photos.isPresented, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                loadingPhoto = true
                Task { @MainActor in
                    let picked = await load(item)
                    photoItem = nil
                    loadingPhoto = false
                    chooser.photos.resolve(picked)
                }
            }
            .onChange(of: chooser.photos.isPresented) { _, presented in
                // `PhotosPicker` has no cancel callback: a dismissal with nothing loading is the
                // user backing out, and the awaiting `choose(from:)` has to be resumed. But a pick
                // sets `photoItem` and `isPresented` in the same dismissal, and SwiftUI gives no
                // ordering guarantee between these two independent `onChange` handlers — if this one
                // ran first, `photoItem` (and `loadingPhoto`) would still read as "nothing chosen"
                // even though a selection is already on its way. Yield one main-actor turn first so
                // a same-transaction `photoItem` update has landed, then re-check both flags — and
                // that the request is even still pending — before treating the dismissal as a cancel.
                guard !presented else { return }
                Task { @MainActor in
                    await Task.yield()
                    if photoItem == nil, !loadingPhoto, chooser.photos.isPending {
                        chooser.photos.resolve(nil)
                    }
                }
            }
            .fileImporter(isPresented: $files.isPresented,
                          allowedContentTypes: [.png, .jpeg, .heic],
                          allowsMultipleSelection: false) { result in
                chooser.files.resolve(picked(from: result))
            } onCancellation: {
                chooser.files.resolve(nil)
            }
    }

    /// The photo's original bytes. `Data` rather than `Image`: the import stores what the user
    /// picked verbatim, never a re-encode (spec §21.2). The name is the item's own type extension —
    /// a `PhotosPickerItem` carries no file name.
    private func load(_ item: PhotosPickerItem) async -> PickedImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
        return PickedImage(data: data, name: "Photo." + ext)
    }

    /// The picked file's bytes, read under the document picker's security-scoped grant — the same
    /// claim a Finder drop needs (see `EditorModel.addTextureNode(contentsOf:at:)`).
    private func picked(from result: Result<[URL], any Error>) -> PickedImage? {
        guard case .success(let urls) = result, let url = urls.first else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PickedImage(data: data, name: url.lastPathComponent)
    }
}
#endif
