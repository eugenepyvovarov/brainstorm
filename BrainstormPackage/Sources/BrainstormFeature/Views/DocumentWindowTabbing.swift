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

enum ApplicationTerminationPreparation: Equatable {
    /// This document is clean, or its requested save completed successfully.
    case proceed
    /// Quit may proceed, but recovery state must be reset only after every
    /// other live document has also approved termination.
    case discard
    /// Keep the application and every document window open.
    case cancel
}

@MainActor
protocol ApplicationTerminationParticipant: AnyObject {
    var documentID: UUID { get }

    func prepareForApplicationTermination()
        -> ApplicationTerminationPreparation

    func discardUnsavedChangesForApplicationTermination()
}

/// Pure two-phase review shared by the AppKit termination bridge and tests.
///
/// Save is completed by each participant during preparation. Destructive
/// discard cleanup is intentionally delayed until every participant approves,
/// so Cancel on a later tab cannot alter an earlier still-open document.
@MainActor
enum ApplicationTerminationReview {
    static func shouldTerminate(
        participants: [any ApplicationTerminationParticipant]
    ) -> Bool {
        var pendingDiscards: [any ApplicationTerminationParticipant] = []

        for participant in participants {
            switch participant.prepareForApplicationTermination() {
            case .proceed:
                continue
            case .discard:
                pendingDiscards.append(participant)
            case .cancel:
                return false
            }
        }

        for participant in pendingDiscards {
            participant.discardUnsavedChangesForApplicationTermination()
        }
        return true
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
    private enum ApplicationTerminationReviewState {
        case idle
        case reviewing
        case approved
    }
    private static var applicationTerminationReviewState:
        ApplicationTerminationReviewState = .idle

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
        isCommandTarget(
            window,
            keyWindow: NSApp.keyWindow,
            fallbackDocumentID: DocumentSession.shared.state.activeDocumentID
        )
    }

    /// Injectable identities keep command routing deterministic in tests.
    ///
    /// A key map window always wins. If an auxiliary window (Theme Manager or
    /// Welcome) is key, route the command to the last active map only.
    static func isCommandTarget(
        _ window: NSWindow,
        keyWindow: NSWindow?,
        fallbackDocumentID: UUID?
    ) -> Bool {
        if let tabGroup = window.tabGroup,
           tabGroup.selectedWindow !== window
        {
            return false
        }
        if keyWindow === window { return true }
        if let keyWindow, documentID(for: keyWindow) != nil { return false }
        guard let fallbackDocumentID else { return false }
        return documentID(for: window) == fallbackDocumentID
    }

    /// Bring an already-open document forward rather than opening its URL twice.
    ///
    /// A persisted session descriptor can outlive its process-local window.
    /// Return whether activation actually happened so callers can reopen a
    /// dormant descriptor instead of silently treating it as visible.
    @discardableResult
    public static func activate(documentID: UUID) -> Bool {
        guard let window = window(for: documentID) else { return false }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Enter or leave native full screen for the exact document window.
    ///
    /// Presentation mode stays in the existing document scene so its store,
    /// autosave identity, and native tab selection remain authoritative.
    /// AppKit completes this transition asynchronously; callers should observe
    /// `NSWindow.didEnterFullScreenNotification` and
    /// `NSWindow.didExitFullScreenNotification` before changing lifecycle state.
    @discardableResult
    public static func setFullScreen(_ shouldEnter: Bool, documentID: UUID) -> Bool {
        guard let window = window(for: documentID) else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard isFullScreen != shouldEnter else { return true }
        window.toggleFullScreen(nil)
        return true
    }

    public static func isFullScreen(documentID: UUID) -> Bool {
        window(for: documentID)?.styleMask.contains(.fullScreen) == true
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

        // AppKit may size the newly-created SwiftUI window from the
        // WindowGroup default while it is being merged. Capture the current
        // host frame so the tab operation cannot resize the user's window.
        let preservedFrame = parent.frame
        let hasPreservedFrame = preservedFrame.width > 0 && preservedFrame.height > 0

        func restorePreservedFrame() {
            guard hasPreservedFrame else { return }
            parent.setFrame(preservedFrame, display: false)
            window.setFrame(preservedFrame, display: false)
        }

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

        restorePreservedFrame()

        if let group = parent.tabGroup {
            group.addWindow(window)
            group.selectedWindow = select ? window : parent
        } else {
            parent.addTabbedWindow(window, ordered: .above)
            parent.tabGroup?.selectedWindow = select ? window : parent
        }

        // SwiftUI can apply the new scene's default size on the next run-loop
        // turn. Restore once more after the native tab group is established.
        DispatchQueue.main.async { [weak parent, weak window] in
            guard let parent, let window else { return }
            guard parent.tabGroup?.windows.contains(where: { $0 === window }) == true else { return }
            parent.setFrame(preservedFrame, display: false)
            window.setFrame(preservedFrame, display: false)
        }

    }

    public static func isMapWindow(_ window: NSWindow) -> Bool {
        documentID(for: window) != nil
    }

    /// Review every live map before AppKit terminates the process.
    ///
    /// `NSWindowDelegate.windowShouldClose` is not called for application Quit,
    /// so the app delegate enters here and waits for one reply after the native
    /// Save / Don’t Save / Cancel review has completed.
    public static func applicationShouldTerminate(
        _ application: NSApplication
    ) -> NSApplication.TerminateReply {
        switch applicationTerminationReviewState {
        case .reviewing:
            return .terminateLater
        case .approved:
            return .terminateNow
        case .idle:
            break
        }

        let participants = applicationTerminationParticipants()
        guard !participants.isEmpty else {
            return .terminateNow
        }

        applicationTerminationReviewState = .reviewing
        DispatchQueue.main.async {
            let shouldTerminate = ApplicationTerminationReview.shouldTerminate(
                participants: participants
            )
            applicationTerminationReviewState =
                shouldTerminate ? .approved : .idle
            application.reply(
                toApplicationShouldTerminate: shouldTerminate
            )
        }
        return .terminateLater
    }

    private static func applicationTerminationParticipants()
        -> [any ApplicationTerminationParticipant]
    {
        let liveIDs = Set(windowsByDocumentID.compactMap { id, window in
            window.value == nil ? nil : id
        })
        var orderedIDs: [UUID] = []

        if let activeID = DocumentSession.shared.state.activeDocumentID,
           liveIDs.contains(activeID)
        {
            orderedIDs.append(activeID)
        }
        for descriptor in DocumentSession.shared.state.openDocuments
        where liveIDs.contains(descriptor.id)
            && !orderedIDs.contains(descriptor.id)
        {
            orderedIDs.append(descriptor.id)
        }
        for id in liveIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) where !orderedIDs.contains(id) {
            orderedIDs.append(id)
        }

        return orderedIDs.compactMap { id in
            guard let window = windowsByDocumentID[id]?.value else {
                windowsByDocumentID.removeValue(forKey: id)
                return nil
            }
            return window.delegate as? any ApplicationTerminationParticipant
        }
    }

    private static func reconcileTab(for childDocumentID: UUID) {
        guard let intent = tabIntents.intent(for: childDocumentID) else { return }
        guard let child = window(for: childDocumentID) else { return }
        guard let parent = window(for: intent.parentDocumentID) else { return }

        tabIntents.remove(childDocumentID: childDocumentID)
        attachAsTab(child, into: parent, select: intent.selectsNewTab)
    }

}
