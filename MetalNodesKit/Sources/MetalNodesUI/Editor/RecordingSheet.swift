import SwiftUI
import CoreGraphics
import MetalNodesCore
import MetalNodesRender

/// Width × height, with the timeline read-only, then Record (spec §26.5).
///
/// Deliberately reads nothing off `preview.clock`: the renderer rewrites the clock on every drawn
/// frame, and a sheet that observed it would re-lay itself out at refresh rate while it is up.
struct RecordingSizeSheet: View {
    let kind: RecordingKind
    let timeline: Timeline
    let initialSize: CGSize
    let onRecord: (CGSize) -> Void
    let onCancel: () -> Void
    @State private var width: Int = 512
    @State private var height: Int = 512

    /// What each kind can be rendered at (spec §27.6): H.264 has its own ceiling, well below the
    /// texture limit, and images a pixel budget — the sheet refuses the size here rather than
    /// letting the recording fail after the sheet is gone.
    static func isValid(kind: RecordingKind, width: Int, height: Int) -> Bool {
        kind == .video ? VideoSink.isSizeSupported(width: width, height: height)
                       : ExportSession.isSizeSupported(CGSize(width: width, height: height))
    }

    /// The caption under a refused size: it names the ceiling the user has just hit, and the two
    /// kinds do not share one.
    static func limitText(for kind: RecordingKind) -> String {
        kind == .video
            ? "H.264 video is limited to 8192 × 8192 and 35.6 megapixels."
            : "Width and height must be between 1 and \(ExportSession.maxDimension) px, and at most \(ExportSession.maxPixels) pixels together."
    }

    private var isValid: Bool { Self.isValid(kind: kind, width: width, height: height) }

    /// The remembered size arrives as a `CGFloat` and only ever seeds the fields, so it is clamped
    /// into range here — `Int(_:)` on its own traps on a non-finite value.
    private static func clamp(_ v: CGFloat) -> Int {
        guard v.isFinite else { return 1 }
        return Int(min(max(v.rounded(), 1), CGFloat(ExportSession.maxDimension)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.headline)
            HStack {
                Text("Size")
                TextField("W", value: $width, format: .number).frame(width: 70)
                Text("×")
                TextField("H", value: $height, format: .number).frame(width: 70)
                Text("px").foregroundStyle(.secondary)
            }
            if kind != .snapshot {
                Text("\(timeline.frameCount) frames — \(timeline.duration, format: .number.precision(.fractionLength(1))) s at \(timeline.frameRate) fps. Change these in the Document section.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isValid {
                Text(Self.limitText(for: kind))
                    .font(.caption).foregroundStyle(.red)
            } else if kind == .video, width % 2 != 0 || height % 2 != 0 {
                Text("H.264 needs even dimensions; the video will be \(width + width % 2) × \(height + height % 2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                // macOS binds Escape to `role: .cancel` only inside alerts and confirmation
                // dialogs, never a sheet — so the shortcut is spelled out (spec §27.6).
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Record") { onRecord(CGSize(width: width, height: height)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { width = Self.clamp(initialSize.width); height = Self.clamp(initialSize.height) }
    }
}

/// "Frame k of N" with Cancel.
struct RecordingProgressSheet: View {
    let progress: RecordingProgress?
    let onCancel: () -> Void

    /// How full the bar is, 0…1 — the whole of what the bar is told, so that `total` is the constant
    /// 1.0 for the life of the sheet. The first update the sheet ever draws is `nil` (the session has
    /// not reported a frame yet), and the pair `(value: 0, total: 1)` becoming `(value: 1, total: 240)`
    /// on the next update is the difference macOS's `ProgressView` was seen not to follow: the label
    /// counted frames while the fill stayed pinned at the left. A fraction against a fixed total is
    /// one number changing, which is the case the control does track.
    ///
    /// Clamped rather than trusted: `frame` is 1-based and never exceeds `frameCount`, but a bar is
    /// not the place to find out otherwise.
    static func fraction(_ progress: RecordingProgress?) -> Double {
        guard let p = progress, p.frameCount > 0 else { return 0 }
        return min(max(Double(p.frame) / Double(p.frameCount), 0), 1)
    }

    var body: some View {
        VStack(spacing: 12) {
            // `.linear` explicitly: `.automatic` in a sheet this small is free to resolve to the
            // circular indicator, and this one has a frame count to show.
            ProgressView(value: Self.fraction(progress))
                .progressViewStyle(.linear)
            Text(progress.map { "Frame \($0.frame) of \($0.frameCount)" } ?? "Preparing…").font(.caption.monospacedDigit())
            // Escape stops the recording; without the shortcut the mouse is the only way out.
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 280)
    }
}

/// An early failure — graph errors, a refused size, a writer that would not start — shown in the
/// sheet that is already up (spec §27.6). Dismissing the sheet and raising an alert in the same
/// update is exactly what SwiftUI drops, so the one sheet the flow owns carries the message.
struct RecordingFailedSheet: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export failed").font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
