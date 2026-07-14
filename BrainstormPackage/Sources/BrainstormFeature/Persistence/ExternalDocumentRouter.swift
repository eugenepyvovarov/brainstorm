import Foundation

/// Queues Finder / Launch Services open-document URLs until a map window can handle them.
@MainActor
public final class ExternalDocumentRouter {
    public static let shared = ExternalDocumentRouter()

    private var pendingURLs: [URL] = []

    public init() {}

    /// Called from the app delegate when macOS delivers document open events.
    public func receive(urls: [URL]) {
        let supported = urls.filter { Self.isSupportedMap($0) }
        guard !supported.isEmpty else { return }
        var pendingKeys = Set(pendingURLs.map(Self.canonicalPath))
        for url in supported where pendingKeys.insert(Self.canonicalPath(url)).inserted {
            pendingURLs.append(url)
        }
        // Tell session restore not to reopen every map from last quit.
        DocumentSession.shared.beginDocumentOpenLaunch()
        NotificationCenter.default.post(name: .brainstormExternalDocumentsAvailable, object: nil)
    }

    /// Drain the queue (caller owns opening).
    public func takePending() -> [URL] {
        let urls = pendingURLs
        pendingURLs = []
        return urls
    }

    public var hasPending: Bool { !pendingURLs.isEmpty }

    /// `.bs` Brainstorm documents only.
    public static func isSupportedMap(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == BrainstormCodec.fileExtension
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
