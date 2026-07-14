import AppKit
import Foundation

struct DocumentTabIntent: Equatable, Sendable {
    let parentDocumentID: UUID
    let selectsNewTab: Bool
}

/// Pure identity bookkeeping kept separate from AppKit so rapid and interleaved
/// window creation can be regression-tested without a running UI application.
struct DocumentTabIntentRegistry: Sendable {
    private var intents: [UUID: DocumentTabIntent] = [:]

    mutating func set(
        childDocumentID: UUID,
        parentDocumentID: UUID,
        select: Bool
    ) {
        intents[childDocumentID] = DocumentTabIntent(
            parentDocumentID: parentDocumentID,
            selectsNewTab: select
        )
    }

    func intent(for childDocumentID: UUID) -> DocumentTabIntent? {
        intents[childDocumentID]
    }

    func children(waitingFor parentDocumentID: UUID) -> [UUID] {
        intents.compactMap { childID, intent in
            intent.parentDocumentID == parentDocumentID ? childID : nil
        }
    }

    mutating func remove(childDocumentID: UUID) {
        intents.removeValue(forKey: childDocumentID)
    }

    mutating func remove(documentID: UUID) {
        intents.removeValue(forKey: documentID)
        intents = intents.filter { $0.value.parentDocumentID != documentID }
    }

}

