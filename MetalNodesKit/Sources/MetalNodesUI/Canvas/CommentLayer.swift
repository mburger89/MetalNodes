import SwiftUI
import MetalNodesCore

/// What a comment view does back to the canvas. One value instead of four closures per view.
struct CommentActions {
    var select: (SelectionMode) -> Void
    /// `resizing`: the corner handle rather than the body.
    var dragBegan: (_ resizing: Bool) -> Void
    var drag: (CGSize) -> Void
    var dragEnded: () -> Void
}

/// Sticky notes and comment frames, drawn below the wires and the nodes (spec §21.4). Frames go
/// down first, then stickies, each in ascending id order — the order `EditorModel.comment(at:)`
/// resolves ties in, so the comment SwiftUI hands a click to is the one drawn on top.
struct CommentLayer: View {
    let graph: Graph
    let selected: Set<CommentID>
    /// Canvas-space cull rect (the viewport plus its margin), or nil before the viewport is known.
    let visible: CGRect?
    /// Comments whose view owns a live gesture: culling must not tear them down mid-drag, or
    /// SwiftUI cancels the drag without an `onEnded` and strands its undo transaction.
    let keeping: Set<CommentID>
    let onSelect: (CommentID, SelectionMode) -> Void
    let onDragBegan: (CommentID, Bool) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.id) { f in
                FrameView(frame: f, isSelected: selected.contains(.frame(f.id)), actions: actions(for: .frame(f.id)))
                    .offset(x: f.frame.minX, y: f.frame.minY)
            }
            ForEach(stickies, id: \.id) { s in
                StickyView(note: s, isSelected: selected.contains(.sticky(s.id)), actions: actions(for: .sticky(s.id)))
                    .offset(x: s.frame.minX, y: s.frame.minY)
            }
        }
    }

    private var frames: [CommentFrame] {
        graph.frames.values
            .filter { shows(.frame($0.id), $0.frame) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }

    private var stickies: [StickyNote] {
        graph.stickies.values
            .filter { shows(.sticky($0.id), $0.frame) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }

    private func shows(_ id: CommentID, _ rect: CGRect) -> Bool {
        keeping.contains(id) || visible.map { rect.intersects($0) } ?? true
    }

    private func actions(for id: CommentID) -> CommentActions {
        CommentActions(select: { onSelect(id, $0) },
                       dragBegan: { onDragBegan(id, $0) },
                       drag: onDrag,
                       dragEnded: onDragEnded)
    }
}

/// Click-to-select and drag-to-move, shared by both comment views. Mirrors `NodeView`'s header
/// drag: an unselected comment joins the selection before the drag snapshots its origins, and a
/// click on an already-selected one collapses (or toggles) the selection on release.
private struct CommentMove: ViewModifier {
    let isSelected: Bool
    let actions: CommentActions
    @State private var dragging = false
    @State private var wasSelectedAtStart = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        wasSelectedAtStart = isSelected
                        if !isSelected { actions.select(InputModifiers.selectionMode()) }
                        actions.dragBegan(false)
                    }
                    actions.drag(g.translation)
                }
                .onEnded { g in
                    let wasDragging = dragging
                    dragging = false
                    if wasDragging { actions.dragEnded() }
                    guard abs(g.translation.width) < 1, abs(g.translation.height) < 1, wasSelectedAtStart else { return }
                    let mode = InputModifiers.selectionMode()
                    if mode == .replace || mode == .toggle { actions.select(mode) }
                }
        )
    }
}

extension View {
    func commentMove(isSelected: Bool, actions: CommentActions) -> some View {
        modifier(CommentMove(isSelected: isSelected, actions: actions))
    }
}

/// The 12 pt corner grab that resizes a comment (spec §21.4). Drawn over the bottom-right corner
/// and above the body's own gesture, so the handle wins there.
struct CommentResizeHandle: View {
    let accent: Color
    let isSelected: Bool
    let actions: CommentActions
    @State private var resizing = false

    static let size: CGFloat = 12

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: Self.size, y: 0))
            p.addLine(to: CGPoint(x: Self.size, y: Self.size))
            p.addLine(to: CGPoint(x: 0, y: Self.size))
            p.closeSubpath()
        }
        .fill(isSelected ? DraculaTheme.selection.color.opacity(0.8) : accent.opacity(0.6))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !resizing {
                        resizing = true
                        actions.dragBegan(true)
                    }
                    actions.drag(g.translation)
                }
                .onEnded { _ in
                    if resizing { actions.dragEnded() }
                    resizing = false
                }
        )
        .accessibilityLabel("Resize")
    }
}
