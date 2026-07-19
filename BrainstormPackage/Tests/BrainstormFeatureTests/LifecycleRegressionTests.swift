import Foundation
import Testing
@testable import BrainstormFeature

@Suite("Presentation full-screen lifecycle")
struct PresentationFullScreenLifecycleTests {
    @Test func exitBeforeQueuedEntryCancelsTheRequest() {
        var lifecycle = PresentationFullScreenLifecycle()

        let beginEffect = lifecycle.begin(isWindowFullScreen: false)
        #expect(beginEffect == .requestEntry)
        #expect(lifecycle.phase == .preparingEntry)
        let exitEffect = lifecycle.requestExit()
        #expect(exitEffect == .finish)
        #expect(lifecycle.phase == .inactive)
        let shouldRequestEntry = lifecycle.prepareEntryRequest()
        #expect(!shouldRequestEntry)
    }

    @Test func exitDuringEntryWaitsForDidEnterThenDidExit() {
        var lifecycle = PresentationFullScreenLifecycle()

        let beginEffect = lifecycle.begin(isWindowFullScreen: false)
        #expect(beginEffect == .requestEntry)
        let shouldRequestEntry = lifecycle.prepareEntryRequest()
        #expect(shouldRequestEntry)
        let entryEffect = lifecycle.entryRequestCompleted(requested: true)
        #expect(entryEffect == .none)
        let earlyExitEffect = lifecycle.requestExit()
        #expect(earlyExitEffect == .none)
        #expect(lifecycle.phase == .exitPendingDuringEntry)

        let didEnterEffect = lifecycle.didEnter()
        #expect(didEnterEffect == .requestExit)
        #expect(lifecycle.phase == .exiting)
        let exitRequestEffect = lifecycle.exitRequestCompleted(
            expectsDidExit: true
        )
        #expect(exitRequestEffect == .none)
        let didExitEffect = lifecycle.didExit()
        #expect(didExitEffect == .finish)
        #expect(lifecycle.phase == .inactive)
    }

    @Test func failedEntryLeavesAWindowedPresentationThatCanClose() {
        var lifecycle = PresentationFullScreenLifecycle()

        let beginEffect = lifecycle.begin(isWindowFullScreen: false)
        #expect(beginEffect == .requestEntry)
        let shouldRequestEntry = lifecycle.prepareEntryRequest()
        #expect(shouldRequestEntry)
        let entryEffect = lifecycle.entryRequestCompleted(requested: false)
        #expect(entryEffect == .none)
        #expect(lifecycle.phase == .windowed)
        let exitEffect = lifecycle.requestExit()
        #expect(exitEffect == .finish)
        #expect(lifecycle.phase == .inactive)
    }

    @Test func asynchronousEntryFailureLeavesAWindowedPresentation() {
        var lifecycle = PresentationFullScreenLifecycle()

        let beginEffect = lifecycle.begin(isWindowFullScreen: false)
        #expect(beginEffect == .requestEntry)
        let prepared = lifecycle.prepareEntryRequest()
        #expect(prepared)
        let requestedEffect = lifecycle.entryRequestCompleted(requested: true)
        #expect(requestedEffect == .none)
        let failureEffect = lifecycle.didFailToEnter()
        #expect(failureEffect == .none)
        #expect(lifecycle.phase == .windowed)
        let exitEffect = lifecycle.requestExit()
        #expect(exitEffect == .finish)
        #expect(lifecycle.phase == .inactive)
    }

    @Test func asynchronousExitFailureCanBeRetried() {
        var lifecycle = PresentationFullScreenLifecycle()

        let beginEffect = lifecycle.begin(isWindowFullScreen: true)
        #expect(beginEffect == .none)
        let exitEffect = lifecycle.requestExit()
        #expect(exitEffect == .requestExit)
        let requestedEffect = lifecycle.exitRequestCompleted(
            expectsDidExit: true
        )
        #expect(requestedEffect == .none)
        let failureEffect = lifecycle.didFailToExit()
        #expect(failureEffect == .none)
        #expect(lifecycle.phase == .active)
        let retryEffect = lifecycle.requestExit()
        #expect(retryEffect == .requestExit)
    }
}

