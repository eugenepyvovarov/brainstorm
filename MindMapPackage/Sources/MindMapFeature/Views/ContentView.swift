import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @State private var store = MindMapStore()
    /// Shared focus: `nil` = canvas shortcuts; UUID = that node’s title field.
    @FocusState private var focusedNodeID: UUID?
    @FocusState private var canvasFocused: Bool
    @State private var showKeyboardHelp = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            MindMapCanvasView(store: store, focusedNodeID: $focusedNodeID)
                .focusable(true)
                .focused($canvasFocused)
                .focusEffectDisabled()
                .focusSection()
                .onKeyPress(phases: .down) { keyPress in
                    handleKeyPress(keyPress)
                }

            keyboardStatusBar
        }
        .onAppear {
            store.ensureSelection()
            syncFocusWithEditingState()
        }
        .onChange(of: store.editingID) { _, newValue in
            syncFocusWithEditingState(editingID: newValue)
        }
        .onChange(of: store.selectedID) { _, _ in
            // After navigation, reclaim canvas focus so the next key isn't lost.
            if !store.isEditing {
                DispatchQueue.main.async {
                    self.canvasFocused = true
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    store.undo()
                    syncFocusWithEditingState()
                }
                .help("Undo (⌘Z)")
                .disabled(!store.canUndo)
                .focusable(false)

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    store.redo()
                    syncFocusWithEditingState()
                }
                .help("Redo (⌘⇧Z)")
                .disabled(!store.canRedo)
                .focusable(false)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Keyboard", systemImage: "keyboard") {
                    showKeyboardHelp = true
                }
                .help("Keyboard shortcuts (? or ⌘/)")
                .focusable(false)

                Button("New", systemImage: "doc.badge.plus") {
                    store.newDocument()
                    syncFocusWithEditingState()
                }
                .help("New mind map (⌘N)")
                .focusable(false)

                Button("Open", systemImage: "folder") {
                    openDocument()
                }
                .help("Open… (⌘O)")
                .focusable(false)

                Button("Save", systemImage: "square.and.arrow.down") {
                    saveDocument(saveAs: false)
                }
                .help("Save (⌘S)")
                .focusable(false)

                Button("Save As", systemImage: "square.and.arrow.down.on.square") {
                    saveDocument(saveAs: true)
                }
                .help("Save As…")
                .focusable(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mindMapUndo)) { _ in
            store.undo()
            syncFocusWithEditingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mindMapRedo)) { _ in
            store.redo()
            syncFocusWithEditingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mindMapShowKeyboardHelp)) { _ in
            showKeyboardHelp = true
        }
        .navigationTitle(store.documentTitle)
        .sheet(isPresented: $showKeyboardHelp) {
            KeyboardHelpSheet()
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        // Always-on key catcher: owns Tab and works even when a text field has focus.
        .background(
            KeyboardMonitor(
                store: store,
                onSave: { saveDocument(saveAs: $0) },
                onOpen: { openDocument() },
                onNew: {
                    store.newDocument()
                    syncFocusWithEditingState()
                },
                onShowHelp: { showKeyboardHelp = true }
            )
        )
        .help(MindNodeShortcuts.helpText)
    }

    /// Always-visible cheat strip so arrow-key navigation is obvious.
    private var keyboardStatusBar: some View {
        HStack(spacing: 16) {
            if store.isEditing {
                Label("Editing", systemImage: "character.cursor.ibeam")
                    .foregroundStyle(.secondary)
                statusHint("↑↓←→", "move")
                statusHint("⌘↩", "done")
                statusHint("Esc", "cancel")
                statusHint("Tab", "child")
                statusHint("↩", "sibling")
            } else {
                Label("Selected", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .foregroundStyle(.secondary)
                statusHint("↑↓", "siblings")
                statusHint("←", "parent")
                statusHint("→", "child")
                statusHint("⌘↩", "edit")
                statusHint("Tab", "child")
                statusHint("↩", "sibling")
            }
            Spacer(minLength: 8)
            Button("All shortcuts") {
                showKeyboardHelp = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open full keyboard guide (? or ⌘/)")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func statusHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Keyboard (secondary path; NSEvent monitor is primary)

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let mods = keyPress.modifiers
        let handled = MindMapKeyRouter.handle(
            store: store,
            key: MindMapKeyRouter.Key(
                keyCode: nil,
                characters: keyPress.characters,
                isTab: keyPress.key == .tab,
                isReturn: keyPress.key == .return,
                isEscape: keyPress.key == .escape,
                isUp: keyPress.key == .upArrow,
                isDown: keyPress.key == .downArrow,
                isLeft: keyPress.key == .leftArrow,
                isRight: keyPress.key == .rightArrow,
                isDelete: keyPress.key == .delete || keyPress.key == .deleteForward
            ),
            modifiers: MindMapKeyRouter.Modifiers(
                command: mods.contains(.command),
                option: mods.contains(.option),
                shift: mods.contains(.shift),
                control: mods.contains(.control)
            ),
            inTextField: store.isEditing,
            fileActions: .init(
                save: { saveDocument(saveAs: $0) },
                open: { openDocument() },
                new: {
                    store.newDocument()
                    syncFocusWithEditingState()
                },
                showHelp: { showKeyboardHelp = true }
            )
        )
        return handled ? .handled : .ignored
    }

    /// Move keyboard focus to the active title field, or back to the canvas.
    /// Clears first so re-assigning the same UUID re-applies focus (FocusState no-ops on equal values).
    private func syncFocusWithEditingState(editingID: UUID? = nil) {
        let id = editingID ?? store.editingID
        if let id {
            // Drop canvas focus so the AppKit title field can become first responder.
            canvasFocused = false
            // Clear-then-set so SwiftUI re-applies even when UUID is unchanged.
            focusedNodeID = nil
            DispatchQueue.main.async {
                self.canvasFocused = false
                self.focusedNodeID = id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if self.store.editingID == id {
                    self.focusedNodeID = id
                }
            }
        } else {
            focusedNodeID = nil
            DispatchQueue.main.async {
                self.canvasFocused = true
            }
        }
    }

    // MARK: - File panels

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "mindmap")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a mind map file"
        if panel.runModal() == .OK, let url = panel.url {
            store.load(from: url)
            syncFocusWithEditingState()
        }
    }

    private func saveDocument(saveAs: Bool) {
        if !saveAs, store.fileURL != nil {
            store.save()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mindmap") ?? .json]
        panel.nameFieldStringValue = store.fileURL?.lastPathComponent ?? store.suggestedFileName
        panel.canCreateDirectories = true
        panel.message = "Save mind map"
        if panel.runModal() == .OK, let url = panel.url {
            store.save(to: url)
        }
    }
}

enum MindNodeShortcuts {
    static let helpText = """
    Move between nodes: ↑↓ siblings · ← parent · → child
    Edit: ⌘↩ or start typing · finish with ⌘↩ · Esc cancels
    Create: Tab child · Return sibling · ? for full list
    """
}

public extension Notification.Name {
    static let mindMapUndo = Notification.Name("MindMapFeature.undo")
    static let mindMapRedo = Notification.Name("MindMapFeature.redo")
    static let mindMapShowKeyboardHelp = Notification.Name("MindMapFeature.showKeyboardHelp")
}

// MARK: - Keyboard help sheet

private struct KeyboardHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How to move with the keyboard")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpSection("1. Look for the orange border") {
                        Text("Keys always act on the selected node (orange outline). Click a node or use arrows to move the selection.")
                    }

                    helpSection("2. Move between nodes (arrow keys)") {
                        shortcutRow("↑", "Previous sibling (node above in the same branch)")
                        shortcutRow("↓", "Next sibling (node below in the same branch)")
                        shortcutRow("←", "Parent (one level left, toward the main idea)")
                        shortcutRow("→", "First child (one level right; unfolds if needed)")
                        shortcutRow("⌘R", "Jump to the main / center node")
                        Text("Arrows also work while typing a title — they save the text and move selection.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    helpSection("3. Edit a node’s title") {
                        shortcutRow("⌘↩", "Start editing the selected node")
                        shortcutRow("type", "Or just start typing to replace the title")
                        shortcutRow("⌘↩", "Finish editing (keep the text)")
                        shortcutRow("Esc", "Cancel editing (restore previous title)")
                    }

                    helpSection("4. Create nodes") {
                        shortcutRow("Tab", "New child under selection (then type)")
                        shortcutRow("↩", "New sibling after selection (then type)")
                        shortcutRow("⌥↩", "New sibling above")
                        shortcutRow("⇧↩", "New main topic (child of center)")
                    }

                    helpSection("5. Other useful keys") {
                        shortcutRow("⌥.", "Fold / unfold branch")
                        shortcutRow("⌫", "Delete node and its children")
                        shortcutRow("⌘Z / ⌘⇧Z", "Undo / redo")
                        shortcutRow("? or ⌘/", "Show this guide")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mental model")
                                .font(.headline)
                            Text("The map is a tree. Think outline:")
                            Text("← → change depth (parent / child)")
                            Text("↑ ↓ change order among brothers/sisters")
                            Text("The selected node has an orange border — that’s the one keys act on.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
    }

    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(.primary)
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared keyboard router (monitor + SwiftUI onKeyPress)

/// Single source of truth for canvas shortcuts so keyboard-only use never depends on focus quirks.
@MainActor
enum MindMapKeyRouter {
    struct Key {
        var keyCode: UInt16?
        var characters: String
        var isTab: Bool
        var isReturn: Bool
        var isEscape: Bool
        var isUp: Bool
        var isDown: Bool
        var isLeft: Bool
        var isRight: Bool
        var isDelete: Bool

        static func from(event: NSEvent) -> Key {
            let code = event.keyCode
            let chars = event.charactersIgnoringModifiers ?? ""
            return Key(
                keyCode: code,
                characters: chars,
                isTab: code == 48,
                isReturn: code == 36 || code == 76,
                isEscape: code == 53,
                isUp: code == 126,
                isDown: code == 125,
                isLeft: code == 123,
                isRight: code == 124,
                isDelete: code == 51 || code == 117
            )
        }
    }

    struct Modifiers {
        var command: Bool
        var option: Bool
        var shift: Bool
        var control: Bool
    }

    struct FileActions {
        var save: (Bool) -> Void
        var open: () -> Void
        var new: () -> Void
        var showHelp: () -> Void
    }

    /// Returns `true` when the event was fully handled (caller should swallow it).
    static func handle(
        store: MindMapStore,
        key: Key,
        modifiers: Modifiers,
        inTextField: Bool,
        fileActions: FileActions?
    ) -> Bool {
        let cmd = modifiers.command
        let opt = modifiers.option
        let shift = modifiers.shift
        let ctrl = modifiers.control
        let chars = key.characters
        let editing = store.isEditing || inTextField

        // Keyboard guide — available anytime.
        if (!cmd && !opt && !ctrl && chars == "?")
            || (cmd && !opt && !shift && !ctrl && chars == "/")
        {
            fileActions?.showHelp()
            return fileActions != nil
        }

        // ——— Tab always belongs to the mind map (never toolbar focus ring) ———
        if key.isTab && !cmd && !ctrl {
            if opt {
                store.insertParentForSelection()
            } else {
                store.addChild()
            }
            return true
        }

        // ——— While editing a title ———
        if editing {
            // Continuous capture: Return commits current title and opens a sibling ready to type.
            if key.isReturn && !cmd && !opt && !ctrl {
                if shift {
                    store.addMainNode()
                } else {
                    store.addSibling(after: true)
                }
                return true
            }
            // ⌥Return while typing → sibling above.
            if key.isReturn && opt && !cmd && !ctrl {
                store.addSibling(after: false)
                return true
            }
            // ⌘Return while typing → finish edit without creating a node.
            if key.isReturn && cmd && !opt {
                store.commitEditing()
                return true
            }
            if key.isEscape {
                store.cancelEditing()
                return true
            }
            // Arrow keys leave the field and move the orange selection.
            if key.isUp && !cmd && !opt && !ctrl {
                store.navigateUp()
                return true
            }
            if key.isDown && !cmd && !opt && !ctrl {
                store.navigateDown()
                return true
            }
            if key.isLeft && !cmd && !opt && !ctrl {
                store.navigateLeft()
                return true
            }
            if key.isRight && !cmd && !opt && !ctrl {
                store.navigateRight()
                return true
            }
            // ⌘↑↓ reorder, ⌘←→ indent/outdent — work even mid-edit.
            if cmd && !opt && !ctrl {
                if key.isUp { store.moveSelectedUp(); return true }
                if key.isDown { store.moveSelectedDown(); return true }
                if key.isRight { store.indentSelected(); return true }
                if key.isLeft { store.outdentSelected(); return true }
            }
            if opt && !cmd && !ctrl && (chars == "." || keyCodeIsPeriod(key)) {
                store.toggleFoldSelected()
                return true
            }
            // Printable characters stay in the field (or salvage if focus failed).
            if !inTextField,
               !cmd, !opt, !ctrl,
               !chars.isEmpty,
               chars != "?",
               chars.allSatisfy({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " " })
            {
                let next = store.editingDraft + chars
                store.updateEditingDraft(next)
                if let id = store.editingID {
                    store.applyTitleLive(id: id, raw: next)
                }
                return true
            }
            return false
        }

        // ——— Not editing: full canvas map ———
        if cmd {
            if key.isUp { store.moveSelectedUp(); return true }
            if key.isDown { store.moveSelectedDown(); return true }
            if key.isRight { store.indentSelected(); return true }
            if key.isLeft { store.outdentSelected(); return true }
            if key.isReturn { store.beginEditing(); return true }
            switch chars.lowercased() {
            case "r" where !opt && !ctrl:
                store.goToMainNode()
                return true
            case "s":
                fileActions?.save(shift)
                return fileActions != nil
            case "o":
                fileActions?.open()
                return fileActions != nil
            case "n":
                fileActions?.new()
                return fileActions != nil
            case "z":
                if shift { store.redo() } else { store.undo() }
                return true
            default:
                return false
            }
        }

        if opt && !cmd && !ctrl {
            if chars == "." || keyCodeIsPeriod(key) {
                store.toggleFoldSelected()
                return true
            }
            if key.isReturn {
                store.addSibling(after: false)
                return true
            }
            if key.isDelete {
                store.deleteSingleNode()
                return true
            }
        }

        if key.isReturn {
            if shift {
                store.addMainNode()
            } else {
                store.addSibling(after: true)
            }
            return true
        }
        if key.isUp { store.navigateUp(); return true }
        if key.isDown { store.navigateDown(); return true }
        if key.isLeft { store.navigateLeft(); return true }
        if key.isRight { store.navigateRight(); return true }
        if key.isDelete { store.deleteSelected(); return true }
        if key.isEscape {
            store.deselect()
            return true
        }

        // Type-to-edit: first printable character starts renaming the selection.
        if !chars.isEmpty,
           !cmd, !opt, !ctrl,
           chars != "?",
           chars.allSatisfy({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " " })
        {
            store.ensureSelection()
            store.beginEditing(seed: chars)
            return true
        }

        return false
    }

    private static func keyCodeIsPeriod(_ key: Key) -> Bool {
        key.keyCode == 47
    }
}

// MARK: - Always-on key monitor

private struct KeyboardMonitor: NSViewRepresentable {
    let store: MindMapStore
    var onSave: (Bool) -> Void
    var onOpen: () -> Void
    var onNew: () -> Void
    var onShowHelp: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.store = store
        view.onSave = onSave
        view.onOpen = onOpen
        view.onNew = onNew
        view.onShowHelp = onShowHelp
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.store = store
        nsView.onSave = onSave
        nsView.onOpen = onOpen
        nsView.onNew = onNew
        nsView.onShowHelp = onShowHelp
    }
}

final class KeyCatcherView: NSView {
    var store: MindMapStore?
    var onSave: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onNew: (() -> Void)?
    var onShowHelp: (() -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    // Local monitor only — must not steal first responder from the title field.
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var handled = false
            if Thread.isMainThread {
                handled = self.handleOnMain(event)
            } else {
                DispatchQueue.main.sync { handled = self.handleOnMain(event) }
            }
            return handled ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    @MainActor
    private func handleOnMain(_ event: NSEvent) -> Bool {
        guard let store else { return false }

        // Don't steal keys from system panels / other app windows.
        guard event.window == window || event.window == nil else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let first = window?.firstResponder
        let inTextField = first is NSTextView || first is NSTextField

        // Allow standard text-editing chord inside the title field (copy/paste/select-all).
        if inTextField {
            let cmd = flags.contains(.command)
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            // Let the field editor own typing undos (⌘Z) and clipboard chords.
            if cmd && ["a", "c", "v", "x", "z"].contains(chars) {
                return false
            }
        }

        return MindMapKeyRouter.handle(
            store: store,
            key: .from(event: event),
            modifiers: .init(
                command: flags.contains(.command),
                option: flags.contains(.option),
                shift: flags.contains(.shift),
                control: flags.contains(.control)
            ),
            inTextField: inTextField,
            fileActions: .init(
                save: { [weak self] saveAs in self?.onSave?(saveAs) },
                open: { [weak self] in self?.onOpen?() },
                new: { [weak self] in self?.onNew?() },
                showHelp: { [weak self] in self?.onShowHelp?() }
            )
        )
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
