import AppKit
import Foundation
import Observation

/// A saved top-level map window frame in macOS screen coordinates.
public struct RecentDocumentWindowFrame: Codable, Hashable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(_ frame: CGRect) {
        originX = frame.origin.x
        originY = frame.origin.y
        width = frame.width
        height = frame.height
    }

    public var rect: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }
}

/// One entry in File → Open Recent.
public struct RecentDocumentEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var pathHint: String
    public var bookmark: Data?
    public var lastOpenedAt: Date
    /// Last standalone window geometry for this saved map, if it has been closed before.
    public var windowFrame: RecentDocumentWindowFrame?

    public init(
        id: String,
        displayName: String,
        pathHint: String,
        bookmark: Data? = nil,
        lastOpenedAt: Date = Date(),
        windowFrame: RecentDocumentWindowFrame? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.bookmark = bookmark
        self.lastOpenedAt = lastOpenedAt
        self.windowFrame = windowFrame
    }

    /// Short title for the menu (filename without extension).
    public var menuTitle: String {
        if displayName.isEmpty {
            return URL(fileURLWithPath: pathHint).deletingPathExtension().lastPathComponent
        }
        return displayName
    }
}

/// MRU list of mind map files the user opened or saved (Application Support).
@Observable
@MainActor
public final class RecentDocuments {
    public static let shared: RecentDocuments = {
        // UI tests must never read or mutate the user's real recent maps.
        // Keep this beside the isolated DocumentSession data so tests can seed
        // both sides of a relaunch/recovery scenario before the app starts.
        if let sessionID = ProcessInfo.processInfo.environment["BRAINSTORM_UI_TEST_SESSION_ID"],
           !sessionID.isEmpty
        {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrainstormUITests-\(sessionID)", isDirectory: true)
            let recents = RecentDocuments(
                storageURL: directory.appendingPathComponent("recents.json")
            )
            #if DEBUG
            recents.seedDormantUITestRecentIfRequested(in: directory)
            #endif
            return recents
        }
        return RecentDocuments()
    }()

    public private(set) var items: [RecentDocumentEntry] = []

    public var maxCount: Int = 12

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL

    public convenience init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("Brainstorm", isDirectory: true)
        self.init(storageURL: dir.appendingPathComponent("recents.json"), fileManager: fileManager)
    }

    /// Test / custom-location initializer.
    public init(storageURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = storageURL
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
        items = Self.load(from: storageURL, decoder: decoder) ?? []
    }

    /// Record a successfully opened or saved file (MRU).
    public func note(url: URL) {
        let path = url.path
        guard !path.isEmpty else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let previous = items.first { $0.id == path || $0.pathHint == path }
        let entry = RecentDocumentEntry(
            id: path,
            displayName: name,
            pathHint: path,
            bookmark: bookmark,
            lastOpenedAt: Date(),
            windowFrame: previous?.windowFrame
        )
        items.removeAll { $0.id == entry.id || $0.pathHint == path }
        items.insert(entry, at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        persist()
        // Also feed the system recent-documents list (Dock / some menu integrations).
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Remember a saved map's final top-level window frame before it is closed.
    public func noteWindowFrame(_ frame: CGRect, for url: URL) {
        let path = url.path
        guard let index = items.firstIndex(where: { $0.id == path || $0.pathHint == path }) else { return }
        items[index].windowFrame = RecentDocumentWindowFrame(frame)
        persist()
    }

    /// A previously saved frame, made safe for the current monitor layout.
    public func restoredWindowFrame(for url: URL) -> CGRect? {
        let path = url.path
        guard let frame = items.first(where: { $0.id == path || $0.pathHint == path })?.windowFrame else {
            return nil
        }
        return Self.fittedWindowFrame(
            frame.rect,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackVisibleFrame: NSScreen.main?.visibleFrame
        )
    }

    /// Keep a saved frame visible after monitors are disconnected or rearranged.
    static func fittedWindowFrame(
        _ frame: CGRect,
        visibleFrames: [CGRect],
        fallbackVisibleFrame: CGRect? = nil
    ) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let available = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
        guard let fallback = fallbackVisibleFrame ?? available.first else { return nil }
        let target = available.max { lhs, rhs in
            lhs.intersection(frame).width * lhs.intersection(frame).height
                < rhs.intersection(frame).width * rhs.intersection(frame).height
        }.flatMap { candidate in
            candidate.intersects(frame) ? candidate : nil
        } ?? fallback

        let size = CGSize(
            width: min(frame.width, target.width),
            height: min(frame.height, target.height)
        )
        return CGRect(
            x: min(max(frame.minX, target.minX), target.maxX - size.width),
            y: min(max(frame.minY, target.minY), target.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    public func clear() {
        items = []
        persist()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Resolve a recent entry to a file URL (bookmark preferred).
    public func resolveURL(for entry: RecentDocumentEntry) -> URL? {
        if let data = entry.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        let url = URL(fileURLWithPath: entry.pathHint)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public func entry(id: String) -> RecentDocumentEntry? {
        items.first { $0.id == id }
    }

    #if DEBUG
    /// XCUITest runners and the sandboxed app cannot write into each other's
    /// containers. Seed this narrowly-scoped recovery fixture inside the app
    /// process when the UI test explicitly requests it.
    private func seedDormantUITestRecentIfRequested(in directory: URL) {
        let environment = ProcessInfo.processInfo.environment
        guard let title = environment["BRAINSTORM_UI_TEST_DORMANT_RECENT_TITLE"],
              !title.isEmpty
        else { return }

        let childTitle = environment["BRAINSTORM_UI_TEST_DORMANT_RECENT_CHILD"]
            ?? "Recovered child fixture"
        var root = BrainstormNode.root(title: title)
        root.children = [BrainstormNode(title: childTitle)]
        let file = BrainstormFile(root: root)
        let url = directory.appendingPathComponent(title).appendingPathExtension("bs")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try BrainstormCodec.save(file, to: url)

            let descriptor = DocumentSession.shared.registerNewDocument(displayName: title)
            DocumentSession.shared.updateFileURL(descriptor.id, url: url)
            try DocumentSession.shared.writeAutosave(file: file, for: descriptor.id)
            DocumentSession.shared.updateDirtyState(
                id: descriptor.id,
                isDirty: false,
                contentRevision: 0,
                savedRevision: 0
            )
            items = [RecentDocumentEntry(
                id: url.path,
                displayName: title,
                pathHint: url.path,
                lastOpenedAt: Date()
            )]
            persist()
        } catch {
            // The UI assertion reports a missing fixture with the app hierarchy.
        }
    }
    #endif

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort.
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [RecentDocumentEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([RecentDocumentEntry].self, from: data)
    }
}
