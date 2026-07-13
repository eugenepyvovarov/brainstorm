import Foundation
import Observation

/// Owns the mind map tree, selection, editing state, and undoable mutations.
@Observable
@MainActor
public final class MindMapStore {
    public private(set) var root: MindNode
    public var selectedID: UUID?
    public var editingID: UUID?
    /// In-progress title text (updated as the user types; committed without requiring Enter).
    /// Not used for layout — only for commit/Tab/navigation so the latest text is never lost.
    public var editingDraft: String = ""
    /// When non-nil, the inline editor should start with this text instead of the node title.
    public var editingSeed: String?
    /// Title snapshot at the start of the current edit session (for undo / cancel).
    private var titleBeforeEdit: String = ""
    public var fileURL: URL?
    public private(set) var isDirty: Bool = false
    public var lastError: String?

    /// Bumped when the tree structure or expansion changes (not on every live keystroke).
    /// Views that only need structural layout can key off this.
    public private(set) var structureEpoch: UInt64 = 0

    /// Bumped whenever the undo stack changes so SwiftUI can refresh Undo/Redo controls.
    public private(set) var historyEpoch: UInt64 = 0

    public let undoManager: UndoManager

    public init(
        root: MindNode = .root(),
        undoManager: UndoManager = UndoManager(),
        startEditing: Bool = true
    ) {
        self.root = root
        self.undoManager = undoManager
        // Explicit groups — more reliable when undos are registered from a key monitor.
        self.undoManager.groupsByEvent = false
        self.undoManager.levelsOfUndo = 50
        self.selectedID = root.id
        // MindNode: new document opens with the main node already in edit mode.
        if startEditing {
            self.editingID = root.id
            self.titleBeforeEdit = root.title
            self.editingDraft = root.title
        }
    }

    public var canUndo: Bool {
        _ = historyEpoch
        return undoManager.canUndo
    }

    public var canRedo: Bool {
        _ = historyEpoch
        return undoManager.canRedo
    }

    /// Undo the last structural change (delete, add, move, rename, …).
    public func undo() {
        // Don't leave a half-edited title fighting the restored snapshot.
        if isEditing {
            // Drop the live draft without registering another undo entry.
            if let editingID {
                _ = updateNode(id: editingID) { $0.title = titleBeforeEdit }
            }
            editingID = nil
            editingSeed = nil
            editingDraft = ""
            titleBeforeEdit = ""
        }
        guard undoManager.canUndo else { return }
        undoManager.undo()
        historyEpoch &+= 1
    }

    /// Redo the last undone change.
    public func redo() {
        if isEditing {
            if let editingID {
                _ = updateNode(id: editingID) { $0.title = titleBeforeEdit }
            }
            editingID = nil
            editingSeed = nil
            editingDraft = ""
            titleBeforeEdit = ""
        }
        guard undoManager.canRedo else { return }
        undoManager.redo()
        historyEpoch &+= 1
    }

    // MARK: - Derived

    /// Window / nav title — always the main (root) node’s name.
    public var documentTitle: String {
        let name = mapName
        return isDirty ? "\(name) — Edited" : name
    }

    /// Base name of the mind map, taken from the first/main item.
    /// Empty or placeholder titles fall back to "Untitled".
    public var mapName: String {
        let trimmed = root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == MindNode.mainPlaceholder {
            return "Untitled"
        }
        return trimmed
    }

