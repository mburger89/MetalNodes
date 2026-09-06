import Testing
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Sticky notes and comment frames: the changes, the geometry, and the ownership rules
/// of spec §11.5 / §21.4.
@MainActor
@Suite struct EditorCommentsTests {
    /// An empty root graph, so every node in it is one this test placed.
    private func model() -> EditorModel {
        let m = EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    /// `input.time` has no inputs and no params, so its frame is exactly 190 × 64.
    private func time(_ m: EditorModel, x: CGFloat, y: CGFloat) -> NodeID {
        m.addNode(defID: "input.time", at: CGPoint(x: x, y: y), select: false)!
    }

    // MARK: Changes

    @Test func commentChangesAreCosmeticAndCarryTheirUndoNames() {
        let s = StickyID(), f = FrameID()
        let note = StickyNote(id: s, text: "n", frame: .zero)
        let frame = CommentFrame(id: f, title: "t", frame: .zero)
        let changes: [DocumentChange] = [
            .addSticky(note), .updateSticky(s, text: "n", accent: .pink),
            .addFrame(frame), .updateFrame(f, title: "t", accent: .pink),
            .moveComments([.sticky(s): .zero]), .resizeComment(.sticky(s), .zero),
            .removeComments([.frame(f)]),
        ]
        #expect(changes.allSatisfy { $0.changeClass == .cosmetic })
        #expect(changes.map(\.undoName) == ["Add Note", "Edit Note", "Add Frame", "Edit Frame", "Move", "Resize", "Delete"])
    }

    @Test func addStickyPlacesA160x100NoteAndSelectsIt() {
        let m = model()
        let id = m.addSticky(at: CGPoint(x: 40, y: 60))
        let note = m.graph.stickies[id]
        #expect(note?.frame == CGRect(x: 40, y: 60, width: 160, height: 100))
        #expect(note?.text == "Note")
        #expect(note?.accent == .muted)
        #expect(m.selectedComments == [.sticky(id)])
        #expect(m.undoManager.undoActionName == "Add Note")
        m.undo()
        #expect(m.graph.stickies.isEmpty)
    }

    @Test func updateEditsTextTitleAndAccent() {
        let m = model()
        let s = m.addSticky(at: .zero)
        m.apply(.updateSticky(s, text: "hello", accent: .pink))
        #expect(m.graph.stickies[s]?.text == "hello")
        #expect(m.graph.stickies[s]?.accent == .pink)
        #expect(m.undoManager.undoActionName == "Edit Note")

        _ = time(m, x: 0, y: 0)
        m.selectAll()
        let f = m.frameSelection()!
        m.apply(.updateFrame(f, title: "Lighting", accent: .cyan))
        #expect(m.graph.frames[f]?.title == "Lighting")
        #expect(m.graph.frames[f]?.accent == .cyan)
        #expect(m.undoManager.undoActionName == "Edit Frame")
    }

    @Test func moveAndResizeRewriteTheCommentRect() {
        let m = model()
        let s = m.addSticky(at: CGPoint(x: 10, y: 10))
        m.apply(.moveComments([.sticky(s): CGPoint(x: 50, y: 70)]))
        #expect(m.graph.stickies[s]?.frame == CGRect(x: 50, y: 70, width: 160, height: 100))
        m.apply(.resizeComment(.sticky(s), CGRect(x: 50, y: 70, width: 200, height: 120)))
        #expect(m.graph.stickies[s]?.frame == CGRect(x: 50, y: 70, width: 200, height: 120))
    }

    // MARK: Frame Selection geometry

    @Test func frameSelectionSurroundsTheSelectionWithPaddingAndATitleBar() {
        let m = model()
        let a = time(m, x: 0, y: 0), b = time(m, x: 300, y: 200)
        m.select(nodes: [a, b], mode: .replace)
        let id = m.frameSelection()!
        // Nodes span (0,0)…(490,264); +24 pt padding all round, then 22 pt of title bar on top.
        #expect(m.graph.frames[id]?.frame == CGRect(x: -24, y: -46, width: 538, height: 334))
        #expect(m.graph.frames[id]?.title == "Frame")
        #expect(m.selectedComments == [.frame(id)])
        #expect(m.undoManager.undoActionName == "Add Frame")
    }

    @Test func frameSelectionRefusesAnEmptySelection() {
        let m = model()
        #expect(m.frameSelection() == nil)
        #expect(m.graph.frames.isEmpty)
    }

    // MARK: Ownership by geometry (spec §11.5)

    @Test func membersAreTheNodesWhoseCentreLiesInside() {
        let m = model()
        let inside = time(m, x: 0, y: 0)          // centre (95, 32)
        let straddling = time(m, x: 100, y: 0)    // centre (195, 32) — outside a 150-wide frame
        let f = CommentFrame(title: "F", frame: CGRect(x: -10, y: -10, width: 150, height: 150))
        m.apply(.addFrame(f))
        #expect(m.members(of: f.id) == [inside])
        #expect(!m.members(of: f.id).contains(straddling))
        #expect(m.members(of: FrameID()).isEmpty)
    }

    @Test func movingAFrameCarriesItsMembersInOneUndoStep() {
        let m = model()
        let inside = time(m, x: 0, y: 0)
        let outside = time(m, x: 600, y: 600)
        let f = CommentFrame(title: "F", frame: CGRect(x: -20, y: -20, width: 240, height: 200))
        m.apply(.addFrame(f))
        let before = m.document
        m.moveFrame(f.id, by: CGSize(width: 30, height: -15))
        #expect(m.graph.frames[f.id]?.frame == CGRect(x: 10, y: -35, width: 240, height: 200))
        #expect(m.graph.nodes[inside]?.position == CGPoint(x: 30, y: -15))
        #expect(m.graph.nodes[outside]?.position == CGPoint(x: 600, y: 600))
        #expect(m.undoManager.undoActionName == "Move Frame")
        m.undo()
        #expect(m.document == before)
    }

    @Test func movingAnEmptyFrameMovesOnlyTheFrame() {
        let m = model()
        let f = CommentFrame(title: "F", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        m.apply(.addFrame(f))
        m.moveFrame(f.id, by: CGSize(width: 5, height: 5))
        #expect(m.graph.frames[f.id]?.frame == CGRect(x: 5, y: 5, width: 100, height: 100))
        #expect(m.undoManager.undoActionName == "Move Frame")
    }

    // MARK: Selection

    @Test func selectingAndClearingCoversBothSets() {
        let m = model()
        let n = time(m, x: 0, y: 0)
        let s = m.addSticky(at: .zero)
        let f = CommentFrame(title: "F", frame: .zero)
        m.apply(.addFrame(f))

        m.selectComment(.frame(f.id), mode: .add)
        #expect(m.selectedComments == [.sticky(s), .frame(f.id)])
        m.selectComment(.sticky(s), mode: .toggle)
        #expect(m.selectedComments == [.frame(f.id)])
        m.selectComment(.sticky(s))                     // .replace
        #expect(m.selectedComments == [.sticky(s)])

        m.select(n)                                     // a node click replaces the whole selection
        #expect(m.selectedComments.isEmpty)
        m.selectComment(.sticky(s))
        #expect(m.selection.isEmpty)

        m.select(n, mode: .add)
        m.clearSelection()
        #expect(m.selection.isEmpty)
        #expect(m.selectedComments.isEmpty)
    }

    @Test func deleteRemovesSelectedNodesAndSelectedCommentsInOneStep() {
        let m = model()
        let n = time(m, x: 0, y: 0)
        let keep = time(m, x: 300, y: 0)
        let s = m.addSticky(at: .zero)
        let f = CommentFrame(title: "F", frame: .zero)
        m.apply(.addFrame(f))
        let before = m.document

        m.select(n)
        m.selectComment(.sticky(s), mode: .add)
        m.deleteSelection()
        #expect(m.graph.nodes.count == 1)
        #expect(m.graph.nodes[keep] != nil)
        #expect(m.graph.stickies.isEmpty)
        #expect(m.graph.frames[f.id] != nil)            // unselected comments stay
        #expect(m.selection.isEmpty)
        #expect(m.selectedComments.isEmpty)
        #expect(m.undoManager.undoActionName == "Delete")
        m.undo()
        #expect(m.document == before)
    }

    @Test func deletingOnlyCommentsStillWorks() {
        let m = model()
        let s = m.addSticky(at: .zero)
        m.deleteSelection()
        #expect(m.graph.stickies[s] == nil)
        #expect(m.selectedComments.isEmpty)
    }

    @Test func removingACommentDropsItFromTheSelection() {
        let m = model()
        let s = m.addSticky(at: .zero)
        m.apply(.removeComments([.sticky(s)]))
        #expect(m.selectedComments.isEmpty)
    }

    // MARK: Hit-testing

    @Test func stickiesHitOnTheirWholeRectAndBeatFrames() {
        let m = model()
        let f = CommentFrame(title: "F", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        m.apply(.addFrame(f))
        let s = m.addSticky(at: CGPoint(x: 100, y: 100))     // wholly inside the frame's interior
        #expect(m.comment(at: CGPoint(x: 150, y: 150)) == .sticky(s))
        #expect(m.comment(at: CGPoint(x: 259, y: 199)) == .sticky(s))
    }

    @Test func aFrameHitsOnItsTitleBarAndBorderButNotItsInterior() {
        let m = model()
        let f = CommentFrame(title: "F", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        m.apply(.addFrame(f))
        #expect(m.comment(at: CGPoint(x: 200, y: 10)) == .frame(f.id))     // title bar (22 pt)
        #expect(m.comment(at: CGPoint(x: 3, y: 150)) == .frame(f.id))      // left border band (6 pt)
        #expect(m.comment(at: CGPoint(x: 397, y: 150)) == .frame(f.id))    // right border band
        #expect(m.comment(at: CGPoint(x: 200, y: 297)) == .frame(f.id))    // bottom border band
        #expect(m.comment(at: CGPoint(x: 200, y: 150)) == nil)             // interior: nodes and marquee win
        #expect(m.comment(at: CGPoint(x: 500, y: 150)) == nil)             // outside
    }
}
