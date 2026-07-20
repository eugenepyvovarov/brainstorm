import CoreGraphics
import Foundation
import Observation

/// Transient canvas viewport state. Keeping this separately observable prevents
/// continuous zoom updates from invalidating the document store and every view
/// that reads document state.
@Observable
@MainActor
public final class CanvasViewportState {
    public static let minimumZoom: CGFloat = 0.25
    public static let maximumZoom: CGFloat = 3

    public private(set) var zoomScale: CGFloat = 1

    public init() {}

    public static func clampedZoom(_ scale: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, scale))
    }

    public func setZoom(_ scale: CGFloat) {
        let next = Self.clampedZoom(scale)
        guard abs(next - zoomScale) > .ulpOfOne else { return }
        zoomScale = next
    }

    public func zoomIn() { setZoom(zoomScale * 1.15) }
    public func zoomOut() { setZoom(zoomScale / 1.15) }
    public func zoomReset() { setZoom(1) }
}

/// Owns the mind map tree, selection, editing state, and undoable mutations.
@Observable
@MainActor
public final class BrainstormStore {
    /// Stable id for this window’s document (autosave + session restore).
    public let documentID: UUID
    public private(set) var root: BrainstormNode
    /// Active editor theme (Zed / VS Code–style palettes).
    public var themeID: String = AppTheme.system.id
    /// Complete canvas selection. `selectedID` is the primary/inspector node.
    public private(set) var selectedIDs: Set<UUID> = []
    public var selectedID: UUID? {
        didSet {
            guard !isUpdatingSelectionGroup else { return }
            selectedIDs = selectedID.map { Set([$0]) } ?? []
        }
    }
    @ObservationIgnored private var isUpdatingSelectionGroup = false
    public var editingID: UUID?
    /// In-progress title text (updated as the user types; committed without requiring Enter).
    /// Not used for layout — only for commit/Tab/navigation so the latest text is never lost.
    public var editingDraft: String = ""
    /// When non-nil, the inline editor should start with this text instead of the node title.
    public var editingSeed: String?
    /// When starting an edit without a seed: select-all (replace) vs caret at end (extend).
    public var editingSelectAll: Bool = true
    /// Title snapshot at the start of the current edit session (for undo / cancel).
    private var titleBeforeEdit: String = ""
    /// Coalesced note-body editing state. The live draft is applied to `root`
    /// for preview/recovery, then committed as one logical undo action.
    public private(set) var noteEditingID: UUID?
    public private(set) var noteEditingDraft: String = ""
    private var noteBeforeEdit: NodeNote?
    private var noteEditStartContentRevision: Int = 0
    private var noteEditStartWasDirty = false
    public var fileURL: URL?
    public private(set) var isDirty: Bool = false
    public var lastError: String?
    /// Last autosave failure message (shown in chrome; cleared on success).
    public private(set) var lastAutosaveError: String?

    /// Monotonic edit counter — used with `savedRevision` for dirty restore.
    public private(set) var contentRevision: Int = 0
    /// Revision at last successful Save / load / pristine seed.
    public private(set) var savedRevision: Int = 0

    /// Bumped when the tree structure or expansion changes (not on every live keystroke).
    /// Views that only need structural layout can key off this.
    public private(set) var structureEpoch: UInt64 = 0

    /// Bumped whenever the undo stack changes so SwiftUI can refresh Undo/Redo controls.
    public private(set) var historyEpoch: UInt64 = 0
    /// Bumped for note-only mutations without pretending the tree structure changed.
    public private(set) var noteEpoch: UInt64 = 0
    @ObservationIgnored private var noteAutosaveTask: Task<Void, Never>?

    // MARK: - View chrome

    /// Shared app-wide workspace preferences. These are not part of the `.bs`
    /// document and are restored independently for every document window.
    @ObservationIgnored private let uiPreferences: BrainstormUIPreferences
    /// Pan/zoom is transient viewport state, not document state.
    @ObservationIgnored public let viewport = CanvasViewportState()

    /// Focus mode dims everything outside the selected branch.
    public var isFocusMode: Bool {
        didSet {
            guard oldValue != isFocusMode, uiPreferences.isFocusMode != isFocusMode else { return }
            uiPreferences.isFocusMode = isFocusMode
        }
    }
    /// Compatibility accessor for callers that only need the current scale.
    public var zoomScale: CGFloat { viewport.zoomScale }
    /// Search query; empty hides search highlights.
    public var searchQuery: String = ""
    /// Match IDs for the current query (visible nodes only, DFS order).
    public private(set) var searchMatchIDs: [UUID] = []
    public private(set) var searchMatchIndex: Int = 0

    public let undoManager: UndoManager

    public init(
        documentID: UUID = UUID(),
        root: BrainstormNode = .root(),
        themeID: String = AppTheme.preferredDefaultID,
        fileURL: URL? = nil,
        isDirty: Bool = false,
        contentRevision: Int = 0,
        savedRevision: Int = 0,
        undoManager: UndoManager = UndoManager(),
        startEditing: Bool = true,
        uiPreferences: BrainstormUIPreferences = .shared
    ) {
        self.documentID = documentID
        self.root = root
        self.themeID = AppTheme.theme(id: themeID).id
        self.fileURL = fileURL
        self.isDirty = isDirty
        self.contentRevision = contentRevision
        self.savedRevision = savedRevision
        self.undoManager = undoManager
        self.uiPreferences = uiPreferences
        self.isFocusMode = uiPreferences.isFocusMode
        // Explicit groups — more reliable when undos are registered from a key monitor.
        self.undoManager.groupsByEvent = false
        self.undoManager.levelsOfUndo = 50
        self.selectedID = root.id
        self.selectedIDs = [root.id]
        // BrainstormNode: new document opens with the main node already in edit mode.
        if startEditing {
            self.editingID = root.id
            self.titleBeforeEdit = root.title
            self.editingDraft = root.title
        }
    }

    /// Restore a document window from autosave / last session.
    ///
    /// **Pure load only** — must not write session state. SwiftUI re-evaluates
    /// `ContentView`’s `State(initialValue:)` expression on every parent body
    /// pass; side effects here (setActive/touch → disk write) caused a 100% CPU
    /// AttributeGraph loop.
    public convenience init(restoring documentID: UUID) {
        let payload = DocumentSession.shared.restorePayload(for: documentID)
        let desc = DocumentSession.shared.descriptor(for: documentID)
        let contentRev = desc?.contentRevision ?? (payload.isDirty ? 1 : 0)
        let savedRev = desc?.savedRevision ?? 0
        self.init(
            documentID: documentID,
            root: payload.root,
            themeID: payload.themeID,
            fileURL: payload.fileURL,
            isDirty: payload.isDirty,
            contentRevision: contentRev,
            savedRevision: savedRev,
            startEditing: payload.startEditing
        )
    }

    /// One store instance per document window (survives SwiftUI re-inits).
    @MainActor
    public static func sharedRestored(documentID: UUID) -> BrainstormStore {
        DocumentStoreCache.store(for: documentID)
    }

    /// Drop cached store when a window is fully closed (optional; memory hygiene).
    @MainActor
    public static func releaseShared(documentID: UUID) {
        DocumentStoreCache.release(documentID)
    }

