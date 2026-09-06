import SwiftUI
import MetalNodesCore

/// A comment frame (spec §21.4): a rounded rect filled with its accent at 12 %, a 1 pt border and
/// a 22 pt title bar. Only the chrome — that title bar and the 6 pt band inside the edge — takes
/// clicks, so the nodes it surrounds and the marquee keep working inside it.
struct FrameView: View {
    let frame: CommentFrame
    let isSelected: Bool
    let actions: CommentActions

    static let cornerRadius: CGFloat = 8

    var body: some View {
        let accent = DraculaTheme.token(for: frame.accent).color
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.cornerRadius).fill(accent.opacity(0.12))
            titleBar(accent)
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(isSelected ? DraculaTheme.selection.color : accent, lineWidth: isSelected ? 2 : 1)
        }
        .frame(width: frame.frame.width, height: frame.frame.height, alignment: .topLeading)
        // The hit region is the chrome only — the same test `EditorModel.frameHitsChrome` applies.
        .contentShape(FrameChrome(titleBar: EditorModel.frameTitleBarHeight,
                                  border: EditorModel.frameBorderWidth,
                                  cornerRadius: Self.cornerRadius), eoFill: true)
        .commentMove(isSelected: isSelected, actions: actions)
        // After the chrome shape, so the handle keeps its own (larger) grab in the corner.
        .overlay(alignment: .bottomTrailing) {
            if isSelected { CommentResizeHandle(actions: actions) }
        }
    }

    private func titleBar(_ accent: Color) -> some View {
        Text(frame.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: frame.frame.width, height: EditorModel.frameTitleBarHeight, alignment: .leading)
            .background(accent.opacity(0.12), in: UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius,
                                                                        topTrailingRadius: Self.cornerRadius))
    }
}

/// The frame's chrome as one even-odd path: the whole rect with its interior punched out. Filled
/// with `eoFill`, the hole is exactly the region `EditorModel.frameHitsChrome` reports as *not*
/// the frame — the canvas below the title bar and inside the border band.
///
/// `nonisolated` because `Shape` is: SwiftUI calls `path(in:)` off the main actor, so the module's
/// default isolation cannot follow the conformance. The measurements are passed in for the same
/// reason — `EditorModel`'s constants are main-actor state.
nonisolated struct FrameChrome: Shape {
    var titleBar: CGFloat
    var border: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: cornerRadius)
        let inner = CGRect(x: rect.minX + border, y: rect.minY + titleBar,
                           width: rect.width - 2 * border, height: rect.height - titleBar - border)
        if inner.width > 0, inner.height > 0 { p.addRect(inner) }
        return p
    }
}
