import SwiftUI
import MetalNodesCore

/// A sticky note (spec §21.4): an accent-tinted card with its text in `foreground`, 8 pt of
/// padding, wrapping inside the note's rect. The whole card takes clicks and drags.
struct StickyView: View {
    let note: StickyNote
    let isSelected: Bool
    let actions: CommentActions

    static let cornerRadius: CGFloat = 6
    static let padding: CGFloat = 8

    var body: some View {
        let accent = DraculaTheme.token(for: note.accent).color
        Text(note.text)
            .font(.caption)
            .foregroundStyle(DraculaToken.foreground.color)
            .multilineTextAlignment(.leading)
            .padding(Self.padding)
            .frame(width: note.frame.width, height: note.frame.height, alignment: .topLeading)
            .background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .stroke(isSelected ? DraculaTheme.selection.color : accent.opacity(0.6),
                            lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(Rectangle())
            .commentMove(isSelected: isSelected, actions: actions)
            .overlay(alignment: .bottomTrailing) {
                if isSelected { CommentResizeHandle(actions: actions) }
            }
    }
}