    /// Suggested Save As filename, derived from the main node title.
    public var suggestedFileName: String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = mapName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Untitled" : cleaned
        return "\(base).mindmap"
    }

    public var selectedNode: MindNode? {
        guard let selectedID else { return nil }
        return node(id: selectedID)
    }

    public var isEditing: Bool { editingID != nil }

    public func visibleIDs() -> [UUID] {
        var result: [UUID] = []
        collectVisible(from: root, into: &result)
        return result
    }

    // MARK: - Document lifecycle

    public func newDocument() {
        root = .root()
        selectedID = root.id
        editingID = root.id
        titleBeforeEdit = root.title
        editingDraft = root.title
        editingSeed = nil
        fileURL = nil
        isDirty = false
        lastError = nil
        structureEpoch &+= 1
        undoManager.removeAllActions()
    }

    /// End title editing (Return or click canvas) — keeps selection.
    public func endEditing() {
        commitEditing()
    }

    /// Click empty canvas: finish editing; keep the current selection focused.
    public func canvasBackgroundClicked() {
        if isEditing {
            commitEditing()
        }
    }

    public func load(from url: URL) {
        do {
            let file = try MindMapCodec.load(from: url)
            root = file.root
            selectedID = root.id
            editingID = nil
            titleBeforeEdit = ""
            editingDraft = ""
            editingSeed = nil
            fileURL = url
            isDirty = false
            lastError = nil
            structureEpoch &+= 1
            undoManager.removeAllActions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns `true` when save succeeded.
    @discardableResult
    public func save(to url: URL? = nil) -> Bool {
        let target = url ?? fileURL
        guard let target else {
            lastError = "No save location selected."
            return false
        }
        do {
            let file = MindMapFile(root: root)
            try MindMapCodec.save(file, to: target)
            fileURL = target
            isDirty = false
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Selection & editing

    public func select(_ id: UUID?) {
        if let id, node(id: id) == nil { return }
        if editingID != nil, editingID != id {
            commitEditing()
        }
        selectedID = id
    }

    /// Keyboard actions never operate on a nil selection — fall back to the main node.
    @discardableResult
    public func ensureSelection() -> UUID {
        if let selectedID, node(id: selectedID) != nil {
            return selectedID
        }
        selectedID = root.id
        return root.id
    }

    public func beginEditing(id: UUID? = nil, seed: String? = nil) {
        // Finish any previous edit first.
        if let editingID, editingID != (id ?? selectedID) {
            commitEditing()
        }
        let target = id ?? selectedID ?? root.id
        guard let existing = node(id: target) else { return }
        selectedID = target
        titleBeforeEdit = existing.title
        editingSeed = seed
        editingDraft = seed ?? existing.title
        if let seed {
            // Seed replaces content immediately (type-to-edit).
            applyTitleLive(id: target, raw: seed)
        }
        editingID = target
    }

    /// Keep the draft in sync as the user types (does not re-layout by itself).
    public func updateEditingDraft(_ raw: String) {
        editingDraft = raw
    }

    /// Write title into the tree. Prefer calling from commit / debounced live save.
    public func applyTitleLive(id: UUID, raw: String) {
        let title = normalizedTitle(raw, for: id)
        guard let existing = node(id: id), existing.title != title else { return }
        _ = updateNode(id: id) { $0.title = title }
        isDirty = true
    }

    public func commitEditing(title: String? = nil) {
        guard let editingID else { return }
        let nodeID = editingID
        let before = titleBeforeEdit
        // Prefer an explicit title, then the live draft, then whatever is already on the node
        // (avoids wiping a programmatic rename with a stale empty draft).
        let raw = title ?? (editingDraft.isEmpty ? nil : editingDraft) ?? node(id: nodeID)?.title ?? before
        applyTitleLive(id: nodeID, raw: raw)
        let finalTitle = node(id: nodeID)?.title ?? before
        // One undo step for the whole rename session.
        if finalTitle != before {
            let after = finalTitle
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { target in
                _ = target.updateNode(id: nodeID) { $0.title = before }
                target.selectedID = nodeID
                target.editingID = nil
                target.editingSeed = nil
                target.editingDraft = ""
                target.titleBeforeEdit = ""
                target.isDirty = true
                target.structureEpoch &+= 1
                target.historyEpoch &+= 1
                target.undoManager.registerUndo(withTarget: target) { redo in
                    _ = redo.updateNode(id: nodeID) { $0.title = after }
                    redo.selectedID = nodeID
                    redo.editingID = nil
                    redo.isDirty = true
                    redo.structureEpoch &+= 1
                    redo.historyEpoch &+= 1
                }
                target.undoManager.setActionName("Rename")
            }
            undoManager.setActionName("Rename")
            undoManager.endUndoGrouping()
            historyEpoch &+= 1
        }
        self.editingID = nil
        self.editingSeed = nil
        self.editingDraft = ""
        self.titleBeforeEdit = ""
    }

    public func cancelEditing() {
        guard let editingID else { return }
        _ = updateNode(id: editingID) { $0.title = titleBeforeEdit }
        self.editingID = nil
        self.editingSeed = nil
        self.editingDraft = ""
        self.titleBeforeEdit = ""
    }

    /// Consume and clear the one-shot rename seed (used by the node editor).
    public func takeEditingSeed() -> String? {
        let seed = editingSeed
        editingSeed = nil
        return seed
    }

    private func normalizedTitle(_ raw: String, for id: UUID) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (id == root.id) ? MindNode.mainPlaceholder : MindNode.nodePlaceholder
        }
        return trimmed
    }

    // MARK: - Tree mutations (MindNode-style)

    /// Return — create sibling after selection (or child of root when root is selected).
    /// Safe to call while editing: current title is committed first, then a new empty sibling opens for typing.
    @discardableResult
    public func addSibling(after: Bool = true) -> UUID? {
        if editingID != nil { commitEditing() }
        let selectedID = ensureSelection()
        if selectedID == root.id {
            return addChild(of: root.id)
        }
        guard let parentNodeID = parentID(of: selectedID) else { return nil }

        // Empty title + edit mode so the user types immediately (MindNode).
        let newNode = MindNode(title: "")
        let insertRelativeTo = selectedID
        let parent = parentNodeID
        let placeAfter = after

        performUndoable(named: after ? "Add Sibling" : "Add Sibling Above") {
            _ = self.insertSibling(
                of: insertRelativeTo,
                parentID: parent,
                node: newNode,
                after: placeAfter
            )
            self.selectedID = newNode.id
            self.titleBeforeEdit = ""
            self.editingDraft = ""
            self.editingID = newNode.id
            self.editingSeed = nil
        }
        return newNode.id
    }

    /// Tab or node well — create child under selection.
    /// Safe to call while editing: current title is committed first, then a new empty child opens for typing.
    @discardableResult
    public func addChild(of parentID: UUID? = nil) -> UUID? {
        // If currently editing another node, save its text first (no Enter needed).
        if editingID != nil {
            commitEditing()
        }
        let targetParent = parentID ?? ensureSelection()

        let newNode = MindNode(title: "")
        performUndoable(named: "Add Child") {
            _ = self.updateNode(id: targetParent) { node in
                node.isExpanded = true
                node.children.append(newNode)
            }
            self.selectedID = newNode.id
            self.titleBeforeEdit = ""
            self.editingDraft = ""
            self.editingID = newNode.id
            self.editingSeed = nil
        }
        return newNode.id
    }

    /// ⌥Tab — insert a new parent between the selection and its current parent.
    @discardableResult
    public func insertParentForSelection() -> UUID? {
        if editingID != nil { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return nil }
        guard let parentNodeID = parentID(of: selectedID) else { return nil }
        guard let parent = node(id: parentNodeID) else { return nil }
        guard let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return nil }

        let newParentID = UUID()
        let childID = selectedID
        let insertIndex = index
        let parentIDValue = parentNodeID

        performUndoable(named: "Add Parent") {
            guard let moving = self.removeNode(id: childID) else { return }
            let wrapper = MindNode(
                id: newParentID,
                title: "",
                isExpanded: true,
                children: [moving]
            )
            _ = self.updateNode(id: parentIDValue) { node in
                let safeIndex = min(insertIndex, node.children.count)
                node.children.insert(wrapper, at: safeIndex)
            }
            self.selectedID = newParentID
            self.titleBeforeEdit = ""
            self.editingDraft = ""
            self.editingID = newParentID
            self.editingSeed = nil
        }
        return newParentID
    }

    /// ⇧Return — new main node (direct child of the central/root node).
    @discardableResult
    public func addMainNode() -> UUID? {
        addChild(of: root.id)
    }

    /// ⌫ — delete selection and its subtree (root protected).
    public func deleteSelected() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return }

        let parent = parentID(of: selectedID)
        let siblings = parent.flatMap { node(id: $0)?.children.map(\.id) } ?? []
        let index = siblings.firstIndex(of: selectedID) ?? 0
        let fallback: UUID? = {
            if index + 1 < siblings.count { return siblings[index + 1] }
            if index > 0 { return siblings[index - 1] }
            return parent
        }()
        let removing = selectedID

        performUndoable(named: "Delete Node") {
            _ = self.removeNode(id: removing)
            self.selectedID = fallback
            self.editingID = nil
            self.editingSeed = nil
        }
    }

    /// ⌥⌫ — delete only the selected node; promote its children into its place.
    public func deleteSingleNode() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return }
        guard let parentNodeID = parentID(of: selectedID) else { return }
        guard let current = node(id: selectedID) else { return }
        guard let parent = node(id: parentNodeID) else { return }
        guard let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }

        let removing = selectedID
        let promoted = current.children
        let insertAt = index
        let parentIDValue = parentNodeID

        performUndoable(named: "Delete Single Node") {
            _ = self.removeNode(id: removing)
            _ = self.updateNode(id: parentIDValue) { node in
                let safeIndex = min(insertAt, node.children.count)
                node.children.insert(contentsOf: promoted, at: safeIndex)
            }
            self.selectedID = promoted.first?.id ?? parentIDValue
            self.editingID = nil
            self.editingSeed = nil
        }
    }

    public func goToMainNode() {
        select(root.id)
    }

    /// Esc when not editing — clear selection (MindNode deselect).
    public func deselect() {
        cancelEditing()
        selectedID = nil
    }

    public func rename(id: UUID, to rawTitle: String) {
        // Don't let a stale edit session overwrite this rename on the next commit.
        if editingID == id {
            editingDraft = rawTitle
            commitEditing(title: rawTitle)
            return
        }
        if editingID != nil {
            commitEditing()
        }

        let title = normalizedTitle(rawTitle, for: id)
        guard let existing = node(id: id), existing.title != title else { return }

        performUndoable(named: "Rename") {
            _ = self.updateNode(id: id) { $0.title = title }
        }
    }

    /// Drag a node onto another to change its parent (MindNode rewire).
    public func rewire(nodeID: UUID, onto newParentID: UUID) {
        guard nodeID != root.id else { return }
        guard nodeID != newParentID else { return }
        guard node(id: nodeID) != nil, node(id: newParentID) != nil else { return }
        // Cannot reparent onto own descendant (would create a cycle).
        guard !isDescendant(newParentID, of: nodeID) else { return }
        // Already a direct child of target — no-op.
        if parentID(of: nodeID) == newParentID { return }

        let movingID = nodeID
        let targetParent = newParentID

        performUndoable(named: "Rewire Node") {
            guard let moving = self.removeNode(id: movingID) else { return }
            _ = self.updateNode(id: targetParent) { parent in
                parent.isExpanded = true
                parent.children.append(moving)
            }
            self.selectedID = movingID
            self.editingID = nil
            self.editingSeed = nil
        }
    }

    /// True if `candidate` is `ancestorID` or nested under it.
    public func isDescendant(_ candidate: UUID, of ancestorID: UUID) -> Bool {
        guard let ancestor = node(id: ancestorID) else { return false }
        return contains(id: candidate, in: ancestor)
    }

    private func contains(id: UUID, in node: MindNode) -> Bool {
        if node.id == id { return true }
        return node.children.contains { contains(id: id, in: $0) }
    }

    public func toggleExpanded(id: UUID) {
        guard let current = node(id: id), current.hasChildren else { return }
        // Fold/unfold is structural; keep undo but avoid edit-session interference.
        if editingID != nil { commitEditing() }
        performUndoable(named: "Toggle Expand") {
            _ = self.updateNode(id: id) { $0.isExpanded.toggle() }
        }
    }

    public func expand(id: UUID) {
        guard let current = node(id: id), current.hasChildren, !current.isExpanded else { return }
        if editingID != nil { commitEditing() }
        performUndoable(named: "Expand") {
            _ = self.updateNode(id: id) { $0.isExpanded = true }
        }
    }

    public func collapse(id: UUID) {
        guard let current = node(id: id), current.hasChildren, current.isExpanded else { return }
        if editingID != nil { commitEditing() }
        performUndoable(named: "Collapse") {
            _ = self.updateNode(id: id) { $0.isExpanded = false }
        }
    }

    // MARK: - Navigation

    public func selectPreviousVisible() {
        let ids = visibleIDs()
        guard let selectedID, let index = ids.firstIndex(of: selectedID), index > 0 else { return }
        select(ids[index - 1])
    }

    public func selectNextVisible() {
        let ids = visibleIDs()
        guard let selectedID, let index = ids.firstIndex(of: selectedID), index + 1 < ids.count else {
            return
        }
        select(ids[index + 1])
    }

    /// ← — move selection to parent (MindNode canvas; fold is ⌥. separately).
    /// Commits any in-progress title edit first so arrows always work from the keyboard.
    public func navigateLeft() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        if let parent = parentID(of: selectedID) {
            select(parent)
        }
    }

    /// → — move selection to first visible child (expand if needed).
    public func navigateRight() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard let current = node(id: selectedID) else { return }
        guard current.hasChildren else { return }
        if !current.isExpanded {
            expand(id: selectedID)
        }
        if let first = node(id: selectedID)?.children.first {
            select(first.id)
        }
    }

    /// ↑ — previous sibling, else previous visible node.
    public func navigateUp() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        if let parentNodeID = parentID(of: selectedID),
           let parent = node(id: parentNodeID),
           let index = parent.children.firstIndex(where: { $0.id == selectedID }),
           index > 0
        {
            select(parent.children[index - 1].id)
            return
        }
        selectPreviousVisible()
    }

    /// ↓ — next sibling, else next visible node.
    public func navigateDown() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        if let parentNodeID = parentID(of: selectedID),
           let parent = node(id: parentNodeID),
           let index = parent.children.firstIndex(where: { $0.id == selectedID }),
           index + 1 < parent.children.count
        {
            select(parent.children[index + 1].id)
            return
        }
        selectNextVisible()
    }

    /// ⌥. — fold/unfold selected branch.
    public func toggleFoldSelected() {
        if isEditing { commitEditing() }
        let id = ensureSelection()
        toggleExpanded(id: id)
    }

    // MARK: - Structure edits

    /// Make the selection a child of its previous sibling.
    public func indentSelected() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return }
        guard let parentID = parentID(of: selectedID) else { return }
        guard let parent = node(id: parentID) else { return }
        guard let index = parent.children.firstIndex(where: { $0.id == selectedID }), index > 0 else {
            return
        }

        let previousSiblingID = parent.children[index - 1].id
        let movingID = selectedID

        performUndoable(named: "Indent") {
            guard let moving = self.removeNode(id: movingID) else { return }
            _ = self.updateNode(id: previousSiblingID) { sibling in
                sibling.isExpanded = true
                sibling.children.append(moving)
            }
            self.selectedID = movingID
        }
    }

    /// Promote the selection to be a sibling of its parent (after the parent).
    public func outdentSelected() {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return }
        guard let parentNodeID = parentID(of: selectedID) else { return }
        // Direct children of root are already top-level topics.
        guard let grandparentID = parentID(of: parentNodeID) else { return }

        let movingID = selectedID

        performUndoable(named: "Outdent") {
            guard let moving = self.removeNode(id: movingID) else { return }
            _ = self.insertSibling(of: parentNodeID, parentID: grandparentID, node: moving, after: true)
            self.selectedID = movingID
        }
    }

    public func moveSelectedUp() {
        moveSelected(direction: -1)
    }

    public func moveSelectedDown() {
        moveSelected(direction: 1)
    }

    private func moveSelected(direction: Int) {
        if isEditing { commitEditing() }
        let selectedID = ensureSelection()
        guard selectedID != root.id else { return }
        guard let parentID = parentID(of: selectedID) else { return }
        guard let parent = node(id: parentID) else { return }
        guard let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < parent.children.count else { return }

        let from = index
        let to = newIndex
        let parentNodeID = parentID

        performUndoable(named: "Move") {
            _ = self.updateNode(id: parentNodeID) { node in
                node.children.swapAt(from, to)
            }
            self.selectedID = selectedID
        }
    }

    // MARK: - Tree helpers

    public func node(id: UUID) -> MindNode? {
        find(id: id, in: root)
    }

    public func parentID(of id: UUID) -> UUID? {
        findParent(of: id, in: root)?.id
    }

    private func collectVisible(from node: MindNode, into result: inout [UUID]) {
        result.append(node.id)
        guard node.isExpanded else { return }
        for child in node.children {
            collectVisible(from: child, into: &result)
        }
    }

    private func find(id: UUID, in node: MindNode) -> MindNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private func findParent(of id: UUID, in node: MindNode) -> MindNode? {
        if node.children.contains(where: { $0.id == id }) { return node }
        for child in node.children {
            if let found = findParent(of: id, in: child) { return found }
        }
        return nil
    }

    @discardableResult
    private func updateNode(id: UUID, _ body: (inout MindNode) -> Void) -> Bool {
        updateNode(id: id, in: &root, body)
    }

    @discardableResult
    private func updateNode(
        id: UUID,
        in node: inout MindNode,
        _ body: (inout MindNode) -> Void
    ) -> Bool {
        if node.id == id {
            body(&node)
            return true
        }
        for index in node.children.indices {
            if updateNode(id: id, in: &node.children[index], body) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func removeNode(id: UUID) -> MindNode? {
        removeNode(id: id, from: &root)
    }

    private func removeNode(id: UUID, from node: inout MindNode) -> MindNode? {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            return node.children.remove(at: index)
        }
        for index in node.children.indices {
            if let removed = removeNode(id: id, from: &node.children[index]) {
                return removed
            }
        }
        return nil
    }

    @discardableResult
    private func insertSibling(
        of siblingID: UUID,
        parentID: UUID,
        node newNode: MindNode,
        after: Bool
    ) -> Bool {
        updateNode(id: parentID) { parent in
            guard let index = parent.children.firstIndex(where: { $0.id == siblingID }) else {
                return
            }
            let insertAt = after ? index + 1 : index
            parent.children.insert(newNode, at: insertAt)
        }
    }

    // MARK: - Undo

    /// Snapshot-based undo. Captures full tree + selection before mutation.
    /// Used for delete/add/move/etc. so accidental deletes can always be restored.
    private func performUndoable(named name: String, _ body: () -> Void) {
        let beforeRoot = root
        let beforeSelected = selectedID

        body()
        isDirty = true
        structureEpoch &+= 1

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreState(
                root: beforeRoot,
                selected: beforeSelected,
                actionName: name
            )
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        historyEpoch &+= 1
    }

    private func restoreState(
        root newRoot: MindNode,
        selected: UUID?,
        actionName: String
    ) {
        let previousRoot = root
        let previousSelected = selectedID

        root = newRoot
        selectedID = selected
        // Never re-enter a stale edit session after undo/redo.
        editingID = nil
        editingSeed = nil
        editingDraft = ""
        titleBeforeEdit = ""
        isDirty = true
        structureEpoch &+= 1
        historyEpoch &+= 1

        undoManager.registerUndo(withTarget: self) { target in
            target.restoreState(
                root: previousRoot,
                selected: previousSelected,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }
}
