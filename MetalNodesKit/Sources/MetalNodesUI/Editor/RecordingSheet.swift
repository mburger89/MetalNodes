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
            if kind == .video, width % 2 != 0 || height % 2 != 0 {
                Text("H.264 needs even dimensions; the video will be \(width + width % 2) × \(height + height % 2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Record") { onRecord(CGSize(width: max(width, 1), height: max(height, 1))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { width = max(Int(initialSize.width), 1); height = max(Int(initialSize.height), 1) }
    }
}

/// "Frame k of N" with Cancel.
struct RecordingProgressSheet: View {
    let progress: RecordingProgress?
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress?.frame ?? 0), total: Double(max(progress?.frameCount ?? 1, 1)))
            Text(progress.map { "Frame \($0.frame) of \($0.frameCount)" } ?? "Preparing…").font(.caption.monospacedDigit())
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(20)
        .frame(width: 280)
    }
}