/// Deterministic native macOS document tabs for Brainstorm map windows.
///
/// SwiftUI creates one `NSWindow` for each `WindowGroup` value. We keep that
/// model, but key every tab request by document identity instead of guessing
/// which newly-created app window belongs to the request.
@MainActor
public enum DocumentWindowTabbing {
    /// Shared across every mind-map window so AppKit's manual tab commands can
    /// merge and detach Brainstorm windows normally.
    public static let identifier: NSWindow.TabbingIdentifier =
        NSWindow.TabbingIdentifier("com.eugenep.Brainstorm.map")

    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow) {
            self.value = value
        }
    }

    private static var windowsByDocumentID: [UUID: WeakWindow] = [:]
    private static var documentIDsByWindow: [ObjectIdentifier: UUID] = [:]
    private static var tabIntents = DocumentTabIntentRegistry()

    /// Brainstorm owns the distinction between New Window and New Tab.
    ///
    /// AppKit explicitly allows automatic grouping to be disabled while still
    /// supporting explicit `addTabbedWindow` calls and the standard tab menu.
    public static func configureApplicationTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Register the exact document hosted by `window` and consume any tab
    /// intent waiting for either this child or this parent.
    public static func configure(_ window: NSWindow, documentID: UUID) {
        configureApplicationTabbing()

        if let previousID = documentIDsByWindow[ObjectIdentifier(window)], previousID != documentID {
            windowsByDocumentID.removeValue(forKey: previousID)
        }

        window.tabbingIdentifier = identifier
        // Preferred keeps native tab UI and manual Merge/Move commands available.
        // Automatic grouping is disabled app-wide, so this does not merge ⌘N windows.
        window.tabbingMode = .preferred
        windowsByDocumentID[documentID] = WeakWindow(window)
        documentIDsByWindow[ObjectIdentifier(window)] = documentID

        reconcileTab(for: documentID)
        for childID in tabIntents.children(waitingFor: documentID) {
            reconcileTab(for: childID)
        }
    }

    /// Forget a closing/dismantled hosting window without disturbing a newer
    /// window that may already host the same document value.
    public static func unregister(documentID: UUID, window: NSWindow?) {
        guard let registered = windowsByDocumentID[documentID]?.value else {
            windowsByDocumentID.removeValue(forKey: documentID)
            if let window {
                documentIDsByWindow.removeValue(forKey: ObjectIdentifier(window))
            }
            tabIntents.remove(documentID: documentID)
            return
        }
        guard window == nil || registered === window else { return }

        windowsByDocumentID.removeValue(forKey: documentID)
        documentIDsByWindow.removeValue(forKey: ObjectIdentifier(registered))
        tabIntents.remove(documentID: documentID)
    }

    public static func window(for documentID: UUID) -> NSWindow? {
        guard let window = windowsByDocumentID[documentID]?.value else {
            windowsByDocumentID.removeValue(forKey: documentID)
            return nil
        }
        return window
    }

    public static func documentID(for window: NSWindow) -> UUID? {
        let key = ObjectIdentifier(window)
        guard let documentID = documentIDsByWindow[key],
              windowsByDocumentID[documentID]?.value === window
        else {
            documentIDsByWindow.removeValue(forKey: key)
            return nil
        }
        return documentID
    }

    /// Native tab groups can report stale key-window state for hidden members.
    /// Commands must target only the selected tab; standalone windows use AppKit key state.
    public static func isCommandTarget(_ window: NSWindow) -> Bool {
        if let tabGroup = window.tabGroup {
            return tabGroup.selectedWindow === window
        }
        return window.isKeyWindow
    }

    /// Bring an already-open document forward rather than opening its URL twice.
    public static func activate(documentID: UUID) {
        guard let window = window(for: documentID) else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Create a document window that will join `parentDocumentID` when both
    /// exact hosting windows exist. Multiple requests can be outstanding safely.
    public static func openAsTab(
        documentID: UUID,
        parentDocumentID: UUID,
        select: Bool = true,
        open: () -> Void
    ) {
        configureApplicationTabbing()
        guard documentID != parentDocumentID else {
            open()
            return
        }

        tabIntents.set(
            childDocumentID: documentID,
            parentDocumentID: parentDocumentID,
            select: select
        )
        open()
        reconcileTab(for: documentID)
    }

    /// Open a document with no tab intent. Automatic grouping is disabled, so
    /// this remains a separate top-level window regardless of system preference.
    public static func openAsWindow(documentID: UUID, open: () -> Void) {
        configureApplicationTabbing()
        tabIntents.remove(childDocumentID: documentID)
        open()
    }

    /// Attach `window` as a native tab on `parent` and select the requested tab.
    public static func attachAsTab(
        _ window: NSWindow,
        into parent: NSWindow,
        select: Bool = true
    ) {
        guard window !== parent else { return }

        configureApplicationTabbing()
        parent.tabbingIdentifier = identifier
        parent.tabbingMode = .preferred
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred

        if let group = parent.tabGroup,
           group.windows.contains(where: { $0 === window })
        {
            group.selectedWindow = select ? window : parent
            return
        }

        // The bridge runs from `viewDidMoveToWindow`, before SwiftUI's extra
        // dispatch turn. Mask any ordering animation while AppKit groups it.
        let originalAnimation = window.animationBehavior
        let originalAlpha = window.alphaValue
        window.animationBehavior = .none
        window.alphaValue = 0
        defer {
            window.alphaValue = originalAlpha
            window.animationBehavior = originalAnimation
        }

        if parent.frame.size.width > 0, parent.frame.size.height > 0 {
            window.setFrame(parent.frame, display: false)
        }

        if let group = parent.tabGroup {
            group.addWindow(window)
            group.selectedWindow = select ? window : parent
        } else {
            parent.addTabbedWindow(window, ordered: .above)
            parent.tabGroup?.selectedWindow = select ? window : parent
        }

    }

    public static func isMapWindow(_ window: NSWindow) -> Bool {
        documentID(for: window) != nil
    }

    private static func reconcileTab(for childDocumentID: UUID) {
        guard let intent = tabIntents.intent(for: childDocumentID) else { return }
        guard let child = window(for: childDocumentID) else { return }
        guard let parent = window(for: intent.parentDocumentID) else { return }

        tabIntents.remove(childDocumentID: childDocumentID)
        attachAsTab(child, into: parent, select: intent.selectsNewTab)
    }

}
