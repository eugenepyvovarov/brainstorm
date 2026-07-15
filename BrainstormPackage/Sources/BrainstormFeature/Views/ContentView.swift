import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    let documentID: UUID
    @State private var store: BrainstormStore
    /// Shared focus: `nil` = canvas shortcuts; UUID = that node’s title field.
    @FocusState private var focusedNodeID: UUID?
    @FocusState private var canvasFocused: Bool
    @State private var showKeyboardHelp = false
    @State private var showInspector = true
    @State private var searchFieldFocused = false
    @FocusState private var searchFocused: Bool
    @State private var autosaveTask: Task<Void, Never>?
    /// Last bytes observed on disk for the current saved document.
    @State private var monitoredFileData: Data?
    @State private var showExternalFileConflict = false
    /// Prevent the final view disappearance from recreating a session entry
    /// after this document has intentionally been closed.
    @State private var isClosing = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    public init(documentID: UUID) {
        self.documentID = documentID
        // Cached restore: SwiftUI re-runs this init on every parent body pass;
        // must not allocate a new store (or write session) each time.
        _store = State(initialValue: BrainstormStore.sharedRestored(documentID: documentID))
    }

    /// Preview / tests helper.
    public init(store: BrainstormStore) {
        self.documentID = store.documentID
        _store = State(initialValue: store)
    }

    public var body: some View {
        rootChrome
            .modifier(contentChrome)
            .toolbar { toolbarContent }
            .help(BrainstormNodeShortcuts.helpText)
            .onChange(of: searchFocused) { _, focused in
                // Clicking/⌘F into search must not keep a node title field live.
                if focused, store.isEditing {
                    store.commitEditing()
                }
            }
            .task(id: store.fileURL) {
                await monitorExternalFileChanges()
            }
            .alert("File Changed on Disk", isPresented: $showExternalFileConflict) {
                Button("Reload from Disk", role: .destructive) {
                    reloadCurrentFileFromDisk()
                }
                Button("Keep My Changes", role: .cancel) {}
            } message: {
                Text("Another tool changed this mind map. Reloading will discard your unsaved changes in Brainstorm.")
            }
    }

    private var contentChrome: ContentViewChrome {
        ContentViewChrome(
            store: store,
            documentID: documentID,
            showKeyboardHelp: $showKeyboardHelp,
            searchFocused: $searchFocused,
            onAppear: {
                store.clearSearch() // search UI disabled for now
                store.ensureSelection()
                syncFocusWithEditingState()
                scheduleAutosave(immediate: true)
            },
            onDisappear: {
                autosaveTask?.cancel()
                if !isClosing {
                    store.performAutosave()
                }
            },
            onEditingChange: { syncFocusWithEditingState(editingID: $0) },
            onSelectionChange: {
                // Never steal focus from the search field when matches update selection.
                if !store.isEditing && !searchFocused {
                    DispatchQueue.main.async { self.canvasFocused = true }
                }
            },
            onAutosave: { immediate in scheduleAutosave(immediate: immediate) },
            onUndo: {
                store.undo()
                syncFocusWithEditingState()
            },
            onRedo: {
                store.redo()
                syncFocusWithEditingState()
            },
            onSave: { saveDocument(saveAs: $0) },
            onOpen: { openDocument() },
            onOpenRecent: { openRecentDocument(id: $0) },
            onNew: { openNewWindow() },
            onNewTab: { openNewTab(in: $0) },
            onExport: { exportDocument(as: $0) },
            onClose: { closeCurrentDocument(window: $0) },
            onShowHelp: { showKeyboardHelp = true },
            onExternalDocuments: { openExternalDocuments() }
        )
    }

    private var rootChrome: some View {
        VStack(spacing: 0) {
            mainWorkspace
            KeyboardStatusBar(
                isEditing: store.isEditing,
                onShowHelp: { showKeyboardHelp = true }
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
            ThemePickerMenu(themeID: store.themeID) { id in
                store.applyTheme(id)
            }
            .help("Editor theme (Zed / VS Code palettes)")
            .focusable(false)

            // Search UI temporarily disabled (type-to-edit conflicts); re-enable later.

            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                store.zoomOut()
            }
            .help("Zoom out (⌘-)")
            .focusable(false)

            Text("\(Int(store.zoomScale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 36)
                .foregroundStyle(.secondary)

            Button {
                store.zoomReset()
            } label: {
                Text("1:1")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            // A regular text button gets its own macOS toolbar capsule and
            // visually splits this ToolbarItemGroup. Keep it inside the shared
            // zoom group while retaining a useful click target.
            .buttonStyle(.plain)
            .help("Actual size — reset zoom to 100% (⌘0)")
            .accessibilityLabel("Actual Size")
            .accessibilityIdentifier("zoomActualSize")
            .disabled(abs(store.zoomScale - 1) < 0.001)
            .focusable(false)

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                store.zoomIn()
            }
            .help("Zoom in (⌘+)")
            .focusable(false)

            Button("Focus", systemImage: store.isFocusMode ? "circle.lefthalf.filled" : "circle") {
                store.toggleFocusMode()
            }
            .help("Focus mode (⇧⌘F)")
            .focusable(false)

            Button("Inspector", systemImage: "sidebar.trailing") {
                showInspector.toggle()
            }
            .help("Toggle style inspector")
            .focusable(false)

            Button("Keyboard", systemImage: "keyboard") {
                showKeyboardHelp = true
            }
            .help("Keyboard shortcuts (⌘/)")
            .focusable(false)

            Button("New Tab", systemImage: "plus.rectangle.on.rectangle") {
                openNewTab()
            }
            .help("New mind map tab (⌘T)")
            .focusable(false)

            Button("New Window", systemImage: "macwindow.badge.plus") {
                openNewWindow()
            }
            .help("New mind map window (⌘N)")
            .focusable(false)

            Button("Open", systemImage: "folder") {
                openDocument()
            }
            .help("Open… (⌘O)")
            .focusable(false)

            Button("Save", systemImage: "square.and.arrow.down") {
                saveDocument(saveAs: false)
            }
            .help("Save (⌘S) — also autosaved continuously")
            .focusable(false)

            Button("Save As", systemImage: "square.and.arrow.down.on.square") {
                saveDocument(saveAs: true)
            }
            .help("Save As…")
            .focusable(false)

            Menu {
                ForEach(BrainstormExportFormat.menuCases, id: \.self) { format in
                    Button(format.menuTitle) {
                        exportDocument(as: format)
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the complete map as an image, document, or text mind map")
            .focusable(false)
        }
    }

    // MARK: - Autosave

    private func scheduleAutosave(immediate: Bool = false) {
        autosaveTask?.cancel()
        if immediate {
            store.performAutosave()
            return
        }
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            store.performAutosave()
        }
    }

    /// ⌘N — separate window (not a tab).
    private func openNewWindow() {
        store.performAutosave()
        let id = DocumentSession.shared.registerNewDocument().id
        DocumentWindowTabbing.openAsWindow(documentID: id) {
            openWindow(id: BrainstormWindowID.map, value: id)
        }
    }

    /// ⌘T / tab-bar + / File → New Tab — new map in the current window’s tab group.
    private func openNewTab(in parentWindow: NSWindow? = nil) {
        store.performAutosave()
        // The native tab-bar + gives us the exact originating window. Refresh
        // its registration before creating the child so SwiftUI view churn can
        // never leave this request attached to a stale document/window pair.
        if let parentWindow {
            DocumentWindowTabbing.configure(parentWindow, documentID: documentID)
        }
        let id = DocumentSession.shared.registerNewDocument().id
        openDocumentWindow(id: id, asTabIn: documentID)
    }

    /// Open a registered document window, optionally merging it as a native tab.
    private func openDocumentWindow(id: UUID, asTabIn parentDocumentID: UUID?) {
        guard let parentDocumentID else {
            DocumentWindowTabbing.openAsWindow(documentID: id) {
                openWindow(id: BrainstormWindowID.map, value: id)
            }
            return
        }
        DocumentWindowTabbing.openAsTab(
            documentID: id,
            parentDocumentID: parentDocumentID
        ) {
            openWindow(id: BrainstormWindowID.map, value: id)
        }
    }

    // MARK: - Theme chrome

    /// Fixed map palettes pin light/dark on the *canvas only*.
    /// Window chrome (toolbar, inspector, status bar) always follows macOS appearance.
    private var canvasPreferredScheme: ColorScheme? {
        let theme = store.theme
        guard !theme.isSystem else { return nil }
        return theme.isDark ? .dark : .light
    }

    // MARK: - Workspace

    private var mainWorkspace: some View {
        HStack(spacing: 0) {
            BrainstormCanvasView(store: store, focusedNodeID: $focusedNodeID)
                .focusable(true)
                .focused($canvasFocused)
                .focusEffectDisabled()
                .focusSection()
                .preferredColorScheme(canvasPreferredScheme)
                .onKeyPress(phases: .down) { keyPress in
                    handleKeyPress(keyPress)
                }

            if showInspector {
                NodeInspectorView(store: store)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showInspector)
        .animation(.easeInOut(duration: 0.25), value: store.themeID)
        // Nodes resolve fill/text/branch from this environment value.
        .environment(\.brainstormTheme, store.theme)
    }

    // MARK: - Keyboard (secondary path; NSEvent monitor is primary)

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let mods = keyPress.modifiers
        let handled = BrainstormKeyRouter.handle(
            store: store,
            key: BrainstormKeyRouter.Key(
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
            modifiers: BrainstormKeyRouter.Modifiers(
                command: mods.contains(.command),
                option: mods.contains(.option),
                shift: mods.contains(.shift),
                control: mods.contains(.control)
            ),
            inTextField: store.isEditing,
            fileActions: .init(
                save: { saveDocument(saveAs: $0) },
                open: { openDocument() },
                new: { openNewWindow() },
                newTab: { openNewTab() },
                close: { closeCurrentDocument() },
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
        panel.allowedContentTypes = BrainstormCodec.openContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a Brainstorm map (.bs)"
        guard panel.runModal() == .OK else { return }
        openURLs(panel.urls)
    }

    /// Open a path from File → Open Recent (key window only).
    private func openRecentDocument(id: String) {
        guard let entry = RecentDocuments.shared.entry(id: id) else { return }
        guard let url = RecentDocuments.shared.resolveURL(for: entry) else {
            store.lastError = "Couldn’t open “\(entry.menuTitle)”. The file may have been moved or deleted."
            RecentDocuments.shared.remove(id: id)
            return
        }
        openURLs([url])
    }

    /// Finder / Launch Services double-click (and drag onto Dock icon).
    private func openExternalDocuments() {
        let urls = ExternalDocumentRouter.shared.takePending()
        guard !urls.isEmpty else { return }
        // Always use fresh document IDs for external files so recovery autosaves
        // for other session maps are never overwritten. Only a pristine blank
        // untitled may be replaced in-place.
        _ = DocumentSession.shared.consumeReplacePrimaryForExternalOpen()
        openURLs(urls)
    }

    /// Open one or more files without clobbering unsaved work.
    /// Pristine blank untitled → first file replaces this tab; otherwise all open as new tabs.
    private func openURLs(_ urls: [URL]) {
        var seenPaths: Set<String> = []
        let uniqueURLs = urls.filter { url in
            seenPaths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
        guard !uniqueURLs.isEmpty else { return }

        var mayReplaceCurrent = canReplaceCurrentWithOpen
        for url in uniqueURLs {
            if let openDocumentID = DocumentSession.shared.documentID(forFileURL: url) {
                DocumentWindowTabbing.activate(documentID: openDocumentID)
                continue
            }

            loadFile(from: url, intoCurrentWindow: mayReplaceCurrent, asTab: !mayReplaceCurrent)
            mayReplaceCurrent = false
        }
    }

    /// Only a never-edited blank untitled may be replaced in-place by Open.
    private var canReplaceCurrentWithOpen: Bool {
        store.fileURL == nil && !store.isDirty && isBlankUntitledMap
    }

    /// True when the map still looks like a fresh document (placeholder root, no children).
    private var isBlankUntitledMap: Bool {
        let title = store.root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = title.isEmpty || title == BrainstormNode.mainPlaceholder || title == "Untitled"
        return isPlaceholder && store.root.children.isEmpty
    }

    private func loadFile(from url: URL, intoCurrentWindow: Bool, asTab: Bool = false) {
        if intoCurrentWindow {
            store.load(from: url)
            refreshMonitoredFileData(from: url)
            scheduleAutosave(immediate: true)
            syncFocusWithEditingState()
            return
        }
        // Fresh document id — never reuse the current slot’s autosave for another file.
        let id = DocumentSession.shared.registerNewDocument(
            displayName: url.deletingPathExtension().lastPathComponent
        ).id
        let temp = BrainstormStore(documentID: id, startEditing: false)
        temp.load(from: url)
        temp.performAutosave()
        let parent = asTab ? documentID : nil
        openDocumentWindow(id: id, asTabIn: parent)
    }

    /// Returns `true` when the document was saved (or Save As completed).
    @discardableResult
    private func saveDocument(saveAs: Bool) -> Bool {
        if store.isEditing { store.commitEditing() }
        if !saveAs, store.fileURL != nil {
            let ok = store.save()
            if ok {
                if let url = store.fileURL { refreshMonitoredFileData(from: url) }
                scheduleAutosave(immediate: true)
            }
            return ok
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [BrainstormCodec.contentType]
        panel.nameFieldStringValue = store.fileURL?.lastPathComponent ?? store.suggestedFileName
        panel.canCreateDirectories = true
        panel.message = "Save Brainstorm map"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let ok = store.save(to: url)
        if ok {
            refreshMonitoredFileData(from: url)
            scheduleAutosave(immediate: true)
        }
        return ok
    }

    // MARK: - External file changes

    /// CLI edits use atomic replacement, so compare bytes instead of relying on
    /// a file descriptor or modification date that can become stale after rename.
    private func monitorExternalFileChanges() async {
        guard let initialURL = store.fileURL else {
            monitoredFileData = nil
            return
        }
        refreshMonitoredFileData(from: initialURL)

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard let currentURL = store.fileURL,
                  currentURL.standardizedFileURL == initialURL.standardizedFileURL
            else { return }

            let currentData = try? Data(contentsOf: currentURL)
            switch ExternalFileChangePolicy.action(
                previousData: monitoredFileData,
                currentData: currentData,
                hasUnsavedChanges: store.isDirty
            ) {
            case .unchanged:
                continue
            case .reload:
                monitoredFileData = currentData
                store.load(from: currentURL)
                syncFocusWithEditingState()
            case .askBeforeReloading:
                // Accept this disk revision as the observed baseline. Choosing
                // Keep My Changes means the next explicit app save may overwrite it.
                monitoredFileData = currentData
                showExternalFileConflict = true
            }
        }
    }

    private func refreshMonitoredFileData(from url: URL) {
        monitoredFileData = try? Data(contentsOf: url)
    }

    private func reloadCurrentFileFromDisk() {
        guard let url = store.fileURL else { return }
        store.load(from: url)
        refreshMonitoredFileData(from: url)
        syncFocusWithEditingState()
    }

    private func exportDocument(as format: BrainstormExportFormat) {
        if store.isEditing { store.commitEditing() }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(store.mapName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.message = "Export the complete mind map as \(format.displayName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try BrainstormExporter.write(
                root: store.root,
                theme: store.theme,
                colorScheme: colorScheme,
                format: format,
                to: url
            )
        } catch {
            store.lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// ⌘W / File → Close asks AppKit to close the exact hosting window. The
    /// delegate then runs the same save flow as the red button / tab close.
    @discardableResult
    private func closeCurrentDocument(window: NSWindow? = nil) -> Bool {
        guard let window else {
            let target = DocumentWindowTabbing.window(for: documentID)
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
            target?.performClose(nil)
            return false
        }

        if store.isEditing { store.commitEditing() }

        if store.isDirty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to “\(store.mapName)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Existing file → Save; untitled → Save As panel.
                guard saveDocument(saveAs: store.fileURL == nil) else { return false }
            case .alertSecondButtonReturn:
                break // Don’t Save
            default:
                return false // Cancel
            }
        }

        isClosing = true
        finalizeDocumentClose(window)
        return true
    }

    private func finalizeDocumentClose(_ window: NSWindow) {
        autosaveTask?.cancel()
        store.performAutosave()
        DocumentSession.shared.closeDocument(documentID)
        BrainstormStore.releaseShared(documentID: documentID)
        DocumentWindowTabbing.unregister(documentID: documentID, window: window)
    }
}

// MARK: - Window identity

public enum BrainstormWindowID {
    /// Typed window group for one mind map document each.
    public static let map = "brainstorm.document"
}

/// Lifecycle chrome extracted from `ContentView.body` so the type checker stays fast.
private struct ContentViewChrome: ViewModifier {
    let store: BrainstormStore
    let documentID: UUID
    @Binding var showKeyboardHelp: Bool
    var searchFocused: FocusState<Bool>.Binding
    let onAppear: () -> Void
    let onDisappear: () -> Void
    let onEditingChange: (UUID?) -> Void
    let onSelectionChange: () -> Void
    let onAutosave: (_ immediate: Bool) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSave: (Bool) -> Void
    let onOpen: () -> Void
    let onOpenRecent: (String) -> Void
    let onNew: () -> Void
    let onNewTab: (NSWindow?) -> Void
    let onExport: (BrainstormExportFormat) -> Void
    /// Close handler; receives the host window when available (red button / tab close).
    let onClose: (NSWindow?) -> Bool
    let onShowHelp: () -> Void
    let onExternalDocuments: () -> Void

    func body(content: Content) -> some View {
        content
            .background(sessionAndKeyboardBackground)
            .background(
                WindowChromeBridge(
                    documentID: documentID,
                    isDocumentEdited: store.isDirty,
                    // Pass the exact sender so inactive tab/window close
                    // never falls back to a different key window.
                    shouldClose: { window in onClose(window) },
                    onNewTab: onNewTab
                )
            )
            .modifier(ContentViewLifecycle(
                store: store,
                onAppear: {
                    onAppear()
                    // Cold launch: Finder may deliver URLs before the window is key.
                    onExternalDocuments()
                },
                onDisappear: onDisappear,
                onEditingChange: onEditingChange,
                onSelectionChange: onSelectionChange,
                onAutosave: onAutosave
            ))
            .modifier(ContentViewNotifications(
                store: store,
                showKeyboardHelp: $showKeyboardHelp,
                searchFocused: searchFocused,
                onUndo: onUndo,
                onRedo: onRedo,
                onSave: onSave,
                onOpen: onOpen,
                onOpenRecent: onOpenRecent,
                onNew: onNew,
                onNewTab: { onNewTab(nil) },
                onExport: onExport,
                onClose: { _ = onClose(nil) },
                onExternalDocuments: onExternalDocuments
            ))
            .navigationTitle(store.documentTitle)
            // App chrome always follows the macOS light/dark appearance.
            // Map palettes pin light/dark only on the canvas (see mainWorkspace).
            .sheet(isPresented: $showKeyboardHelp) {
                KeyboardHelpSheet()
            }
            .modifier(ContentViewErrorAlert(store: store))
    }

    @ViewBuilder
    private var sessionAndKeyboardBackground: some View {
        SessionWindowRestorer(primaryDocumentID: documentID)
        KeyboardMonitor(
            store: store,
            isSearchFocused: { searchFocused.wrappedValue },
            onDismissSearch: {
                store.clearSearch()
                searchFocused.wrappedValue = false
            },
            onSave: onSave,
            onOpen: onOpen,
            onNew: onNew,
            onNewTab: { onNewTab(nil) },
            onClose: { _ = onClose(nil) },
            onShowHelp: onShowHelp
        )
    }
}

/// Appear / disappear / change hooks (separate modifier = lighter type-check).
private struct ContentViewLifecycle: ViewModifier {
    let store: BrainstormStore
    let onAppear: () -> Void
    let onDisappear: () -> Void
    let onEditingChange: (UUID?) -> Void
    let onSelectionChange: () -> Void
    let onAutosave: (_ immediate: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onChange(of: store.editingID) { _, newValue in
                onEditingChange(newValue)
                onAutosave(false)
            }
            .onChange(of: store.selectedID) { _, _ in
                onSelectionChange()
            }
            .onChange(of: store.structureEpoch) { _, _ in
                onAutosave(false)
            }
            .onChange(of: store.themeID) { _, _ in
                onAutosave(false)
            }
            .onChange(of: store.editingDraft) { _, _ in
                onAutosave(false)
            }
            // historyEpoch advances only after a completed undoable action
            // (including undo/redo), so persist immediately without writing
            // once per live drag frame or title keystroke.
            .onChange(of: store.historyEpoch) { _, _ in
                onAutosave(true)
            }
    }
}

private struct ContentViewNotifications: ViewModifier {
    let store: BrainstormStore
    @Binding var showKeyboardHelp: Bool
    var searchFocused: FocusState<Bool>.Binding
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSave: (Bool) -> Void
    let onOpen: () -> Void
    let onOpenRecent: (String) -> Void
    let onNew: () -> Void
    let onNewTab: () -> Void
    let onExport: (BrainstormExportFormat) -> Void
    let onClose: () -> Void
    let onExternalDocuments: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .brainstormUndo)) { _ in
                guard isKeyWindow else { return }
                onUndo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormRedo)) { _ in
                guard isKeyWindow else { return }
                onRedo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormShowKeyboardHelp)) { _ in
                guard isKeyWindow else { return }
                showKeyboardHelp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormFocusSearch)) { _ in
                guard isKeyWindow else { return }
                // Leave node-title edit so typing goes only to search.
                if store.isEditing {
                    store.commitEditing()
                }
                searchFocused.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormNew)) { _ in
                guard isKeyWindow else { return }
                onNew()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormNewTab)) { _ in
                // File → New Tab / ⌘T (tab-bar + uses WindowChromeBridge directly).
                guard isKeyWindow else { return }
                onNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormOpen)) { _ in
                guard isKeyWindow else { return }
                onOpen()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormOpenRecent)) { note in
                guard isKeyWindow else { return }
                if let id = note.object as? String {
                    onOpenRecent(id)
                } else if let id = note.userInfo?["id"] as? String {
                    onOpenRecent(id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormSave)) { _ in
                guard isKeyWindow else { return }
                onSave(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormSaveAs)) { _ in
                guard isKeyWindow else { return }
                onSave(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormExportPNG)) { _ in
                guard isKeyWindow else { return }
                onExport(.png)
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormExportPDF)) { _ in
                guard isKeyWindow else { return }
                onExport(.pdf)
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormClose)) { _ in
                guard isKeyWindow else { return }
                onClose()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brainstormExternalDocumentsAvailable)) { _ in
                // Prefer key window; if none is key yet, any window may drain pending.
                if isKeyWindow || ExternalDocumentRouter.shared.hasPending {
                    onExternalDocuments()
                }
            }
    }

    /// Only the frontmost map window should handle File / Edit menu posts.
    private var isKeyWindow: Bool {
        if let window = DocumentWindowTabbing.window(for: store.documentID) {
            return DocumentWindowTabbing.isCommandTarget(window)
        }
        // The hosting-window bridge can be one SwiftUI update behind during
        // initial scene creation, so retain the environment value as fallback.
        return controlActiveState == .key
    }
}

