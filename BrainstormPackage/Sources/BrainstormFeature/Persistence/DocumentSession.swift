import AppKit
import Foundation
import Observation

// MARK: - Session models

/// One open mind map window (user file and/or autosave).
public struct OpenDocumentDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Security-scoped bookmark for the user’s Save location (nil = untitled / autosave only).
    public var fileBookmark: Data?
    public var filePathHint: String?
    /// Always present under Application Support/Autosave.
    public var autosaveFileName: String
    public var lastEditedAt: Date
    public var displayName: String
    /// Explicit dirty flag — do not infer “edited” merely because an autosave exists.
    public var isDirty: Bool
    /// Monotonic content revision (bumped on user edits); compared to `savedRevision`.
    public var contentRevision: Int
    /// Revision last known equal to the user’s saved file (or pristine untitled seed).
    public var savedRevision: Int

    public init(
        id: UUID = UUID(),
        fileBookmark: Data? = nil,
        filePathHint: String? = nil,
        autosaveFileName: String? = nil,
        lastEditedAt: Date = Date(),
        displayName: String = "Untitled",
        isDirty: Bool = false,
        contentRevision: Int = 0,
        savedRevision: Int = 0
    ) {
        self.id = id
        self.fileBookmark = fileBookmark
        self.filePathHint = filePathHint
        self.autosaveFileName = autosaveFileName ?? "\(id.uuidString).\(BrainstormCodec.fileExtension)"
        self.lastEditedAt = lastEditedAt
        self.displayName = displayName
        self.isDirty = isDirty
        self.contentRevision = contentRevision
        self.savedRevision = savedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        filePathHint = try c.decodeIfPresent(String.self, forKey: .filePathHint)
        autosaveFileName = try c.decode(String.self, forKey: .autosaveFileName)
        lastEditedAt = try c.decode(Date.self, forKey: .lastEditedAt)
        displayName = try c.decode(String.self, forKey: .displayName)
        isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        contentRevision = try c.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
        savedRevision = try c.decodeIfPresent(Int.self, forKey: .savedRevision) ?? 0
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public var openDocuments: [OpenDocumentDescriptor]
    public var activeDocumentID: UUID?

    public init(openDocuments: [OpenDocumentDescriptor] = [], activeDocumentID: UUID? = nil) {
        self.openDocuments = openDocuments
        self.activeDocumentID = activeDocumentID
    }

    public static let empty = SessionState()
}

// MARK: - Document session (autosave + restore)

/// Application Support autosave + multi-window session restore.
@Observable
@MainActor
public final class DocumentSession {
    public static let shared: DocumentSession = {
        // UI tests must never mutate the user's real recovery session.
        if let sessionID = ProcessInfo.processInfo.environment["BRAINSTORM_UI_TEST_SESSION_ID"],
           !sessionID.isEmpty
        {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrainstormUITests-\(sessionID)", isDirectory: true)
            return DocumentSession(supportDirectory: directory)
        }
        return DocumentSession()
    }()

    public private(set) var state: SessionState
    /// Ensures we only open extra restored windows once per launch.
    public private(set) var didRestoreExtraWindows = false
    /// Finder / Dock dropped a document before multi-window restore — open only those files.
    public private(set) var suppressSessionWindowRestore = false
    /// Cold launch via double-click: first window should show the opened file (not last session).
    public private(set) var replacePrimaryForExternalOpen = false

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public let supportDirectory: URL
    public let autosaveDirectory: URL
    public let sessionFileURL: URL

