import AppKit
import Foundation
import Observation

/// One entry in File → Open Recent.
public struct RecentDocumentEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var pathHint: String
    public var bookmark: Data?
    public var lastOpenedAt: Date

    public init(
        id: String,
        displayName: String,
        pathHint: String,
        bookmark: Data? = nil,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.bookmark = bookmark
        self.lastOpenedAt = lastOpenedAt
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
    public static let shared = RecentDocuments()

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
        let entry = RecentDocumentEntry(
            id: path,
            displayName: name,
            pathHint: path,
            bookmark: bookmark,
            lastOpenedAt: Date()
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