/// Reports the hosting window synchronously when SwiftUI installs this view.
/// This is earlier and more deterministic than dispatching from `updateNSView`.
@MainActor
final class WindowChromeHostView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// Hosting-window bridge: native tabbing, tab-bar +, and close-with-save.
struct WindowChromeBridge: NSViewRepresentable {
    let documentID: UUID
    var isDocumentEdited: Bool
    /// Receives the exact window that should close (red button / tab).
    var shouldClose: (NSWindow) -> Bool
    var onNewTab: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentID: documentID,
            isDocumentEdited: isDocumentEdited,
            shouldClose: shouldClose,
            onNewTab: onNewTab
        )
    }

    func makeNSView(context: Context) -> WindowChromeHostView {
        let view = WindowChromeHostView(frame: .zero)
        view.isHidden = true
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeHostView, context: Context) {
        if context.coordinator.documentID != documentID {
            context.coordinator.detach()
        }
        context.coordinator.documentID = documentID
        context.coordinator.isDocumentEdited = isDocumentEdited
        context.coordinator.shouldClose = shouldClose
        context.coordinator.onNewTab = onNewTab
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(
        _ nsView: WindowChromeHostView,
        coordinator: Coordinator
    ) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSResponder, NSWindowDelegate {
        var documentID: UUID
        var isDocumentEdited: Bool
        var shouldClose: (NSWindow) -> Bool
        var onNewTab: (NSWindow?) -> Void
        weak var window: NSWindow?
        nonisolated(unsafe) weak var forwardedDelegate: (any NSWindowDelegate)?
        nonisolated(unsafe) weak var forwardedResponder: NSResponder?
        var isClosing = false

        init(
            documentID: UUID,
            isDocumentEdited: Bool,
            shouldClose: @escaping (NSWindow) -> Bool,
            onNewTab: @escaping (NSWindow?) -> Void
        ) {
            self.documentID = documentID
            self.isDocumentEdited = isDocumentEdited
            self.shouldClose = shouldClose
            self.onNewTab = onNewTab
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func attach(to window: NSWindow?) {
            guard let window else {
                detach()
                return
            }
            window.isDocumentEdited = isDocumentEdited
            DocumentWindowTabbing.configure(window, documentID: documentID)
            if self.window === window, (window.delegate as AnyObject?) === self {
                installInResponderChain(of: window)
                return
            }

            detach()
            self.window = window
            if (window.delegate as AnyObject?) !== self {
                if let previous = window.delegate as? Coordinator {
                    // SwiftUI can replace the representable before dismantling
                    // its old coordinator. Forward directly to the original
                    // delegate instead of building a fragile proxy chain.
                    forwardedDelegate = previous.forwardedDelegate
                } else {
                    forwardedDelegate = window.delegate
                }
            }
            window.delegate = self
            installInResponderChain(of: window)
            if window.isKeyWindow {
                DocumentSession.shared.setActive(documentID)
            }
        }

        private func installInResponderChain(of window: NSWindow) {
            guard window.nextResponder !== self else { return }
            // SwiftUI's window controller also implements newWindowForTab: and
            // would duplicate the current scene value. Insert this coordinator
            // immediately after the window so the native tab-bar + creates a
            // fresh document through Brainstorm's deterministic tab path.
            if let previous = window.nextResponder as? Coordinator {
                forwardedResponder = previous.forwardedResponder ?? previous.nextResponder
            } else {
                forwardedResponder = window.nextResponder
            }
            nextResponder = forwardedResponder
            window.nextResponder = self
        }

        func detach() {
            guard let window else { return }
            if (window.delegate as AnyObject?) === self {
                window.delegate = forwardedDelegate
            }
            if window.nextResponder === self {
                window.nextResponder = forwardedResponder
            }
            self.window = nil
            forwardedDelegate = nil
            forwardedResponder = nil
            nextResponder = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isClosing { return true }
            // Respect an existing AppKit delegate veto before changing the
            // document or session. Once it accepts, Brainstorm owns the
            // save/session decision and re-issues the native tab close below.
            if forwardedDelegate?.windowShouldClose?(sender) == false {
                return false
            }
            guard shouldClose(sender) else { return false }

            // A tab close can be consumed by AppKit's tab controller when it
            // is approved in this delegate callback. Re-issue the close on
            // the next turn: the guard above lets that second request through
            // without another save prompt, and AppKit removes the exact tab.
            isClosing = true
            DispatchQueue.main.async { [weak sender] in
                sender?.performClose(nil)
            }
            return false
        }

        func windowDidBecomeKey(_ notification: Notification) {
            DocumentSession.shared.setActive(documentID)
            forwardedDelegate?.windowDidBecomeKey?(notification)
        }

        /// Tab bar “+” button — open a new document tab in this window’s group.
        @objc(newWindowForTab:)
        override func newWindowForTab(_ sender: Any?) {
            onNewTab(window)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return forwardedDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let forwardedDelegate, forwardedDelegate.responds(to: aSelector) {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

/// Isolated alert so the Binding expression does not slow the main body checker.
private struct ContentViewErrorAlert: ViewModifier {
    let store: BrainstormStore

    private var isPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.alert("Error", isPresented: isPresented) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

/// Opens remaining session documents as native tabs on the primary window (once per launch).
/// Skipped when the app was started by opening a specific file (Finder double-click).
private struct SessionWindowRestorer: View {
    let primaryDocumentID: UUID
    @Environment(\.openWindow) private var openWindow
    @State private var didRun = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard !didRun else { return }
                didRun = true
                guard !DocumentSession.shared.didRestoreExtraWindows else { return }

                // Let `application(_:open:)` deliver Finder URLs before we reopen last session.
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard !DocumentSession.shared.didRestoreExtraWindows else { return }

                // Double-click / Dock drop: skip multi-window restore so only the
                // requested file(s) appear — but never prune recovery autosaves.
                if DocumentSession.shared.suppressSessionWindowRestore
                    || ExternalDocumentRouter.shared.hasPending
                {
                    DocumentSession.shared.beginDocumentOpenLaunch()
                    DocumentSession.shared.markExtraWindowsRestored()
                    if ExternalDocumentRouter.shared.hasPending {
                        NotificationCenter.default.post(
                            name: .brainstormExternalDocumentsAvailable,
                            object: nil
                        )
                    }
                    return
                }

                DocumentSession.shared.markExtraWindowsRestored()
                let extras = DocumentSession.shared.additionalDocumentIDsToRestore(
                    primary: primaryDocumentID
                )
                guard !extras.isEmpty else { return }

                // Wait a beat so the primary bridge can register its exact window.
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                for id in extras {
                    guard !Task.isCancelled else { return }
                    DocumentWindowTabbing.openAsTab(
                        documentID: id,
                        parentDocumentID: primaryDocumentID,
                        // Keep the previously-active primary tab selected while restoring.
                        select: false
                    ) {
                        openWindow(id: BrainstormWindowID.map, value: id)
                    }
                }
            }
    }
}

enum BrainstormNodeShortcuts {
    static let helpText = """
    Move between nodes: ↑↓ siblings · ← parent · → child
    Edit: Space to extend · type a letter to replace · ⌃←→ move by words · ⌃↑↓ disabled · ⌘↩ rename/done · Esc cancels
    Structure: ⌘↑↓ reorder · ⌘←→ change depth (outside title editing)
    Create: Tab child · Return sibling · ? for full list
    Documents: ⌘T new tab · ⌘N new window · ⌘W close
    """
}

public extension Notification.Name {
    static let brainstormUndo = Notification.Name("BrainstormFeature.undo")
    static let brainstormRedo = Notification.Name("BrainstormFeature.redo")
    static let brainstormShowKeyboardHelp = Notification.Name("BrainstormFeature.showKeyboardHelp")
    static let brainstormFocusSearch = Notification.Name("BrainstormFeature.focusSearch")
    static let brainstormNew = Notification.Name("BrainstormFeature.new")
    /// New document as a native tab (⌘T). `object` may be the host `NSWindow`.
    static let brainstormNewTab = Notification.Name("BrainstormFeature.newTab")
    static let brainstormOpen = Notification.Name("BrainstormFeature.open")
    static let brainstormOpenRecent = Notification.Name("BrainstormFeature.openRecent")
    static let brainstormSave = Notification.Name("BrainstormFeature.save")
    static let brainstormSaveAs = Notification.Name("BrainstormFeature.saveAs")
    static let brainstormExportPNG = Notification.Name("BrainstormFeature.exportPNG")
    static let brainstormExportPDF = Notification.Name("BrainstormFeature.exportPDF")
    static let brainstormClose = Notification.Name("BrainstormFeature.close")
    /// Finder / Launch Services delivered one or more document URLs.
    static let brainstormExternalDocumentsAvailable = Notification.Name("BrainstormFeature.externalDocumentsAvailable")
}


// MARK: - Chrome subviews

/// Menu of Zed / VS Code–style editor palettes.
struct ThemePickerMenu: View {
    let themeID: String
    var onSelect: (String) -> Void

    private var current: AppTheme { AppTheme.theme(id: themeID) }

    var body: some View {
        Menu {
            ForEach(AppTheme.all) { theme in
                Button {
                    onSelect(theme.id)
                } label: {
                    HStack {
                        ThemeSwatchStrip(theme: theme)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(theme.name)
                            Text(theme.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if theme.id == themeID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(current.isSystem ? "Theme" : current.name)
            } icon: {
                Image(systemName: "paintpalette.fill")
            }
        }
        .menuIndicator(.hidden)
    }
}

/// Mini canvas / node / accent preview for a theme row.
struct ThemeSwatchStrip: View {
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 2) {
            if theme.isSystem {
                // Live system colors so the strip tracks light/dark appearance.
                colorSwatch(Color(nsColor: .textBackgroundColor))
                colorSwatch(Color.accentColor)
                colorSwatch(Color.accentColor.opacity(0.7))
            } else {
                colorSwatch(Color(hex: theme.canvasBackground) ?? .gray)
                colorSwatch(Color(hex: theme.rootFill) ?? .gray)
                colorSwatch(Color(hex: theme.branch) ?? .gray)
            }
        }
    }

    private func colorSwatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 10, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

private struct SearchFieldChrome: View {
    @Binding var query: String
    var matchIndex: Int
    var matchCount: Int
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 140)
                .focused(isFocused)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Text("\(matchCount == 0 ? 0 : matchIndex + 1)/\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .brainstormGlassCapsule(interactive: false)
    }
}

private struct KeyboardStatusBar: View {
    let isEditing: Bool
    let onShowHelp: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if isEditing {
                Label("Editing", systemImage: "character.cursor.ibeam")
                    .foregroundStyle(.secondary)
                StatusHint(key: "←→", label: "caret")
                StatusHint(key: "⌘↩", label: "done")
                StatusHint(key: "Esc", label: "cancel")
                StatusHint(key: "↩", label: "sibling")
            } else {
                Label("Selected", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .foregroundStyle(.secondary)
                StatusHint(key: "Space", label: "edit")
                StatusHint(key: "type", label: "replace")
                StatusHint(key: "↑↓←→", label: "nav")
                StatusHint(key: "⇧⌘F", label: "focus")
            }
            Spacer(minLength: 8)
            Button("All shortcuts", action: onShowHelp)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open full keyboard guide (⌘/)")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background { statusBackground }
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    @ViewBuilder
    private var statusBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Rectangle().fill(.bar)
        }
    }
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
                        Text("While editing: ←→ move the caret in the title; ↑↓ leave edit and move selection. Modifier arrows do not change the tree while the title editor is active.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    helpSection("3. Edit a node’s title") {
                        shortcutRow("Space", "Edit existing title (caret at end — keep the text)")
                        shortcutRow("⌘↩", "Rename (select all — type to replace)")
                        shortcutRow("type a letter", "Replace the whole title with what you type")
                        shortcutRow("double-click", "Rename (select all)")
                        shortcutRow("⌘↩", "Finish editing (keep the text)")
                        shortcutRow("Esc", "Cancel editing (restore previous title)")
                    }

                    helpSection("4. Create nodes") {
                        shortcutRow("Tab", "New child under selection (then type)")
                        shortcutRow("↩", "New sibling after selection (then type)")
                        shortcutRow("⌥↩", "New sibling above")
                        shortcutRow("⇧↩", "New main topic (when not editing)")
                    }

                    helpSection("5. Style, zoom, focus") {
                        shortcutRow("Theme", "Map palette — System (macOS light/dark), Dark+, One Dark, …")
                        shortcutRow("Inspector", "Map theme, fill, shape, font, branch, emoji, image")
                        shortcutRow("⇧-click", "Add/remove nodes from selection; inspector styles all selected nodes")
                        shortcutRow("drag", "Reorder among siblings (gap line) or free-position")
                        shortcutRow("drop onto node", "Confirm to reparent the dragged node")
                        shortcutRow("⌘↑↓", "Reorder selected among siblings (outside title editing)")
                        shortcutRow("⌘←→", "Indent or outdent (outside title editing)")
                        shortcutRow("⌃←→", "Move by words while editing a title")
                        shortcutRow("⌃↑↓", "Disabled while editing (never changes the tree)")
                        shortcutRow("⌥↑↓←→", "Nudge free position by 10pt · ⌥R resets")
                        shortcutRow("1:1 / ⌘0", "Reset zoom to 100%")
                        shortcutRow("⌘+ / ⌘-", "Zoom in / out (or ⌘-scroll)")
                        shortcutRow("⇧⌘F", "Focus mode — keep branch + same-level peers (not their kids)")
                    }

                    helpSection("6. Documents & windows") {
                        shortcutRow("⌘T", "New map as a tab in this window")
                        shortcutRow("⌘N", "New map in a separate window")
                        shortcutRow("⌘W", "Close current tab / window (asks to save)")
                        shortcutRow("Export", "Save the complete map as PNG, PDF, Markdown, Mermaid, or PlantUML")
                        shortcutRow("drag tab", "Pull a tab out into its own window")
                        Text("Use Window → Show Tab Bar if the tab strip is hidden. Window → Merge All Windows recombines open maps.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    helpSection("7. Other useful keys") {
                        shortcutRow("⌥.", "Fold / unfold branch")
                        shortcutRow("⌫", "Delete node and its children")
                        shortcutRow("⌘Z / ⌘⇧Z", "Undo / redo")
                        shortcutRow("⌘/", "Show this guide")
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
enum BrainstormKeyRouter {
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
        var newTab: () -> Void
        var close: () -> Void
        var showHelp: () -> Void
    }

    /// Returns `true` when the event was fully handled (caller should swallow it).
    static func handle(
        store: BrainstormStore,
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

        // Keyboard guide: ⌘/ only — bare `?` must type a question mark in titles.
        if cmd && !opt && !shift && !ctrl && chars == "/" {
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
            // Modifier arrows are never structural shortcuts. Let horizontal
            // modifiers reach the native title field (word/caret navigation),
            // but consume vertical modifiers so they cannot move selection or
            // invoke a system action while editing.
            if (cmd || ctrl) && (key.isUp || key.isDown) {
                return true
            }
            if (cmd || ctrl) && (key.isLeft || key.isRight) {
                return false
            }
            // ⇧Return inserts a manual line break. When the AppKit title field owns
            // focus, let it insert at the caret; the store path covers lost focus.
            if key.isReturn && shift && !cmd && !opt && !ctrl {
                if inTextField { return false }
                store.insertNewlineInTitle()
                return true
            }
            // Plain Return commits the title and creates the next sibling.
            if key.isReturn && !shift && !cmd && !opt && !ctrl {
                store.addSibling(after: true)
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
            // ↑↓ leave the field and move the orange selection among siblings.
            // ←→ stay in the title field so the caret can move within the text.
            if key.isUp && !cmd && !opt && !ctrl {
                store.navigateUp()
                return true
            }
            if key.isDown && !cmd && !opt && !ctrl {
                store.navigateDown()
                return true
            }
            if (key.isLeft || key.isRight) && !cmd && !opt && !ctrl {
                return false
            }
            if opt && !cmd && !ctrl && (chars == "." || keyCodeIsPeriod(key)) {
                store.toggleFoldSelected()
                return true
            }
            // Empty title + ⌫ → delete node and select previous (BrainstormNode / outliner).
            if key.isDelete && !cmd && !opt && !ctrl {
                if store.deleteEmptyEditingNode() { return true }
                // Non-empty draft: let the text field delete characters.
                return false
            }
            // Space and other printables: prefer the real text field when focused.
            if inTextField, !cmd, !opt, !ctrl, !chars.isEmpty {
                return false
            }
            // Salvage path if the title field lost first-responder (still append).
            if !cmd, !opt, !ctrl,
               !chars.isEmpty,
               Self.isTitleTypingCharacter(chars)
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
            // Structural modifier arrows remain available outside the title
            // editor. While editing, the guarded path above keeps them out of
            // the tree and lets horizontal caret movement stay native.
            if !opt && !ctrl {
                if key.isUp { store.moveSelectedUp(); return true }
                if key.isDown { store.moveSelectedDown(); return true }
                if key.isRight { store.indentSelected(); return true }
                if key.isLeft { store.outdentSelected(); return true }
            }
            // ⌘↩ — rename mode (select all, ready to replace).
            if key.isReturn { store.beginEditing(selectAll: true); return true }
            // Zoom: ⌘= / ⌘+ / ⌘- / ⌘0
            if !opt && !ctrl {
                if chars == "=" || chars == "+" {
                    store.zoomIn()
                    return true
                }
                if chars == "-" || chars == "_" {
                    store.zoomOut()
                    return true
                }
                if chars == "0" {
                    store.zoomReset()
                    return true
                }
            }
            switch chars.lowercased() {
            case "r" where !opt && !ctrl:
                store.goToMainNode()
                return true
            case "f" where !opt && !ctrl:
                // ⇧⌘F = focus mode. Plain ⌘F search is temporarily disabled.
                if shift {
                    store.toggleFocusMode()
                    return true
                }
                return false
            // ⌘G search-next temporarily disabled with search UI.
            case "s":
                fileActions?.save(shift)
                return fileActions != nil
            case "o":
                fileActions?.open()
                return fileActions != nil
            case "n":
                fileActions?.new()
                return fileActions != nil
            case "t" where !opt && !ctrl && !shift:
                fileActions?.newTab()
                return fileActions != nil
            case "w" where !opt && !ctrl && !shift:
                fileActions?.close()
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
            // ⌥ + arrows: nudge free position
            if key.isUp { store.nudgeSelected(dx: 0, dy: -10); return true }
            if key.isDown { store.nudgeSelected(dx: 0, dy: 10); return true }
            if key.isLeft { store.nudgeSelected(dx: -10, dy: 0); return true }
            if key.isRight { store.nudgeSelected(dx: 10, dy: 0); return true }
            // ⌃⌘R style: ⌥R reset position (also available in inspector)
            if chars.lowercased() == "r" {
                store.resetPosition()
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

        // Space — enter edit mode at end of existing title (extend / insert, not replace).
        if !cmd, !opt, !ctrl, chars == " " {
            store.ensureSelection()
            store.beginEditing(selectAll: false)
            return true
        }

        // Type-to-edit: first letter/digit/punctuation replaces the title.
        if !chars.isEmpty,
           !cmd, !opt, !ctrl,
           Self.isTitleTypingCharacter(chars),
           chars != " "
        {
            store.ensureSelection()
            store.beginEditing(seed: chars)
            return true
        }

        return false
    }

    /// Characters that belong in a node title (including space).
    private static func isTitleTypingCharacter(_ chars: String) -> Bool {
        chars.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch.isPunctuation || ch == " " || ch.isSymbol
        }
    }

    private static func keyCodeIsPeriod(_ key: Key) -> Bool {
        key.keyCode == 47
    }
}

// MARK: - Always-on key monitor

private struct KeyboardMonitor: NSViewRepresentable {
    let store: BrainstormStore
    /// True while the toolbar search field owns focus (SwiftUI FocusState).
    var isSearchFocused: () -> Bool
    var onDismissSearch: () -> Void
    var onSave: (Bool) -> Void
    var onOpen: () -> Void
    var onNew: () -> Void
    var onNewTab: () -> Void
    var onClose: () -> Void
    var onShowHelp: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.store = store
        view.isSearchFocused = isSearchFocused
        view.onDismissSearch = onDismissSearch
        view.onSave = onSave
        view.onOpen = onOpen
        view.onNew = onNew
        view.onNewTab = onNewTab
        view.onClose = onClose
        view.onShowHelp = onShowHelp
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.store = store
        nsView.isSearchFocused = isSearchFocused
        nsView.onDismissSearch = onDismissSearch
        nsView.onSave = onSave
        nsView.onOpen = onOpen
        nsView.onNew = onNew
        nsView.onNewTab = onNewTab
        nsView.onClose = onClose
        nsView.onShowHelp = onShowHelp
    }
}

final class KeyCatcherView: NSView {
    var store: BrainstormStore?
    var isSearchFocused: (() -> Bool)?
    var onDismissSearch: (() -> Void)?
    var onSave: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onNew: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onClose: (() -> Void)?
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
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let shift = flags.contains(.shift)
        let ctrl = flags.contains(.control)
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let first = window?.firstResponder
        let inTextInput = Self.isTextInputResponder(first)
        let searchFocused = isSearchFocused?() ?? false

        // Toolbar search (or any non–node-title text field): never type-to-edit / Tab-add-child.
        // Node title edit sets store.isEditing — that path stays on the key router.
        let chromeTextActive = (inTextInput || searchFocused) && !store.isEditing
        if chromeTextActive {
            return handleChromeTextKey(
                store: store,
                cmd: cmd, opt: opt, shift: shift, ctrl: ctrl,
                chars: chars,
                keyCode: event.keyCode
            )
        }

        // Allow standard text-editing chords inside the node title field.
        if inTextInput {
            if cmd && ["a", "c", "v", "x", "z"].contains(chars) {
                return false
            }
        }

        return BrainstormKeyRouter.handle(
            store: store,
            key: .from(event: event),
            modifiers: .init(
                command: cmd,
                option: opt,
                shift: shift,
                control: ctrl
            ),
            inTextField: inTextInput && store.isEditing,
            fileActions: .init(
                save: { [weak self] saveAs in self?.onSave?(saveAs) },
                open: { [weak self] in self?.onOpen?() },
                new: { [weak self] in self?.onNew?() },
                newTab: { [weak self] in self?.onNewTab?() },
                close: { [weak self] in self?.onClose?() },
                showHelp: { [weak self] in self?.onShowHelp?() }
            )
        )
    }

    /// Keys while search / inspector / other chrome text is focused (not node title).
    @MainActor
    private func handleChromeTextKey(
        store: BrainstormStore,
        cmd: Bool, opt: Bool, shift: Bool, ctrl: Bool,
        chars: String,
        keyCode: UInt16
    ) -> Bool {
        // Esc clears search and returns focus to the canvas map.
        if keyCode == 53 /* escape */, !cmd, !opt, !ctrl {
            onDismissSearch?()
            return true
        }

        guard cmd, !opt, !ctrl else {
            // All plain typing, arrows, Tab, Return stay in the text field.
            return false
        }

        switch chars {
        case "s":
            onSave?(shift)
            return true
        case "o":
            onOpen?()
            return true
        case "n":
            onNew?()
            return true
        case "t" where !shift:
            onNewTab?()
            return true
        case "w" where !shift:
            onClose?()
            return true
        case "z":
            if shift { store.redo() } else { store.undo() }
            return true
        case "/":
            onShowHelp?()
            return true
        case "f", "g":
            // Search temporarily disabled.
            return false
        default:
            // ⌘A/C/V/X and other field chords.
            return false
        }
    }

    private static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView || responder is NSTextField { return true }
        // Field editor for NSTextField is often an NSTextView subclass; also cover NSText.
        if responder is NSText { return true }
        return false
    }
}

#Preview {
    ContentView(store: BrainstormStore(startEditing: false))
        .frame(width: 900, height: 600)
}