    /// Snapshot for autosave (includes in-progress edit draft).
    public func autosaveSnapshot() -> BrainstormFile {
        var snapshotRoot = root
        if let editingID, let draft = Optional(editingDraft) {
            // Apply live draft so we don't lose uncommitted typing on quit.
            func apply(_ node: inout BrainstormNode) -> Bool {
                if node.id == editingID {
                    node.title = draft
                    return true
                }
                for i in node.children.indices {
                    if apply(&node.children[i]) { return true }
                }
                return false
            }
            _ = apply(&snapshotRoot)
        }
        if let noteEditingID {
            let draft = noteEditingDraft
            func applyNoteDraft(_ node: inout BrainstormNode) -> Bool {
                if node.id == noteEditingID {
                    var note = node.note ?? NodeNote()
                    note.bodyMarkdown = NodeNote.normalizeLineEndings(draft)
                    let canonical = note.canonicalized()
                    node.note = canonical.isEmpty ? nil : canonical
                    return true
                }
                for i in node.children.indices {
                    if applyNoteDraft(&node.children[i]) { return true }
                }
                return false
            }
            _ = applyNoteDraft(&snapshotRoot)
        }
        return BrainstormFile(root: snapshotRoot, themeID: themeID)
    }

    /// Persist recovery snapshot. Returns `false` on encode/disk failure (sets `lastAutosaveError`).
    @discardableResult
    public func performAutosave() -> Bool {
        // A synchronous autosave subsumes any delayed note-only autosave. In
        // particular, close and Don’t Save must not leave a task capable of
        // re-registering a session descriptor after it has been removed.
        cancelPendingNoteAutosave()
        let file = autosaveSnapshot()
        do {
            try DocumentSession.shared.writeAutosave(file: file, for: documentID)
            DocumentSession.shared.touch(
                id: documentID,
                displayName: mapName,
                fileURL: fileURL,
                isDirty: isDirty,
                contentRevision: contentRevision,
                savedRevision: savedRevision
            )
            lastAutosaveError = nil
            return true
        } catch {
            lastAutosaveError = "Autosave failed: \(error.localizedDescription)"
            // Keep lastError visible too so the existing error alert can surface it.
            if lastError == nil {
                lastError = lastAutosaveError
            }
            return false
        }
    }

    /// Mark the document edited and bump the content revision.
    /// Session metadata is flushed on the next successful `performAutosave()`.
    public func markDirty() {
        contentRevision &+= 1
        isDirty = true
    }

