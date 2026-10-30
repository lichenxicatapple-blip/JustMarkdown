import Foundation

struct SourceSelection: Equatable {
    var range: NSRange
    var scrollY: CGFloat = 0
}

/// UIKit can offer this manager in system menus without registering a second
/// set of text mutations. The document model is the sole registration owner.
@MainActor
final class SourceUndoManager: UndoManager {
    private var modelOperation = false
    weak var registrationTarget: AnyObject?

    func performModelOperation(_ action: () -> Void) {
        let previous = modelOperation
        modelOperation = true
        defer { modelOperation = previous }
        action()
    }

    override func beginUndoGrouping() { if modelOperation { super.beginUndoGrouping() } }
    override func endUndoGrouping() { if modelOperation { super.endUndoGrouping() } }
    override func removeAllActions() {}
    func reset() { super.removeAllActions() }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        if target as AnyObject === registrationTarget {
            super.registerUndo(withTarget: target, selector: selector, object: anObject)
        }
    }
    override func __registerUndoWithTarget(_ target: Any, handler undoHandler: @escaping @MainActor (Any) -> Void) {
        if target as AnyObject === registrationTarget { super.__registerUndoWithTarget(target, handler: undoHandler) }
    }
    override func undo() { performModelOperation { super.undo() } }
    override func redo() { performModelOperation { super.redo() } }
}

/// Owns the working text and edit transactions. Text views and Web snapshots are projections.
@MainActor
final class SourceHistory {
    enum InputKind { case typing, backwardDelete, forwardDelete, composition, transaction }

    private final class Entry {
        let id: String
        var start: Int
        var before: String
        var after: String
        let kind: InputKind
        let beforeSelection: SourceSelection
        var afterSelection: SourceSelection

        init(
            id: String, start: Int, before: String, after: String, kind: InputKind,
            beforeSelection: SourceSelection, afterSelection: SourceSelection
        ) {
            self.id = id
            self.start = start
            self.before = before
            self.after = after
            self.kind = kind
            self.beforeSelection = beforeSelection
            self.afterSelection = afterSelection
        }
    }

    private final class UndoTarget {
        weak var history: SourceHistory?
    }

    let undoManager = SourceUndoManager()
    private(set) var text = ""
    private(set) var revision = 0
    private var undo: [Entry] = []
    private var redo: [Entry] = []
    private var group: Entry?
    private let undoTarget = UndoTarget()
    var onChange: ((SourceSelection, String?, String?) -> Void)?

    init() {
        undoTarget.history = self
        undoManager.registrationTarget = undoTarget
        undoManager.groupsByEvent = false
    }

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }

    func reset(_ value: String) {
        undoManager.reset()
        undo.removeAll()
        redo.removeAll()
        group = nil
        text = value
        revision += 1
    }

    func breakGroup() { group = nil }

    func record(
        _ value: String, before: SourceSelection, after selection: SourceSelection? = nil,
        kind requestedKind: InputKind = .transaction, id: String = UUID().uuidString.lowercased()
    ) {
        guard value != text else { return }
        let patch = Self.difference(
            text, value, maximumPrefix: selection.map { min(before.range.location, $0.range.location) })
        let kind: InputKind
        if requestedKind == .typing && patch.after.isEmpty {
            kind =
                before.range.length > 0
                ? .transaction : patch.start < before.range.location ? .backwardDelete : .forwardDelete
        } else {
            kind = requestedKind
        }
        let delta = patch.after.utf16.count - patch.before.utf16.count
        let end = patch.start + patch.before.utf16.count
        func moved(_ offset: Int) -> Int {
            if offset <= patch.start { return offset }
            if offset >= end { return offset + delta }
            return patch.start + min(offset - patch.start, patch.after.utf16.count)
        }
        let start = moved(before.range.location)
        let after =
            selection
            ?? SourceSelection(
                range: NSRange(location: start, length: moved(NSMaxRange(before.range)) - start),
                scrollY: before.scrollY)
        var entry: Entry?
        var merged = false
        if let previous = group, undo.last === previous, previous.kind == kind {
            let previousAfterCount = previous.after.utf16.count
            if kind == .typing, patch.before.isEmpty, previous.before.isEmpty,
                patch.start == previous.start + previousAfterCount
            {
                previous.after += patch.after
                merged = true
            } else if kind == .backwardDelete, patch.after.isEmpty, previous.after.isEmpty,
                patch.start + patch.before.utf16.count == previous.start
            {
                previous.start = patch.start
                previous.before = patch.before + previous.before
                merged = true
            } else if kind == .forwardDelete, patch.after.isEmpty, previous.after.isEmpty,
                patch.start == previous.start
            {
                previous.before += patch.before
                merged = true
            }
            if merged { entry = previous }
        }
        if !merged {
            let transaction = Entry(
                id: id, start: patch.start, before: patch.before, after: patch.after, kind: kind,
                beforeSelection: before, afterSelection: after)
            entry = transaction
            undo.append(transaction)
            register(transaction, forward: false)
        }
        guard let entry else { return }
        entry.afterSelection = after
        redo.removeAll()
        text = value
        revision += 1
        group = kind == .transaction || kind == .composition ? nil : entry
        if kind == .typing, let last = patch.after.unicodeScalars.last,
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:。！？；，")).contains(last)
        {
            group = nil
        }
        onChange?(after, entry.id, "applied")
    }

    @discardableResult
    func move(forward: Bool, id: String? = nil) -> Bool {
        guard forward ? canRedo : canUndo else { return false }
        if let id, (forward ? redo.last : undo.last)?.id != id { return false }
        if forward { undoManager.redo() } else { undoManager.undo() }
        return true
    }

    private func register(_ entry: Entry, forward: Bool) {
        undoManager.performModelOperation {
            if !undoManager.isUndoing && !undoManager.isRedoing { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: undoTarget) { target in
                target.history?.replay(entry, forward: forward)
            }
            if !undoManager.isUndoing && !undoManager.isRedoing { undoManager.endUndoGrouping() }
        }
    }

    private func replay(_ entry: Entry, forward: Bool) {
        let expected = forward ? entry.before : entry.after
        let replacement = forward ? entry.after : entry.before
        let range = NSRange(location: entry.start, length: expected.utf16.count)
        let current = text as NSString
        precondition(NSMaxRange(range) <= current.length && current.substring(with: range) == expected)
        text = current.replacingCharacters(in: range, with: replacement)
        if forward {
            redo.removeLast()
            undo.append(entry)
        } else {
            undo.removeLast()
            redo.append(entry)
        }
        register(entry, forward: !forward)
        group = nil
        revision += 1
        onChange?(forward ? entry.afterSelection : entry.beforeSelection, entry.id, forward ? "applied" : "undone")
    }

    private static func difference(
        _ before: String, _ after: String, maximumPrefix: Int?
    ) -> (start: Int, before: String, after: String) {
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        // Repeated characters admit several equal text diffs. Native selection
        // boundaries identify the actual edit, so adjacent deletions still merge.
        let prefixLimit = min(old.count, new.count, maximumPrefix ?? Int.max)
        var prefix = 0
        while prefix < prefixLimit && old[prefix] == new[prefix] { prefix += 1 }
        if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix
            && old[old.count - suffix - 1] == new[new.count - suffix - 1]
        {
            suffix += 1
        }
        if suffix > 0, (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        return (
            prefix,
            (before as NSString).substring(with: NSRange(location: prefix, length: old.count - prefix - suffix)),
            (after as NSString).substring(with: NSRange(location: prefix, length: new.count - prefix - suffix))
        )
    }
}
