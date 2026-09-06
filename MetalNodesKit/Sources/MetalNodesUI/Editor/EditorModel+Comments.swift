import CoreGraphics
import MetalNodesCore

/// Both kinds of comment addressed alike, so the changes that only touch a rect need one case
/// instead of two (spec §21.4).
extension Graph {
    subscript(comment id: CommentID) -> CGRect? {
        get {
            switch id {
            case .sticky(let s): stickies[s]?.frame
            case .frame(let f): frames[f]?.frame
            }
        }
        set {
            guard let newValue else { return }
            switch id {
            case .sticky(let s): stickies[s]?.frame = newValue
            case .frame(let f): frames[f]?.frame = newValue
            }
        }
    }

    mutating func remove(comment id: CommentID) {
        switch id {
        case .sticky(let s): stickies[s] = nil
        case .frame(let f): frames[f] = nil
        }
    }
}

/// Sticky notes and comment frames (spec §11.5, §21.4). Comments are document data — undoable,
/// carried by the clipboard — while their selection is view state.
extension EditorModel {
    /// A frame's title bar: the strip at the top of its rect that drags and hit-tests as the frame.
    public static let frameTitleBarHeight: CGFloat = 22
    /// The band inside a frame's edge that hit-tests as the frame. Everything further in belongs to
    /// the nodes and the marquee, so a frame never swallows the canvas it surrounds.
    public static let frameBorderWidth: CGFloat = 6
    public static let stickySize = CGSize(width: 160, height: 100)
    /// Slack between a framed selection's bounding box and the frame around it.
    public static let framePadding: CGFloat = 24

    public var selectedComments: Set<CommentID> {
        get { viewState.selectedComments }
        set { viewState.selectedComments = newValue }
    }

    // MARK: Creating

    /// Adds a 160 × 100 note whose top-left is `point`, and selects it.
    @discardableResult
    public func addSticky(at point: CGPoint) -> StickyID {
        let note = StickyNote(text: "Note", frame: CGRect(origin: point, size: Self.stickySize), accent: .muted)
        apply(.addSticky(note))
        selectComment(.sticky(note.id))
        return note.id
    }

    /// Frames the selected nodes: their bounding box plus 24 pt of padding, with the title bar
    /// added above it. `nil` when nothing is selected, which is what disables the menu item.
    @discardableResult
    public func frameSelection() -> FrameID? {
        guard let bounds = selectionBounds else { return nil }
        let padded = bounds.insetBy(dx: -Self.framePadding, dy: -Self.framePadding)
        let rect = CGRect(x: padded.minX, y: padded.minY - Self.frameTitleBarHeight,
                          width: padded.width, height: padded.height + Self.frameTitleBarHeight)
        let frame = CommentFrame(title: "Frame", frame: rect, accent: .muted)
        apply(.addFrame(frame))
        selectComment(.frame(frame.id))
        return frame.id
    }

    // MARK: Ownership by geometry (spec §11.5)

    /// The nodes a frame owns: those whose frame centre lies inside it. Never stored — a node
    /// dragged across the edge simply changes membership.
    public func members(of frame: FrameID) -> Set<NodeID> {
        guard let rect = graph.frames[frame]?.frame else { return [] }
        return Set(graph.nodes.keys.filter { id in
            guard let f = self.frame(of: id) else { return false }
            return rect.contains(CGPoint(x: f.midX, y: f.midY))
        })
    }

    /// Moves a frame and the nodes it owns by the same delta, as one undo step. Membership is
    /// read before the move, so the frame carries what it held when the drag began.
    public func moveFrame(_ id: FrameID, by delta: CGSize) {
        guard let rect = graph.frames[id]?.frame else { return }
        var moves: [NodeID: CGPoint] = [:]
        for member in members(of: id) {
            guard let p = graph.nodes[member]?.position else { continue }
            moves[member] = CGPoint(x: p.x + delta.width, y: p.y + delta.height)
        }
        beginTransaction("Move Frame")
        apply(.moveComments([.frame(id): CGPoint(x: rect.minX + delta.width, y: rect.minY + delta.height)]))
        if !moves.isEmpty { apply(.moveNodes(moves)) }
        endTransaction()
    }

    // MARK: Selection

    /// `.replace` takes over the whole selection, nodes included — clicking a comment deselects
    /// the nodes exactly as clicking a node deselects the comments.
    public func selectComment(_ id: CommentID, mode: SelectionMode = .replace) {
        selectedWire = nil
        switch mode {
        case .replace:
            selection = []
            selectedComments = [id]
        case .add: selectedComments.insert(id)
        case .toggle: selectedComments.formSymmetricDifference([id])
        }
    }

    /// Comment selection may only reference comments of the active graph, as node selection may
    /// only reference its nodes (spec §20.3).
    func pruneCommentSelection() {
        let g = graph
        viewState.selectedComments = viewState.selectedComments.filter { g[comment: $0] != nil }
    }

    // MARK: Hit-testing

    /// The comment under a canvas point. Stickies hit on their whole rect and win over frames;
    /// a frame hits only on its title bar or its border band, so nodes and the marquee keep
    /// working inside it (spec §21.4).
    public func comment(at point: CGPoint) -> CommentID? {
        let g = graph
        if let s = g.stickies.values.filter({ $0.frame.contains(point) }).max(by: Self.byID) {
            return .sticky(s.id)
        }
        if let f = g.frames.values.filter({ Self.frameHitsChrome($0.frame, at: point) }).max(by: Self.byID) {
            return .frame(f.id)
        }
        return nil
    }

    /// Whether `point` is on a frame's chrome rather than in the canvas it surrounds.
    static func frameHitsChrome(_ rect: CGRect, at point: CGPoint) -> Bool {
        guard rect.contains(point) else { return false }
        if point.y <= rect.minY + frameTitleBarHeight { return true }
        return !rect.insetBy(dx: frameBorderWidth, dy: frameBorderWidth).contains(point)
    }

    /// Overlapping comments resolve by id, so hit-testing is deterministic.
    private static func byID<T: Identifiable>(_ a: T, _ b: T) -> Bool where T.ID: CustomStringConvertible {
        a.id.description < b.id.description
    }
}
