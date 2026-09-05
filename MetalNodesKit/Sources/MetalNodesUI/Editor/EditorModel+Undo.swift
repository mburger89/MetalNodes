import Foundation
import MetalNodesCore

/// Snapshot-based undo (spec §5, §18.3). A transaction captures the document once;
/// `endTransaction` registers a single undo step that restores that snapshot.
extension EditorModel {
    public var isInTransaction: Bool { transactionSnapshot != nil }
    /// Reads `undoStackVersion` before forwarding so SwiftUI observes a change whenever the
    /// (non-`@Observable`) `UndoManager`'s stack changes.
    public var canUndo: Bool { _ = undoStackVersion; return undoManager.canUndo }
    public var canRedo: Bool { _ = undoStackVersion; return undoManager.canRedo }

    /// Opens a transaction; a nested call joins the open one, keeps its name, and must be
    /// balanced by its own `endTransaction()`.
    public func beginTransaction(_ name: String) {
        transactionDepth += 1
        guard transactionSnapshot == nil else { return }
        transactionSnapshot = document
        transactionName = name
    }

    /// Closes one level; the outermost close registers the undo step.
    public func endTransaction() {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        guard transactionDepth == 0, let before = transactionSnapshot else { return }
        transactionSnapshot = nil
        commitUndo(before: before, name: transactionName)
    }

    /// Abandons the open transaction: the document goes back to the snapshot and nothing is
    /// registered with the undo manager. Nested calls unwind one level; the outermost restores.
    /// Used by the cancel paths of a re-drag, whose `.disconnect` has already been applied
    /// (spec §18.5) — `apply(.restore(_:))` deliberately registers nothing of its own.
    public func cancelTransaction() {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        guard transactionDepth == 0, let before = transactionSnapshot else { return }
        transactionSnapshot = nil
        apply(.restore(before))
    }

    /// No-op while a gesture transaction is open (spec §18.3): undoing mid-gesture would race
    /// the transaction's eventual `commitUndo`.
    public func undo() {
        guard !isInTransaction else { return }
        undoManager.undo()
        undoStackVersion += 1
    }

    public func redo() {
        guard !isInTransaction else { return }
        undoManager.redo()
        undoStackVersion += 1
    }

    /// Registers "go back to `before`". Registering again inside the undo handler is what
    /// gives `UndoManager` its redo step.
    func commitUndo(before: ShaderDocument, name: String) {
        guard before != document else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.document
                model.apply(.restore(before))
                model.commitUndo(before: current, name: name)
            }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        undoStackVersion += 1
    }
}