@Suite("Delayed note autosave lifecycle", .serialized)
@MainActor
struct DelayedNoteAutosaveLifecycleTests {
    @Test func synchronousAutosaveConsumesDelayedWriteBeforeClose() async throws {
        let documentID = UUID()
        let store = BrainstormStore(
            documentID: documentID,
            root: .root(),
            startEditing: false
        )
        defer { DocumentSession.shared.closeDocument(documentID) }

        try store.setNoteBody("Pending recovery", for: store.root.id)
        #expect(store.performAutosave())
        DocumentSession.shared.closeDocument(documentID)

        try await Task.sleep(for: .milliseconds(450))
        #expect(DocumentSession.shared.descriptor(for: documentID) == nil)
    }

    @Test func explicitCancellationPreventsDiscardedSessionFromReturning() async throws {
        let documentID = UUID()
        let store = BrainstormStore(
            documentID: documentID,
            root: .root(),
            startEditing: false
        )
        defer { DocumentSession.shared.closeDocument(documentID) }

        #expect(store.performAutosave())
        try store.setNoteBody("Discard me", for: store.root.id)
        store.cancelPendingNoteAutosave()
        DocumentSession.shared.closeDocument(documentID)

        try await Task.sleep(for: .milliseconds(450))
        #expect(DocumentSession.shared.descriptor(for: documentID) == nil)
    }

    @Test func editorTeardownAfterFinalCloseCannotRecreateSession() async throws {
        let documentID = UUID()
        let store = BrainstormStore(
            documentID: documentID,
            root: .root(),
            startEditing: false
        )
        defer { DocumentSession.shared.closeDocument(documentID) }

        store.beginNoteEditing(id: store.root.id)
        try store.updateNoteEditingDraft("Close with editor mounted")
        // Mirrors ContentView.finalizeDocumentClose: finish the active session,
        // consume its delayed write, then remove the descriptor.
        store.commitNoteEditing()
        #expect(store.performAutosave())
        store.cancelPendingNoteAutosave()
        DocumentSession.shared.closeDocument(documentID)

        // SwiftUI's editor onDisappear runs after the host window is removed.
        store.commitNoteEditing()
        try await Task.sleep(for: .milliseconds(450))
        #expect(DocumentSession.shared.descriptor(for: documentID) == nil)
    }

    @Test func returningToOriginalNoteSynchronouslyReplacesRecovery() throws {
        let documentID = UUID()
        let original = NodeNote(bodyMarkdown: "Original")
        let store = BrainstormStore(
            documentID: documentID,
            root: BrainstormNode(title: "Root", note: original),
            startEditing: false
        )
        defer { DocumentSession.shared.closeDocument(documentID) }

        store.beginNoteEditing(id: store.root.id)
        try store.updateNoteEditingDraft("Modified recovery")
        #expect(store.performAutosave())
        try store.updateNoteEditingDraft(original.bodyMarkdown)
        store.commitNoteEditing()

        let recovered = try DocumentSession.shared.readAutosave(for: documentID)
        #expect(recovered.root.note == original)
        #expect(
            DocumentSession.shared.descriptor(for: documentID)?.isDirty
                == false
        )
    }

    @Test func cancellingNoteSynchronouslyReplacesRecovery() throws {
        let documentID = UUID()
        let original = NodeNote(bodyMarkdown: "Original")
        let store = BrainstormStore(
            documentID: documentID,
            root: BrainstormNode(title: "Root", note: original),
            startEditing: false
        )
        defer { DocumentSession.shared.closeDocument(documentID) }

        store.beginNoteEditing(id: store.root.id)
        try store.updateNoteEditingDraft("Cancelled recovery")
        #expect(store.performAutosave())
        store.cancelNoteEditing()

        let recovered = try DocumentSession.shared.readAutosave(for: documentID)
        #expect(recovered.root.note == original)
        #expect(
            DocumentSession.shared.descriptor(for: documentID)?.isDirty
                == false
        )
    }
}