    private func markClean() {
        isDirty = false
        savedRevision = contentRevision
        lastAutosaveError = nil
        DocumentSession.shared.updateDirtyState(
            id: documentID,
            isDirty: false,
            contentRevision: contentRevision,
            savedRevision: savedRevision
        )
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
        if noteEditingID != nil {
            commitNoteEditing()
        }
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
        if noteEditingID != nil {
            commitNoteEditing()
        }
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

    /// Stable window/tab title. Dirty state uses AppKit's native document dot so
    /// narrow tab labels do not waste space on an “Edited” suffix.
    public var documentTitle: String {
        mapName
    }

    /// Base name of the mind map, taken from the first/main item.
    /// Empty or placeholder titles fall back to "Untitled".
    public var mapName: String {
        let trimmed = root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == BrainstormNode.mainPlaceholder {
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
        return "\(base).\(BrainstormCodec.fileExtension)"
    }

    public var selectedNode: BrainstormNode? {
        guard let selectedID else { return nil }
        return node(id: selectedID)
    }

    public var isEditing: Bool { editingID != nil }

    public var theme: AppTheme { AppTheme.theme(id: themeID) }

    /// Switch the editor palette (persisted with the document).
    /// Remaps per-node colors that still match the previous theme’s tokens so the
    /// whole map recolors; true custom hexes are left alone.
    /// Also becomes the default theme for newly created maps.
    public func applyTheme(_ id: String) {
        if noteEditingID != nil { commitNoteEditing() }
        let nextTheme = AppTheme.theme(id: id)
        let next = nextTheme.id
        // Always remember the pick as the app default, even if this doc already uses it.
        AppTheme.setPreferredDefault(next)
        guard next != themeID else { return }
        let before = themeID
        let beforeRoot = root
        let oldTheme = AppTheme.theme(id: before)

        var remapped = root
        Self.remapThemeLinkedColors(in: &remapped, from: oldTheme, to: nextTheme)
        let afterRoot = remapped

        themeID = next
        root = afterRoot
        markDirty()
        structureEpoch &+= 1
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.themeID = before
            target.root = beforeRoot
            target.markDirty()
            target.structureEpoch &+= 1
            target.historyEpoch &+= 1
            target.undoManager.registerUndo(withTarget: target) { redo in
                redo.themeID = next
                redo.root = afterRoot
                redo.markDirty()
                redo.structureEpoch &+= 1
                redo.historyEpoch &+= 1
            }
            target.undoManager.setActionName("Change Theme")
        }
        undoManager.setActionName("Change Theme")
        undoManager.endUndoGrouping()
        historyEpoch &+= 1
    }

    /// Walk the tree and rewrite fill/text/branch hexes that belonged to `from`.
    private static func remapThemeLinkedColors(
        in node: inout BrainstormNode,
        from: AppTheme,
        to: AppTheme
    ) {
        node.style.fillHex = AppTheme.remapLinkedHex(node.style.fillHex, from: from, to: to)
        node.style.textHex = AppTheme.remapLinkedHex(node.style.textHex, from: from, to: to)
        node.style.branchHex = AppTheme.remapLinkedHex(node.style.branchHex, from: from, to: to)
        for i in node.children.indices {
            remapThemeLinkedColors(in: &node.children[i], from: from, to: to)
        }
    }

    public func visibleIDs() -> [UUID] {
        var result: [UUID] = []
        collectVisible(from: root, into: &result)
        return result
    }

    // MARK: - Document lifecycle

    /// Replace this window’s content with a blank map (keeps the same document id / autosave slot).
    public func newDocument() {
        cancelPendingNoteAutosave()
        root = .root()
        selectedID = root.id
        editingID = root.id
        titleBeforeEdit = root.title
        editingDraft = root.title
        editingSeed = nil
        clearNoteEditingState()
        fileURL = nil
        lastError = nil
        isFocusMode = uiPreferences.isFocusMode
        viewport.zoomReset()
        // Prefer the app-wide default (last selected theme); fall back to current.
        themeID = AppTheme.preferredDefaultID
        clearSearch()
        structureEpoch &+= 1
        undoManager.removeAllActions()
        contentRevision = 0
        savedRevision = 0
        isDirty = false
        DocumentSession.shared.updateFileURL(documentID, url: nil)
        DocumentSession.shared.touch(
            id: documentID,
            displayName: "Untitled",
            fileURL: nil,
            isDirty: false,
            contentRevision: 0,
            savedRevision: 0
        )
        performAutosave()
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
            cancelPendingNoteAutosave()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let file = try BrainstormCodec.load(from: url)
            root = file.root
            themeID = file.themeID.flatMap { AppTheme.theme(id: $0).id } ?? AppTheme.preferredDefaultID
            selectedID = root.id
            editingID = nil
            titleBeforeEdit = ""
            editingDraft = ""
            editingSeed = nil
            clearNoteEditingState()
            fileURL = url
            lastError = nil
            isFocusMode = uiPreferences.isFocusMode
            viewport.zoomReset()
            clearSearch()
            structureEpoch &+= 1
            undoManager.removeAllActions()
            contentRevision = 0
            savedRevision = 0
            isDirty = false
            DocumentSession.shared.updateFileURL(documentID, url: url)
            DocumentSession.shared.touch(
                id: documentID,
                displayName: url.deletingPathExtension().lastPathComponent,
                fileURL: url,
                isDirty: false,
                contentRevision: 0,
                savedRevision: 0
            )
            RecentDocuments.shared.note(url: url)
            performAutosave()
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
        // Saving checkpoints a coalesced note edit for persistence and undo,
        // but the mounted WYSIWYG editor must still have a valid session for
        // the very next keystroke. Resume after both success and failure using
        // the post-checkpoint note as the new baseline.
        let noteEditingTarget = noteEditingID
        defer {
            if let noteEditingTarget,
               noteEditingID == nil,
               node(id: noteEditingTarget) != nil
            {
                beginNoteEditing(id: noteEditingTarget)
            }
        }
        do {
            if isEditing { commitEditing() }
            if noteEditingID != nil { commitNoteEditing() }
            let accessed = target.startAccessingSecurityScopedResource()
            defer { if accessed { target.stopAccessingSecurityScopedResource() } }
            let file = BrainstormFile(root: root, themeID: themeID)
            try BrainstormCodec.save(file, to: target)
            fileURL = target
            lastError = nil
            markClean()
            DocumentSession.shared.updateFileURL(documentID, url: target)
            RecentDocuments.shared.note(url: target)
            performAutosave()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Selection & editing

    public func select(_ id: UUID?, extending: Bool = false) {
        if let id, node(id: id) == nil { return }
        if extending, let id {
            toggleSelection(id)
            return
        }
        if editingID != nil, editingID != id {
            commitEditing()
        }
        if noteEditingID != nil, noteEditingID != id {
            commitNoteEditing()
        }
        selectedID = id
    }

    /// Shift-click selection: add a node, or remove it when at least one other
    /// node remains selected. The latest added node becomes the inspector primary.
    public func toggleSelection(_ id: UUID) {
        guard node(id: id) != nil else { return }
        if editingID != nil, editingID != id {
            commitEditing()
        }
        if noteEditingID != nil, noteEditingID != id {
            commitNoteEditing()
        }

        var next = selectedIDs
        if next.isEmpty, let selectedID {
            next.insert(selectedID)
        }
        if next.contains(id) {
            guard next.count > 1 else { return }
            next.remove(id)
            let primary = selectedID == id ? next.first : selectedID
            setSelection(primary: primary, ids: next)
        } else {
            next.insert(id)
            setSelection(primary: id, ids: next)
        }
    }

    public func isSelected(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    private func setSelection(primary: UUID?, ids: Set<UUID>) {
        isUpdatingSelectionGroup = true
        selectedID = primary
        selectedIDs = ids
        if let primary {
            selectedIDs.insert(primary)
        }
        isUpdatingSelectionGroup = false
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

    /// - Parameters:
    ///   - seed: First character of type-to-edit (replaces the whole title).
    ///   - selectAll: When `true` and no seed, select the whole title (ready to replace).
    ///     When `false`, place the caret at the end so the user can extend/edit the existing text.
    public func beginEditing(id: UUID? = nil, seed: String? = nil, selectAll: Bool = true) {
        if noteEditingID != nil {
            commitNoteEditing()
        }
        // Finish any previous edit first.
        if let editingID, editingID != (id ?? selectedID) {
            commitEditing()
        }
        let target = id ?? selectedID ?? root.id
        guard let existing = node(id: target) else { return }
        selectedID = target
        titleBeforeEdit = existing.title
        editingSeed = seed
        if let seed {
            // Type-to-edit: first keystroke replaces the old title.
            editingDraft = seed
            editingSelectAll = false
            applyTitleLive(id: target, raw: seed)
        } else {
            editingDraft = existing.title
            editingSelectAll = selectAll
        }
        editingID = target
    }

    /// Keep the draft in sync as the user types (does not re-layout by itself).
    public func updateEditingDraft(_ raw: String) {
        editingDraft = raw
    }

    /// Write title into the tree while typing. Preserves spaces (including trailing) so
    /// the user can type multi-word titles; full normalize runs on commit.
    public func applyTitleLive(id: UUID, raw: String) {
        let title = liveNormalizedTitle(raw)
        guard let existing = node(id: id), existing.title != title else { return }
        _ = updateNode(id: id) { $0.title = title }
        markDirty()
    }

    public func commitEditing(title: String? = nil) {
        guard let editingID else { return }
        let nodeID = editingID
        let before = titleBeforeEdit
        // Prefer an explicit title, then the live draft, then whatever is already on the node
        // (avoids wiping a programmatic rename with a stale empty draft).
        let raw = title ?? (editingDraft.isEmpty ? nil : editingDraft) ?? node(id: nodeID)?.title ?? before
        // Commit uses full normalize (trim ends, collapse runs); live typing keeps spaces.
        let committed = normalizedTitle(raw, for: nodeID)
        if node(id: nodeID)?.title != committed {
            _ = updateNode(id: nodeID) { $0.title = committed }
            markDirty()
        }
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
                target.markDirty()
                target.structureEpoch &+= 1
                target.historyEpoch &+= 1
                target.undoManager.registerUndo(withTarget: target) { redo in
                    _ = redo.updateNode(id: nodeID) { $0.title = after }
                    redo.selectedID = nodeID
                    redo.editingID = nil
                    redo.markDirty()
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

    /// Keep intentional newlines and spaces (including trailing) while typing.
    private func liveNormalizedTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func normalizedTitle(_ raw: String, for id: UUID) -> String {
        // Fully blank (only spaces/newlines) → placeholder.
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (id == root.id) ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
        }
        // Preserve line boundaries while collapsing repeated spaces within each line.
        let lines = liveNormalizedTitle(raw).components(separatedBy: "\n")
        let normalizedLines = lines.map { line in
            var result = ""
            var previousWasSpace = false
            for ch in line {
                if ch == " " {
                    if !previousWasSpace {
                        result.append(ch)
                        previousWasSpace = true
                    }
                } else {
                    result.append(ch)
                    previousWasSpace = false
                }
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        return normalizedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback for Shift-Return when the title editor temporarily loses first responder.
    public func insertNewlineInTitle() {
        guard let editingID else { return }
        let next = editingDraft + "\n"
        updateEditingDraft(next)
        applyTitleLive(id: editingID, raw: next)
    }

    // MARK: - Node notes

    public func note(for id: UUID? = nil) -> NodeNote? {
        let target = id ?? selectedID ?? root.id
        return node(id: target)?.note
    }

    /// Discrete body replacement. Interactive editors should use
    /// begin/update/commit below to coalesce typing into one undo action.
    @discardableResult
    public func setNoteBody(_ body: String, for id: UUID? = nil) throws -> Bool {
        let target = try resolveNoteTarget(id)
        let normalized = NodeNote.normalizeLineEndings(body)
        return try performNoteMutation(id: target, named: "Edit Note") { note in
            note.bodyMarkdown = normalized
        }
    }

    @discardableResult
    public func setNoteVisibility(
        _ visibility: NodeNoteVisibility,
        for id: UUID? = nil
    ) -> Bool {
        let target = id ?? selectedID ?? root.id
        guard let current = node(id: target)?.note, current.visibility != visibility else {
            return false
        }
        return (try? performNoteMutation(id: target, named: "Change Note Visibility") { note in
            note.visibility = visibility
        }) ?? false
    }

    @discardableResult
    public func addNoteImage(
        _ data: Data,
        altText: String,
        caption: String? = nil,
        for id: UUID? = nil
    ) throws -> UUID {
        let target = try resolveNoteTarget(id)
        let attachmentPath = "\(notePath(for: target)).attachments"
        let image = try NodeNoteImageNormalizer.normalize(
            data,
            altText: altText,
            caption: caption,
            path: attachmentPath
        )
        try performNoteMutation(id: target, named: "Add Note Image") { note in
            note.attachments.append(.image(image))
        }
        return image.id
    }

    /// Normalizes an image for an editor-owned two-phase insertion.
    ///
    /// The rich-text editor renders this attachment before committing it to
    /// the tree, avoiding an observation refresh between model mutation and
    /// TextKit's local insertion.
    func prepareNoteImageForEditor(
        _ data: Data,
        altText: String,
        caption: String? = nil,
        for id: UUID
    ) throws -> NoteImageAttachment {
        let target = try resolveNoteTarget(id)
        return try NodeNoteImageNormalizer.normalize(
            data,
            altText: altText,
            caption: caption,
            path: "\(notePath(for: target)).attachments"
        )
    }

    /// Appends a prepared image without ending the active coalesced note edit.
    ///
    /// Document-level undo is registered once when the editor session commits;
    /// TextKit owns local image undo/redo while the surface remains open.
    @discardableResult
    func commitPreparedNoteImageForEditor(
        _ image: NoteImageAttachment,
        for id: UUID
    ) throws -> Bool {
        let target = try resolveNoteTarget(id)
        var updated = node(id: target)?.note ?? NodeNote()
        updated.attachments.append(.image(image))
        updated = updated.canonicalized()

        // Reject capacity failures before beginning or switching the coalesced
        // session. A failed paste must not change selection or leave a hidden
        // note editor active.
        try NodeNoteValidator.validate(
            note: updated,
            path: notePath(for: target)
        )
        var candidateRoot = root
        _ = updateNode(id: target, in: &candidateRoot) {
            $0.note = updated
        }
        try NodeNoteValidator.validate(root: candidateRoot)

        if noteEditingID != target {
            beginNoteEditing(id: target)
        }
        guard noteEditingID == target else {
            throw NodeNoteValidationError(
                code: .nodeNotFound,
                path: notePath(for: target),
                message: "The node is no longer available for note editing."
            )
        }

        return try restoreNoteEditorTransaction(
            nodeID: target,
            note: updated
        )
    }

    @discardableResult
    public func addNoteYouTube(
        _ input: String,
        caption: String? = nil,
        for id: UUID? = nil
    ) throws -> UUID {
        let target = try resolveNoteTarget(id)
        let attachmentPath = "\(notePath(for: target)).attachments"
        let parsed = try YouTubeReferenceParser.parse(input, path: attachmentPath)
        let youtube = NoteYouTubeAttachment(
            videoID: parsed.videoID,
            startSeconds: parsed.startSeconds,
            caption: caption
        ).canonicalized()
        try performNoteMutation(id: target, named: "Add YouTube Video") { note in
            note.attachments.append(.youtube(youtube))
        }
        return youtube.id
    }

    /// Atomically replaces the note body and appends videos extracted from
    /// WYSIWYG text. Validation happens before any state is committed so a
    /// capacity failure leaves both the body and attachments unchanged.
    @discardableResult
    func embedNoteYouTubeLinks(
        _ inputs: [String],
        bodyMarkdown: String,
        for id: UUID? = nil
    ) throws -> [UUID] {
        let target = try resolveNoteTarget(id)
        let attachmentPath = "\(notePath(for: target)).attachments"
        let videos = try inputs.enumerated().map { index, input in
            let parsed = try YouTubeReferenceParser.parse(
                input,
                path: "\(attachmentPath)[\(index)]"
            )
            return NoteYouTubeAttachment(
                videoID: parsed.videoID,
                startSeconds: parsed.startSeconds
            ).canonicalized()
        }
        guard !videos.isEmpty else { return [] }

        try performNoteMutation(
            id: target,
            named: videos.count == 1
                ? "Embed YouTube Video"
                : "Embed YouTube Videos"
        ) { note in
            note.bodyMarkdown = NodeNote.normalizeLineEndings(bodyMarkdown)
            note.attachments.append(contentsOf: videos.map(NodeNoteAttachment.youtube))
        }
        return videos.map(\.id)
    }

    /// Replace an attachment with the same stable id (for alt text, caption,
    /// start-time, or future metadata editing).
    @discardableResult
    public func replaceNoteAttachment(
        _ attachment: NodeNoteAttachment,
        for id: UUID? = nil
    ) throws -> Bool {
        let target = try resolveNoteTarget(id)
        guard let note = node(id: target)?.note,
              note.attachments.contains(where: { $0.id == attachment.id })
        else {
            throw NodeNoteValidationError(
                code: .attachmentNotFound,
                path: "\(notePath(for: target)).attachments",
                message: "The note attachment no longer exists."
            )
        }
        return try performNoteMutation(id: target, named: "Edit Note Attachment") { note in
            guard let index = note.attachments.firstIndex(where: { $0.id == attachment.id }) else {
                return
            }
            note.attachments[index] = attachment
        }
    }

    @discardableResult
    public func removeNoteAttachment(
        _ attachmentID: UUID,
        from nodeID: UUID? = nil
    ) -> Bool {
        let target = nodeID ?? selectedID ?? root.id
        guard node(id: target)?.note?.attachments.contains(where: { $0.id == attachmentID }) == true
        else {
            return false
        }
        return (try? performNoteMutation(id: target, named: "Remove Note Attachment") { note in
            note.attachments.removeAll { $0.id == attachmentID }
        }) ?? false
    }

    @discardableResult
    public func moveNoteAttachment(
        _ attachmentID: UUID,
        to index: Int,
        in nodeID: UUID? = nil
    ) -> Bool {
        let target = nodeID ?? selectedID ?? root.id
        guard let note = node(id: target)?.note,
              let from = note.attachments.firstIndex(where: { $0.id == attachmentID }),
              !note.attachments.isEmpty
        else {
            return false
        }
        let destination = max(0, min(index, note.attachments.count - 1))
        guard from != destination else { return false }
        return (try? performNoteMutation(id: target, named: "Reorder Note Attachment") { note in
            guard let current = note.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                return
            }
            let moving = note.attachments.remove(at: current)
            note.attachments.insert(moving, at: destination)
        }) ?? false
    }

    @discardableResult
    public func clearNote(for id: UUID? = nil) -> Bool {
        let target = id ?? selectedID ?? root.id
        guard node(id: target)?.note != nil else { return false }
        if noteEditingID != nil {
            commitNoteEditing()
        }
        let before = node(id: target)?.note
        guard updateNode(id: target, { $0.note = nil }) else { return false }
        markDirty()
        noteEpoch &+= 1
        registerNoteUndo(
            nodeID: target,
            before: before,
            after: nil,
            actionName: "Clear Note"
        )
        scheduleNoteAutosave()
        return true
    }

    /// Start a live body-editing session. Attachments and visibility remain in
    /// the tree while the body draft changes.
    public func beginNoteEditing(id: UUID? = nil) {
        let target = id ?? selectedID ?? root.id
        guard let currentNode = node(id: target) else { return }
        if noteEditingID == target { return }
        if noteEditingID != nil {
            commitNoteEditing()
        }
        if isEditing {
            commitEditing()
        }
        selectedID = target
        noteEditingID = target
        noteEditingDraft = currentNode.note?.bodyMarkdown ?? ""
        noteBeforeEdit = currentNode.note
        noteEditStartContentRevision = contentRevision
        noteEditStartWasDirty = isDirty
    }

    /// Apply a note draft for immediate preview and crash recovery without
    /// creating an undo record for every keystroke.
    public func updateNoteEditingDraft(_ body: String) throws {
        guard let target = noteEditingID else { return }
        let normalized = NodeNote.normalizeLineEndings(body)
        var candidateNote = node(id: target)?.note ?? NodeNote()
        candidateNote.bodyMarkdown = normalized
        candidateNote = candidateNote.canonicalized()
        try NodeNoteValidator.validateBody(
            candidateNote.bodyMarkdown,
            path: "\(notePath(for: target)).bodyMarkdown"
        )

        let storedNote: NodeNote? = candidateNote.isEmpty ? nil : candidateNote

        noteEditingDraft = normalized
        guard node(id: target)?.note != storedNote else { return }
        _ = updateNode(id: target) { $0.note = storedNote }
        markDirty()
        noteEpoch &+= 1
        scheduleNoteAutosave()
    }

    /// Restore an exact editor-owned note snapshot without consuming or
    /// registering document-level undo. TextKit uses this for local attachment
    /// transactions; the enclosing coalesced note session remains responsible
    /// for its eventual document undo entry.
    @discardableResult
    func restoreNoteEditorTransaction(
        nodeID: UUID,
        note: NodeNote?
    ) throws -> Bool {
        guard let existingNode = node(id: nodeID) else {
            throw NodeNoteValidationError(
                code: .nodeNotFound,
                path: notePath(for: nodeID),
                message: "The node no longer exists."
            )
        }

        let canonical = note?.canonicalized()
        let restoredNote = canonical?.isEmpty == true ? nil : canonical
        if let restoredNote {
            try NodeNoteValidator.validate(
                note: restoredNote,
                path: notePath(for: nodeID)
            )
        }
        guard existingNode.note != restoredNote else { return false }

        var candidateRoot = root
        _ = updateNode(id: nodeID, in: &candidateRoot) {
            $0.note = restoredNote
        }
        try NodeNoteValidator.validate(root: candidateRoot)

        _ = updateNode(id: nodeID) { $0.note = restoredNote }
        if noteEditingID == nodeID {
            // Retain `noteBeforeEdit` and the starting dirty/revision counters:
            // local undo/redo is still part of the same coalesced edit session.
            noteEditingDraft = restoredNote?.bodyMarkdown ?? ""
        }
        markDirty()
        noteEpoch &+= 1
        scheduleNoteAutosave()
        return true
    }

    /// Finish a live note edit and register the complete session as one undo.
    public func commitNoteEditing() {
        guard let target = noteEditingID else { return }
        let before = noteBeforeEdit
        let after = node(id: target)?.note
        let startRevision = noteEditStartContentRevision
        let startWasDirty = noteEditStartWasDirty
        clearNoteEditingState()

        guard before != after else {
            restoreNoteEditCounters(revision: startRevision, wasDirty: startWasDirty)
            // A modified draft may already be the current recovery payload.
            // Once the edit returns to its original value, replace that
            // payload before advertising the restored clean revision.
            performAutosave()
            return
        }
        registerNoteUndo(
            nodeID: target,
            before: before,
            after: after,
            actionName: "Edit Note"
        )
        scheduleNoteAutosave()
    }

    public func cancelNoteEditing() {
        guard let target = noteEditingID else { return }
        let before = noteBeforeEdit
        let startRevision = noteEditStartContentRevision
        let startWasDirty = noteEditStartWasDirty
        let changed = node(id: target)?.note != before
        if changed {
            _ = updateNode(id: target) { $0.note = before }
            noteEpoch &+= 1
        }
        clearNoteEditingState()
        restoreNoteEditCounters(revision: startRevision, wasDirty: startWasDirty)
        // Cancellation restores the original tree and revision immediately;
        // keep the crash-recovery payload equally authoritative.
        performAutosave()
    }

    @discardableResult
    private func performNoteMutation(
        id: UUID,
        named actionName: String,
        _ mutate: (inout NodeNote) -> Void
    ) throws -> Bool {
        if noteEditingID != nil {
            commitNoteEditing()
        }
        if isEditing {
            commitEditing()
        }
        guard let existingNode = node(id: id) else {
            throw NodeNoteValidationError(
                code: .nodeNotFound,
                path: notePath(for: id),
                message: "The node no longer exists."
            )
        }
        let before = existingNode.note
        var candidate = before ?? NodeNote()
        mutate(&candidate)
        candidate = candidate.canonicalized()
        try NodeNoteValidator.validate(note: candidate, path: notePath(for: id))
        let after: NodeNote? = candidate.isEmpty ? nil : candidate
        guard after != before else { return false }

        var candidateRoot = root
        _ = updateNode(id: id, in: &candidateRoot) { $0.note = after }
        try NodeNoteValidator.validate(root: candidateRoot)

        _ = updateNode(id: id) { $0.note = after }
        selectedID = id
        markDirty()
        noteEpoch &+= 1
        registerNoteUndo(
            nodeID: id,
            before: before,
            after: after,
            actionName: actionName
        )
        scheduleNoteAutosave()
        return true
    }

    private func registerNoteUndo(
        nodeID: UUID,
        before: NodeNote?,
        after: NodeNote?,
        actionName: String
    ) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreNoteState(
                before,
                nodeID: nodeID,
                inverse: after,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        historyEpoch &+= 1
    }

    private func restoreNoteState(
        _ note: NodeNote?,
        nodeID: UUID,
        inverse: NodeNote?,
        actionName: String
    ) {
        _ = updateNode(id: nodeID) { $0.note = note }
        selectedID = nodeID
        clearNoteEditingState()
        markDirty()
        noteEpoch &+= 1
        historyEpoch &+= 1
        scheduleNoteAutosave()
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreNoteState(
                inverse,
                nodeID: nodeID,
                inverse: note,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    private func resolveNoteTarget(_ id: UUID?) throws -> UUID {
        let target = id ?? selectedID ?? root.id
        guard node(id: target) != nil else {
            throw NodeNoteValidationError(
                code: .nodeNotFound,
                path: notePath(for: target),
                message: "The node no longer exists."
            )
        }
        return target
    }

    private func notePath(for id: UUID) -> String {
        "$.nodes[\"\(id.uuidString)\"].note"
    }

    private func clearNoteEditingState() {
        noteEditingID = nil
        noteEditingDraft = ""
        noteBeforeEdit = nil
        noteEditStartContentRevision = contentRevision
        noteEditStartWasDirty = isDirty
    }

    private func restoreNoteEditCounters(revision: Int, wasDirty: Bool) {
        contentRevision = revision
        isDirty = wasDirty
        DocumentSession.shared.updateDirtyState(
            id: documentID,
            isDirty: isDirty,
            contentRevision: contentRevision,
            savedRevision: savedRevision
        )
    }

    private func scheduleNoteAutosave() {
        cancelPendingNoteAutosave()
        noteAutosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.noteAutosaveTask = nil
            self?.performAutosave()
        }
    }

    /// Cancel a delayed note recovery write before document/session teardown.
    /// `performAutosave()` also calls this because its synchronous write
    /// consumes the pending request.
    func cancelPendingNoteAutosave() {
        noteAutosaveTask?.cancel()
        noteAutosaveTask = nil
    }

    // MARK: - Tree mutations (BrainstormNode-style)

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

        // Empty title + edit mode so the user types immediately (BrainstormNode).
        let newNode = BrainstormNode(title: "")
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

        let newNode = BrainstormNode(title: "")
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
            let wrapper = BrainstormNode(
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
            self.editingDraft = ""
            self.titleBeforeEdit = ""
        }
    }

    /// While editing an empty title, ⌫ deletes the node and selects the previous sibling
    /// (or parent). Root is never deleted. Returns `true` when the key was handled.
    @discardableResult
    public func deleteEmptyEditingNode() -> Bool {
        guard let editingID else { return false }
        let draftEmpty = editingDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard draftEmpty else { return false }
        // Never remove the main/root node — leave the empty field alone.
        guard editingID != root.id else { return false }

        let removing = editingID
        let parent = parentID(of: removing)
        let siblings = parent.flatMap { node(id: $0)?.children.map(\.id) } ?? []
        let index = siblings.firstIndex(of: removing) ?? 0
        // Prefer previous sibling (outliner-style), else parent.
        let fallback: UUID? = {
            if index > 0 { return siblings[index - 1] }
            return parent
        }()

        // Drop the edit session without committing a placeholder title.
        self.editingID = nil
        self.editingSeed = nil
        self.editingDraft = ""
        self.titleBeforeEdit = ""

        performUndoable(named: "Delete Node") {
            _ = self.removeNode(id: removing)
            self.selectedID = fallback
            self.editingID = nil
            self.editingSeed = nil
            self.editingDraft = ""
            self.titleBeforeEdit = ""
        }
        return true
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

    /// Esc when not editing — clear selection (BrainstormNode deselect).
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

    /// Drag a node onto another to change its parent (BrainstormNode rewire).
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

    private func contains(id: UUID, in node: BrainstormNode) -> Bool {
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

    /// ← — move selection to parent (BrainstormNode canvas; fold is ⌥. separately).
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
        reorderAmongSiblings(nodeID: selectedID, toIndex: newIndex)
    }

    /// Move a node to a new index among its siblings, shifting the intervening range.
    /// When that range contains custom-positioned nodes, their visible canvas
    /// positions rotate with the order instead of snapping to automatic slots.
    /// - Parameter toIndex: Desired final index in the parent’s `children` array (0…count-1).
    public func reorderAmongSiblings(nodeID: UUID, toIndex: Int) {
        guard nodeID != root.id else { return }
        guard let parentNodeID = parentID(of: nodeID) else { return }
        guard let parent = node(id: parentNodeID) else { return }
        guard let from = parent.children.firstIndex(where: { $0.id == nodeID }) else { return }
        let clamped = max(0, min(toIndex, parent.children.count - 1))
        guard from != clamped else { return }

        if isEditing { commitEditing() }
        let movingID = nodeID
        let parentID = parentNodeID
        let fromIndex = from
        let toIdx = clamped
        let siblingIDsBefore = parent.children.map(\.id)
        let affectedRange = min(fromIndex, toIdx)...max(fromIndex, toIdx)

        // Manual offsets are relative to automatic slots, so changing sibling
        // order would otherwise move every custom-positioned item. Capture
        // positions relative to the root, which is stable even when the canvas
        // normalizes negative coordinates back into its padded bounds.
        let beforeLayout = LayoutEngine().layout(root: root)
        let beforeOrigins = Dictionary(
            uniqueKeysWithValues: beforeLayout.nodes.map { ($0.id, $0.frame.origin) }
        )
        let manualIDs = Set(parent.children.filter(\.hasManualPosition).map(\.id))
        var positionedIDs = manualIDs
        let affectedIDs = Set(affectedRange.map { siblingIDsBefore[$0] })
        let rotatesCustomPositions = !manualIDs.isDisjoint(with: affectedIDs)
        if rotatesCustomPositions {
            positionedIDs.formUnion(affectedIDs)
        }

        var beforeRelativeOrigins: [UUID: CGPoint] = [:]
        if let rootOrigin = beforeOrigins[root.id] {
            for id in positionedIDs {
                guard let origin = beforeOrigins[id] else { continue }
                beforeRelativeOrigins[id] = CGPoint(
                    x: origin.x - rootOrigin.x,
                    y: origin.y - rootOrigin.y
                )
            }
        }
        var desiredRelativeOrigins = beforeRelativeOrigins
        if rotatesCustomPositions {
            var siblingIDsAfter = siblingIDsBefore
            let movedID = siblingIDsAfter.remove(at: fromIndex)
            siblingIDsAfter.insert(movedID, at: toIdx)
            for index in affectedRange {
                let newOccupantID = siblingIDsAfter[index]
                let oldOccupantID = siblingIDsBefore[index]
                desiredRelativeOrigins[newOccupantID] = beforeRelativeOrigins[oldOccupantID]
            }
        }

        performUndoable(named: "Reorder") {
            _ = self.updateNode(id: parentID) { node in
                let item = node.children.remove(at: fromIndex)
                node.children.insert(item, at: toIdx)
            }

            if !desiredRelativeOrigins.isEmpty {
                // Measure the new automatic slots first, then express each
                // desired canvas position as an offset from its new slot.
                for id in desiredRelativeOrigins.keys {
                    _ = self.updateNode(id: id) { node in
                        node.offsetX = nil
                        node.offsetY = nil
                    }
                }
                let automaticLayout = LayoutEngine().layout(root: self.root)
                let automaticOrigins = Dictionary(
                    uniqueKeysWithValues: automaticLayout.nodes.map { ($0.id, $0.frame.origin) }
                )
                if let rootOrigin = automaticOrigins[self.root.id] {
                    for (id, relativeOrigin) in desiredRelativeOrigins {
                        guard let automaticOrigin = automaticOrigins[id] else { continue }
                        let offsetX = rootOrigin.x + relativeOrigin.x - automaticOrigin.x
                        let offsetY = rootOrigin.y + relativeOrigin.y - automaticOrigin.y
                        _ = self.updateNode(id: id) { node in
                            node.offsetX = abs(offsetX) < 0.01 ? nil : Double(offsetX)
                            node.offsetY = abs(offsetY) < 0.01 ? nil : Double(offsetY)
                        }
                    }
                }
            }
            self.selectedID = movingID
            self.editingID = nil
            self.editingSeed = nil
        }
    }

    /// Sibling ids under the same parent as `nodeID` (including itself), in order. Empty if root / missing.
    public func siblingIDs(of nodeID: UUID) -> [UUID] {
        guard nodeID != root.id, let parentNodeID = parentID(of: nodeID),
              let parent = node(id: parentNodeID)
        else { return [] }
        return parent.children.map(\.id)
    }

    /// Current index among siblings, or `nil` for root / missing.
    public func siblingIndex(of nodeID: UUID) -> Int? {
        guard nodeID != root.id, let parentNodeID = parentID(of: nodeID),
              let parent = node(id: parentNodeID)
        else { return nil }
        return parent.children.firstIndex(where: { $0.id == nodeID })
    }


    // MARK: - Style / media / position

    public func updateStyle(for id: UUID? = nil, _ mutate: (inout NodeStyle) -> Void) {
        let targets: [UUID]
        if let id {
            targets = [id]
        } else {
            let validSelection = selectedIDs.filter { node(id: $0) != nil }
            targets = validSelection.isEmpty ? [ensureSelection()] : Array(validSelection)
        }
        if isEditing { commitEditing() }
        performUndoable(named: "Style") {
            for target in targets {
                _ = self.updateNode(id: target) { node in
                    mutate(&node.style)
                }
            }
        }
    }

    public func setFillColor(_ hex: String?) {
        updateStyle { style in
            let value = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fill = (value?.isEmpty == false) ? value : nil
            style.fillHex = fill
            // Leave text nil so it tracks theme (or auto-contrasts against a custom fill at render).
            // Only clear auto/contrast text that was previously baked in.
            if style.textHex == ColorContrast.lightTextHex
                || style.textHex == ColorContrast.darkTextHex
                || style.textHex == nil
            {
                style.textHex = nil
            }
        }
    }

    public func setTextColor(_ hex: String?) {
        updateStyle { style in
            let value = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty / "Auto" → nil (theme text, or contrast against custom fill at render).
            if value == nil || value?.isEmpty == true {
                style.textHex = nil
            } else {
                style.textHex = value
            }
        }
    }

    public func setBranchColor(_ hex: String?) {
        updateStyle { style in
            let value = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
            style.branchHex = (value?.isEmpty == false) ? value : nil
        }
    }

    public func setBorderColor(_ hex: String?) {
        updateStyle { style in
            let value = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
            style.borderHex = (value?.isEmpty == false) ? value : nil
        }
    }

    public func setBorderWidth(_ width: Double?) {
        updateStyle { style in
            guard let width, width > 0 else {
                style.borderWidth = nil
                return
            }
            style.borderWidth = min(6, width)
        }
    }

    public func setShape(_ shape: NodeShape) {
        updateStyle { $0.shape = shape }
    }

    public func setFontSize(_ size: Double?) {
        updateStyle { $0.fontSize = size }
    }

    public func toggleBold() {
        setBold(!(selectedNode?.style.isBold ?? false))
    }

    public func toggleItalic() {
        setItalic(!(selectedNode?.style.isItalic ?? false))
    }

    public func setBold(_ enabled: Bool) {
        updateStyle { $0.isBold = enabled }
    }

    public func setItalic(_ enabled: Bool) {
        updateStyle { $0.isItalic = enabled }
    }

    /// Emojis currently used anywhere in the document (for shortlist enrichment).
    public func documentEmojis() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func walk(_ n: BrainstormNode) {
            if let raw = n.media.emoji {
                let e = EmojiUsageStore.normalize(raw)
                if !e.isEmpty, seen.insert(e).inserted {
                    result.append(e)
                }
            }
            for child in n.children { walk(child) }
        }
        walk(root)
        return result
    }

    /// Set emoji on the selection. Passing the same emoji again (or `nil` / empty) clears it.
    /// Clears sticker/image — only one media kind at a time.
    public func setEmoji(_ emoji: String?) {
        let target = ensureSelection()
        if isEditing { commitEditing() }
        let incoming: String? = {
            guard let raw = emoji else { return nil }
            let n = EmojiUsageStore.normalize(raw)
            return n.isEmpty ? nil : n
        }()
        let current: String? = {
            guard let raw = node(id: target)?.media.emoji else { return nil }
            let n = EmojiUsageStore.normalize(raw)
            return n.isEmpty ? nil : n
        }()
        // Re-pick or clear → remove emoji from the node.
        let next: String? = (incoming != nil && incoming == current) ? nil : incoming
        let before = node(id: target)?.media ?? .empty
        var after = before
        after.setExclusiveEmoji(next)
        guard after != before else { return }
        performUndoable(named: next == nil ? "Clear Emoji" : "Set Emoji") {
            _ = self.updateNode(id: target) { node in
                node.media = after
            }
            self.selectedID = target
        }
        if let next {
            EmojiUsageStore.shared.record(next)
        }
    }

    /// Set SF Symbol sticker. Passing the same symbol again (or `nil` / empty) clears it.
    /// Clears emoji/image — only one media kind at a time.
    public func setSticker(_ symbol: String?) {
        let target = ensureSelection()
        if isEditing { commitEditing() }
        let trimmed = symbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = (trimmed?.isEmpty == false) ? trimmed : nil
        let current = node(id: target)?.media.sticker
        let next: String? = (incoming != nil && incoming == current) ? nil : incoming
        let before = node(id: target)?.media ?? .empty
        var after = before
        after.setExclusiveSticker(next)
        guard after != before else { return }
        performUndoable(named: next == nil ? "Clear Sticker" : "Set Sticker") {
            _ = self.updateNode(id: target) { node in
                node.media = after
            }
            self.selectedID = target
        }
    }

    /// Embed a PNG image. Clears emoji/sticker — only one media kind at a time.
    public func setImagePNGData(_ data: Data?) {
        let target = ensureSelection()
        if isEditing { commitEditing() }
        let encoded = data.map { $0.base64EncodedString() }
        let before = node(id: target)?.media ?? .empty
        var after = before
        after.setExclusiveImageBase64(encoded)
        guard after != before else { return }
        performUndoable(named: encoded == nil ? "Clear Image" : "Set Image") {
            _ = self.updateNode(id: target) { node in
                node.media = after
            }
            self.selectedID = target
        }
    }

    public func clearMedia() {
        let target = ensureSelection()
        if isEditing { commitEditing() }
        guard node(id: target)?.media.isEmpty == false else { return }
        performUndoable(named: "Clear Media") {
            _ = self.updateNode(id: target) { node in
                node.media = .empty
            }
            self.selectedID = target
        }
    }

    /// Apply a free-position delta (document points) on top of automatic layout.
    public func setManualOffset(id: UUID? = nil, x: Double?, y: Double?) {
        let target = id ?? ensureSelection()
        performUndoable(named: "Move Node") {
            _ = self.updateNode(id: target) { node in
                node.offsetX = x
                node.offsetY = y
            }
            self.selectedID = target
        }
    }

    /// Live drag update (no undo until `commitManualOffset`).
    public func applyManualOffsetLive(id: UUID, x: Double, y: Double) {
        _ = updateNode(id: id) { node in
            node.offsetX = x
            node.offsetY = y
        }
        structureEpoch &+= 1
        markDirty()
    }

    public func commitManualOffset(id: UUID, from before: CGSize) {
        let afterX = node(id: id)?.offsetX ?? 0
        let afterY = node(id: id)?.offsetY ?? 0
        let beforeX = Double(before.width)
        let beforeY = Double(before.height)
        guard abs(afterX - beforeX) > 0.01 || abs(afterY - beforeY) > 0.01 else { return }
        let nodeID = id
        let storedBeforeX: Double? = abs(beforeX) < 0.01 ? nil : beforeX
        let storedBeforeY: Double? = abs(beforeY) < 0.01 ? nil : beforeY
        let storedAfterX: Double? = abs(afterX) < 0.01 ? nil : afterX
        let storedAfterY: Double? = abs(afterY) < 0.01 ? nil : afterY
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            _ = target.updateNode(id: nodeID) { node in
                node.offsetX = storedBeforeX
                node.offsetY = storedBeforeY
            }
            target.selectedID = nodeID
            target.structureEpoch &+= 1
            target.markDirty()
            target.historyEpoch &+= 1
            target.undoManager.registerUndo(withTarget: target) { redo in
                _ = redo.updateNode(id: nodeID) { node in
                    node.offsetX = storedAfterX
                    node.offsetY = storedAfterY
                }
                redo.selectedID = nodeID
                redo.structureEpoch &+= 1
                redo.markDirty()
                redo.historyEpoch &+= 1
            }
            target.undoManager.setActionName("Move Node")
        }
        undoManager.setActionName("Move Node")
        undoManager.endUndoGrouping()
        historyEpoch &+= 1
    }

    /// Nudge manual position by document points (⌥ + arrows).
    public func nudgeSelected(dx: Double, dy: Double) {
        let target = ensureSelection()
        if isEditing { commitEditing() }
        let current = node(id: target)
        let nx = (current?.offsetX ?? 0) + dx
        let ny = (current?.offsetY ?? 0) + dy
        performUndoable(named: "Nudge Node") {
            _ = self.updateNode(id: target) { node in
                node.offsetX = abs(nx) < 0.01 ? nil : nx
                node.offsetY = abs(ny) < 0.01 ? nil : ny
            }
            self.selectedID = target
        }
    }

    public func resetPosition(id: UUID? = nil) {
        let target = id ?? ensureSelection()
        guard let n = node(id: target), n.hasManualPosition else { return }
        if isEditing { commitEditing() }
        performUndoable(named: "Reset Position") {
            _ = self.updateNode(id: target) { node in
                node.offsetX = nil
                node.offsetY = nil
            }
            self.selectedID = target
        }
    }

    public func resetAllPositions() {
        if isEditing { commitEditing() }
        performUndoable(named: "Reset All Positions") {
            self.clearOffsets(in: &self.root)
        }
    }

    private func clearOffsets(in node: inout BrainstormNode) {
        node.offsetX = nil
        node.offsetY = nil
        for i in node.children.indices {
            clearOffsets(in: &node.children[i])
        }
    }

    // MARK: - Focus mode

    public func toggleFocusMode() {
        isFocusMode.toggle()
        if isFocusMode {
            _ = ensureSelection()
        }
    }

    /// IDs that stay fully visible in focus mode:
    /// ancestors of selection, selection subtree, and **siblings** of the selection
    /// (same parent, same level) — but not the siblings' children.
    public func focusVisibleIDs() -> Set<UUID> {
        guard isFocusMode else { return Set(visibleIDs()) }
        let selected = ensureSelection()
        var set = Set<UUID>()
        // Ancestors (includes selection itself as we walk up)
        var current: UUID? = selected
        while let id = current {
            set.insert(id)
            current = parentID(of: id)
        }
        // Descendants of selection (branch under focus)
        if let node = node(id: selected) {
            collectAll(from: node, into: &set)
        }
        // Peers at the same level: siblings only, not their subtrees
        if let parent = parentID(of: selected), let parentNode = node(id: parent) {
            for sibling in parentNode.children {
                set.insert(sibling.id)
            }
        }
        return set
    }

    private func collectAll(from node: BrainstormNode, into set: inout Set<UUID>) {
        set.insert(node.id)
        for child in node.children {
            collectAll(from: child, into: &set)
        }
    }

    // MARK: - Zoom

    public func setZoom(_ scale: CGFloat) {
        viewport.setZoom(scale)
    }

    public func zoomIn() { viewport.zoomIn() }
    public func zoomOut() { viewport.zoomOut() }
    public func zoomReset() { viewport.zoomReset() }

    // MARK: - Search

    public func updateSearchQuery(_ query: String) {
        searchQuery = query
        rebuildSearchMatches()
    }

    public func clearSearch() {
        searchQuery = ""
        searchMatchIDs = []
        searchMatchIndex = 0
    }

    public func selectNextSearchMatch() {
        guard !searchMatchIDs.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex + 1) % searchMatchIDs.count
        select(searchMatchIDs[searchMatchIndex])
        if isFocusMode { /* keep */ }
    }

    public func selectPreviousSearchMatch() {
        guard !searchMatchIDs.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex - 1 + searchMatchIDs.count) % searchMatchIDs.count
        select(searchMatchIDs[searchMatchIndex])
    }

    private func rebuildSearchMatches() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchMatchIDs = []
            searchMatchIndex = 0
            return
        }
        let needle = q.lowercased()
        var matches: [UUID] = []
        collectSearchMatches(from: root, needle: needle, into: &matches)
        searchMatchIDs = matches
        if let selectedID, let idx = matches.firstIndex(of: selectedID) {
            searchMatchIndex = idx
        } else {
            searchMatchIndex = 0
            if let first = matches.first {
                select(first)
            }
        }
    }

    private func collectSearchMatches(from node: BrainstormNode, needle: String, into result: inout [UUID]) {
        if node.title.lowercased().contains(needle) {
            result.append(node.id)
        }
        for child in node.children {
            collectSearchMatches(from: child, needle: needle, into: &result)
        }
    }

    // MARK: - Tree helpers

    public func node(id: UUID) -> BrainstormNode? {
        find(id: id, in: root)
    }

    public func parentID(of id: UUID) -> UUID? {
        findParent(of: id, in: root)?.id
    }

    private func collectVisible(from node: BrainstormNode, into result: inout [UUID]) {
        result.append(node.id)
        guard node.isExpanded else { return }
        for child in node.children {
            collectVisible(from: child, into: &result)
        }
    }

    private func find(id: UUID, in node: BrainstormNode) -> BrainstormNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private func findParent(of id: UUID, in node: BrainstormNode) -> BrainstormNode? {
        if node.children.contains(where: { $0.id == id }) { return node }
        for child in node.children {
            if let found = findParent(of: id, in: child) { return found }
        }
        return nil
    }

    @discardableResult
    private func updateNode(id: UUID, _ body: (inout BrainstormNode) -> Void) -> Bool {
        updateNode(id: id, in: &root, body)
    }

    @discardableResult
    private func updateNode(
        id: UUID,
        in node: inout BrainstormNode,
        _ body: (inout BrainstormNode) -> Void
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
    private func removeNode(id: UUID) -> BrainstormNode? {
        removeNode(id: id, from: &root)
    }

    private func removeNode(id: UUID, from node: inout BrainstormNode) -> BrainstormNode? {
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
        node newNode: BrainstormNode,
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
        if noteEditingID != nil {
            commitNoteEditing()
        }
        let beforeRoot = root
        let beforeSelected = selectedID
        let beforeSelection = selectedIDs

        body()
        markDirty()
        structureEpoch &+= 1

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreState(
                root: beforeRoot,
                selected: beforeSelected,
                selection: beforeSelection,
                actionName: name
            )
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        historyEpoch &+= 1
    }

    private func restoreState(
        root newRoot: BrainstormNode,
        selected: UUID?,
        selection: Set<UUID>,
        actionName: String
    ) {
        let previousRoot = root
        let previousSelected = selectedID
        let previousSelection = selectedIDs

        root = newRoot
        let validSelection = Set(selection.filter { node(id: $0) != nil })
        let validPrimary = selected.flatMap { node(id: $0) == nil ? nil : $0 }
        setSelection(primary: validPrimary, ids: validSelection)
        // Never re-enter a stale edit session after undo/redo.
        editingID = nil
        editingSeed = nil
        editingDraft = ""
        titleBeforeEdit = ""
        markDirty()
        structureEpoch &+= 1
        historyEpoch &+= 1

        undoManager.registerUndo(withTarget: self) { target in
            target.restoreState(
                root: previousRoot,
                selected: previousSelected,
                selection: previousSelection,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }
}

// MARK: - Store cache (breaks State(initialValue:) re-eval thrash)

@MainActor
enum DocumentStoreCache {
    private static var stores: [UUID: BrainstormStore] = [:]

    static func store(for documentID: UUID) -> BrainstormStore {
        if let existing = stores[documentID] { return existing }
        let created = BrainstormStore(restoring: documentID)
        stores[documentID] = created
        return created
    }

    static func release(_ documentID: UUID) {
        stores[documentID] = nil
    }
}