    public convenience init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(
            supportDirectory: base.appendingPathComponent("Brainstorm", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Test / custom-location initializer (does not touch the shared app session).
    public init(supportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()

        self.supportDirectory = supportDirectory
        autosaveDirectory = supportDirectory.appendingPathComponent("Autosave", isDirectory: true)
        sessionFileURL = supportDirectory.appendingPathComponent("session.json")

        try? fileManager.createDirectory(at: autosaveDirectory, withIntermediateDirectories: true)
        state = Self.loadState(from: sessionFileURL, decoder: decoder) ?? .empty
    }

    // MARK: - Launch

    /// Document id for the first window. Prefers last active, else most recently edited, else new.
    public func launchDocumentID() -> UUID {
        if let active = state.activeDocumentID,
           state.openDocuments.contains(where: { $0.id == active })
        {
            return active
        }
        if let newest = state.openDocuments.max(by: { $0.lastEditedAt < $1.lastEditedAt }) {
            return newest.id
        }
        return registerNewDocument().id
    }

    /// The primary document for session recovery, if there is real user work
    /// to recover. A clean untitled seed is intentionally not a session to
    /// restore: launch should show the welcome screen instead.
    public func launchRestorableDocumentID() -> UUID? {
        let documents = state.openDocuments.filter(isRestorable)
        if let active = state.activeDocumentID,
           documents.contains(where: { $0.id == active })
        {
            return active
        }
        return documents.max(by: { $0.lastEditedAt < $1.lastEditedAt })?.id
    }

    /// Extra window ids to open after the first window appears.
    public func additionalDocumentIDsToRestore(primary: UUID) -> [UUID] {
        guard !suppressSessionWindowRestore else { return [] }
        return state.openDocuments
            .filter(isRestorable)
            .map(\.id)
            .filter { $0 != primary }
    }

    public func markExtraWindowsRestored() {
        didRestoreExtraWindows = true
    }

    /// Call when Launch Services delivers document URLs (Finder double-click / Dock drop).
    /// Skips restoring every previously open map so only the requested file(s) appear.
    public func beginDocumentOpenLaunch() {
        // App already running — multi-window restore already finished; just open the file(s).
        guard !didRestoreExtraWindows else { return }
        suppressSessionWindowRestore = true
        replacePrimaryForExternalOpen = true
    }

    /// Whether the first window should load the external file (cold document-open launch).
    public func consumeReplacePrimaryForExternalOpen() -> Bool {
        let value = replacePrimaryForExternalOpen
        replacePrimaryForExternalOpen = false
        return value
    }

    /// Drop session entries that never got a window.
    ///
    /// **Do not call during Finder / external open** — that orphans recovery autosaves.
    /// Only use when the user has explicitly closed documents or reset the session.
    public func pruneSession(keeping ids: Set<UUID>) {
        let before = state.openDocuments.map(\.id)
        state.openDocuments.removeAll { !ids.contains($0.id) }
        if let active = state.activeDocumentID, !ids.contains(active) {
            state.activeDocumentID = state.openDocuments.first?.id
        }
        if state.openDocuments.map(\.id) != before {
            persistSession()
        }
    }

    // MARK: - Register / update

    @discardableResult
    public func registerNewDocument(displayName: String = "Untitled") -> OpenDocumentDescriptor {
        let desc = OpenDocumentDescriptor(displayName: displayName)
        // Seed empty autosave so restore always finds a file.
        // Use the last theme the user picked so new maps match their preference.
        let empty = BrainstormFile(root: .root(), themeID: AppTheme.preferredDefaultID)
        try? writeAutosave(file: empty, fileName: desc.autosaveFileName)
        upsert(desc)
        state.activeDocumentID = desc.id
        persistSession()
        return desc
    }

    public func ensureRegistered(_ id: UUID) -> OpenDocumentDescriptor {
        if let existing = state.openDocuments.first(where: { $0.id == id }) {
            return existing
        }
        let desc = OpenDocumentDescriptor(id: id)
        let empty = BrainstormFile(root: .root(), themeID: AppTheme.preferredDefaultID)
        try? writeAutosave(file: empty, fileName: desc.autosaveFileName)
        upsert(desc)
        persistSession()
        return desc
    }

    public func descriptor(for id: UUID) -> OpenDocumentDescriptor? {
        state.openDocuments.first { $0.id == id }
    }

    /// Existing session document for a file path, used to focus an already-open
    /// map instead of creating duplicate tabs for repeated Launch Services events.
    public func documentID(forFileURL url: URL) -> UUID? {
        let requestedPath = Self.canonicalPath(url)
        return state.openDocuments.first { descriptor in
            guard let hint = descriptor.filePathHint else { return false }
            return Self.canonicalPath(URL(fileURLWithPath: hint)) == requestedPath
        }?.id
    }

    public func setActive(_ id: UUID) {
        guard state.openDocuments.contains(where: { $0.id == id }) else { return }
        // No-op when already active — avoids session.json thrash during view re-inits.
        guard state.activeDocumentID != id else { return }
        state.activeDocumentID = id
        persistSession()
    }

    public func touch(
        id: UUID,
        displayName: String? = nil,
        fileURL: URL? = nil,
        isDirty: Bool? = nil,
        contentRevision: Int? = nil,
        savedRevision: Int? = nil
    ) {
        guard var desc = descriptor(for: id) else { return }
        desc.lastEditedAt = Date()
        if let displayName { desc.displayName = displayName }
        if let fileURL {
            desc.filePathHint = fileURL.path
            desc.fileBookmark = makeBookmark(for: fileURL)
        }
        if let isDirty { desc.isDirty = isDirty }
        if let contentRevision { desc.contentRevision = contentRevision }
        if let savedRevision { desc.savedRevision = savedRevision }
        upsert(desc)
        persistSession()
    }

    public func updateFileURL(_ id: UUID, url: URL?) {
        guard var desc = descriptor(for: id) else { return }
        if let url {
            desc.filePathHint = url.path
            desc.fileBookmark = makeBookmark(for: url)
            desc.displayName = url.deletingPathExtension().lastPathComponent
        } else {
            desc.filePathHint = nil
            desc.fileBookmark = nil
        }
        desc.lastEditedAt = Date()
        upsert(desc)
        persistSession()
    }

    /// Record clean/dirty + revisions without rewriting the autosave payload.
    public func updateDirtyState(
        id: UUID,
        isDirty: Bool,
        contentRevision: Int,
        savedRevision: Int
    ) {
        guard var desc = descriptor(for: id) else { return }
        guard desc.isDirty != isDirty
            || desc.contentRevision != contentRevision
            || desc.savedRevision != savedRevision
        else { return }
        desc.isDirty = isDirty
        desc.contentRevision = contentRevision
        desc.savedRevision = savedRevision
        desc.lastEditedAt = Date()
        upsert(desc)
        persistSession()
    }

    public func closeDocument(_ id: UUID) {
        state.openDocuments.removeAll { $0.id == id }
        if state.activeDocumentID == id {
            state.activeDocumentID = state.openDocuments.first?.id
        }
        // Keep autosave file so “reopen last” can still recover briefly; prune later.
        persistSession()
    }

    /// Apply a final “Don’t Save” decision during application termination.
    ///
    /// Saved documents remain in the restorable session, but their recovery
    /// snapshot is replaced with the last user-saved bytes. Untitled documents,
    /// or saved files that can no longer be read safely, are removed from the
    /// session so discarded recovery content can never reappear on relaunch.
    public func discardUnsavedChangesForTermination(_ id: UUID) {
        guard var descriptor = descriptor(for: id) else { return }
        guard let fileURL = resolvedFileURL(for: id) else {
            closeDocument(id)
            return
        }

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let savedFile = try BrainstormCodec.load(from: fileURL)
            try writeAutosave(
                file: savedFile,
                fileName: descriptor.autosaveFileName
            )
            // The rotated backup contains the pre-discard recovery snapshot.
            // Once the saved bytes are safely installed, it must not be used
            // as a later fallback for changes the user explicitly discarded.
            let backupURL = autosaveFileURL(for: id)
                .appendingPathExtension("bak")
            try? fileManager.removeItem(at: backupURL)

            let cleanRevision = max(
                descriptor.contentRevision,
                descriptor.savedRevision
            )
            descriptor.isDirty = false
            descriptor.contentRevision = cleanRevision
            descriptor.savedRevision = cleanRevision
            descriptor.lastEditedAt = Date()
            upsert(descriptor)
            persistSession()
        } catch {
            // If the saved file or clean autosave cannot be established, drop
            // the descriptor rather than resurrecting discarded edits.
            closeDocument(id)
        }
    }

    // MARK: - Autosave I/O

    public func autosaveFileURL(for id: UUID) -> URL {
        let name = descriptor(for: id)?.autosaveFileName ?? "\(id.uuidString).\(BrainstormCodec.fileExtension)"
        return autosaveDirectory.appendingPathComponent(name)
    }

    public func writeAutosave(file: BrainstormFile, for id: UUID) throws {
        let desc = ensureRegistered(id)
        try writeAutosave(file: file, fileName: desc.autosaveFileName)
        touch(id: id, displayName: displayName(for: file))
    }

    public func readAutosave(for id: UUID) throws -> BrainstormFile {
        let url = autosaveFileURL(for: id)
        return try BrainstormCodec.load(from: url)
    }

    public func hasAutosave(for id: UUID) -> Bool {
        fileManager.fileExists(atPath: autosaveFileURL(for: id).path)
    }

    /// Resolve user file URL from bookmark if possible.
    public func resolvedFileURL(for id: UUID) -> URL? {
        guard let desc = descriptor(for: id) else { return nil }
        if let data = desc.fileBookmark, let url = resolveBookmark(data) {
            return url
        }
        if let path = desc.filePathHint {
            let url = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Restore store payload

    public struct RestorePayload: Sendable {
        public var root: BrainstormNode
        public var themeID: String
        public var fileURL: URL?
        public var isDirty: Bool
        public var startEditing: Bool
    }

    /// Load best available content for a document id (user file if clean path, else autosave).
    public func restorePayload(for id: UUID) -> RestorePayload {
        let desc = ensureRegistered(id)

        // Prefer autosave when present — it has the latest edits including unsaved work.
        if let auto = readAutosavePreferringBackup(for: id) {
            let fileURL = resolvedFileURL(for: id)
            // Prefer explicit session dirty/revision flags (seeded autosave ≠ dirty).
            let dirty: Bool
            if desc.contentRevision != desc.savedRevision || desc.isDirty {
                dirty = desc.isDirty || desc.contentRevision != desc.savedRevision
            } else if let fileURL, let disk = try? BrainstormCodec.load(from: fileURL) {
                // Autosaves are always canonical v3, while a clean user file
                // may still be v1/v2. Compare document content rather than the
                // envelope version so migration alone does not create a false
                // recovery edit.
                dirty = !Self.hasSameDocumentContent(disk, auto)
            } else {
                // Untitled with matching revisions → clean (fresh window / seed autosave).
                dirty = false
            }
            let emptyTitle = auto.root.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || auto.root.title == BrainstormNode.mainPlaceholder
            return RestorePayload(
                root: auto.root,
                themeID: auto.themeID.flatMap { AppTheme.theme(id: $0).id } ?? AppTheme.preferredDefaultID,
                fileURL: fileURL,
                isDirty: dirty,
                startEditing: emptyTitle && auto.root.children.isEmpty && !dirty
            )
        }

        if let fileURL = resolvedFileURL(for: id), let file = try? BrainstormCodec.load(from: fileURL) {
            // Mirror into autosave (best-effort).
            try? writeAutosave(file: file, for: id)
            return RestorePayload(
                root: file.root,
                themeID: file.themeID.flatMap { AppTheme.theme(id: $0).id } ?? AppTheme.preferredDefaultID,
                fileURL: fileURL,
                isDirty: false,
                startEditing: false
            )
        }

        return RestorePayload(
            root: .root(),
            themeID: AppTheme.preferredDefaultID,
            fileURL: nil,
            isDirty: false,
            startEditing: true
        )
    }

    /// Primary autosave, else last-good `.bak` after a failed write / corrupt file.
    public func readAutosavePreferringBackup(for id: UUID) -> BrainstormFile? {
        let url = autosaveFileURL(for: id)
        if let file = try? BrainstormCodec.load(from: url) { return file }
        let bak = url.appendingPathExtension("bak")
        return try? BrainstormCodec.load(from: bak)
    }

    // MARK: - Private

    private func upsert(_ desc: OpenDocumentDescriptor) {
        if let idx = state.openDocuments.firstIndex(where: { $0.id == desc.id }) {
            state.openDocuments[idx] = desc
        } else {
            state.openDocuments.append(desc)
        }
    }

    /// Saved files and genuinely edited untitled maps are worth reopening.
    /// `registerNewDocument` seeds an empty autosave, but that is a launch
    /// implementation detail rather than user work that should bypass Welcome.
    private func isRestorable(_ descriptor: OpenDocumentDescriptor) -> Bool {
        descriptor.filePathHint != nil
            || descriptor.isDirty
            || descriptor.contentRevision != descriptor.savedRevision
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func hasSameDocumentContent(
        _ lhs: BrainstormFile,
        _ rhs: BrainstormFile
    ) -> Bool {
        lhs.root.canonicalized() == rhs.root.canonicalized()
            && lhs.themeID == rhs.themeID
    }

    private func writeAutosave(file: BrainstormFile, fileName: String) throws {
        try fileManager.createDirectory(at: autosaveDirectory, withIntermediateDirectories: true)
        let url = autosaveDirectory.appendingPathComponent(fileName)
        let tmp = url.appendingPathExtension("tmp")
        let bak = url.appendingPathExtension("bak")
        // Write temp → rotate previous to .bak → promote temp. Keeps last good copy on failure.
        if fileManager.fileExists(atPath: tmp.path) {
            try? fileManager.removeItem(at: tmp)
        }
        try BrainstormCodec.save(file, to: tmp)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: bak)
            try fileManager.moveItem(at: url, to: bak)
        }
        try fileManager.moveItem(at: tmp, to: url)
    }

    private func persistSession() {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: sessionFileURL, options: .atomic)
        } catch {
            // Best-effort; don't crash the editor.
        }
    }

    private static func loadState(from url: URL, decoder: JSONDecoder) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionState.self, from: data)
    }

    private func displayName(for file: BrainstormFile) -> String {
        let t = file.root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == BrainstormNode.mainPlaceholder { return "Untitled" }
        return String(t.prefix(48))
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        // Do not leave security scope open — callers start/stop around each I/O.
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url
    }
}
