import AppKit
import SwiftUI

/// Focused WYSIWYG composition surface for one node.
///
/// Rich text stays local to AppKit while the user types. The editor publishes
/// canonical Markdown after a short idle period and when it closes, keeping a
/// continuous edit as one document undo operation without exposing Markdown.
struct NodeNoteEditorView: View {
    private struct IndexedAttachment {
        let index: Int
        let attachment: NodeNoteAttachment
    }

    @Bindable var store: BrainstormStore

    private let nodeID: UUID

    @State private var bodyDraft = ""
    @State private var commandRequest: NodeNoteTextCommandRequest?
    @State private var expectedHistoryEpoch: UInt64?
    @State private var formattingState = NodeNoteFormattingState()
    @State private var textUndoBoundaryID = UUID()
    @State private var isBodySessionActive = false
    @State private var isBodyLocallyEmpty = true
    @State private var validationMessage: String?
    @State private var showClearConfirmation = false

    private var note: NodeNote? {
        store.node(id: nodeID)?.note
    }

    private var hasContent: Bool {
        note?.isEmpty == false
    }

    private var imageAttachments: [NoteImageAttachment] {
        note?.attachments.compactMap { attachment in
            guard case .image(let image) = attachment else { return nil }
            return image
        } ?? []
    }

    init(store: BrainstormStore, nodeID: UUID) {
        self.store = store
        self.nodeID = nodeID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            formattingToolbar
            richTextEditor

            if let validationMessage {
                validationBanner(validationMessage)
            }
        }
        .padding(16)
        .onAppear(perform: beginBodyEditing)
        .onDisappear(perform: commitBodyEditing)
        .onChange(of: store.noteEpoch) { _, _ in
            synchronizeBodyFromStoreIfNeeded()
        }
        .onChange(of: store.historyEpoch) { _, newEpoch in
            if let expectedHistoryEpoch,
               expectedHistoryEpoch != newEpoch
            {
                textUndoBoundaryID = UUID()
            }
            expectedHistoryEpoch = newEpoch
        }
        .confirmationDialog(
            "Clear this note?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Note", role: .destructive, action: clearNote)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note text and all of its images and videos will be removed.")
        }
        .accessibilityIdentifier("nodeNoteCompositionSurface")
    }

    private func validationBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Note validation error")
            .accessibilityValue(message)
            .accessibilityIdentifier("noteValidationMessage")
    }

    private var richTextEditor: some View {
        ZStack(alignment: .topLeading) {
            NodeNoteTextEditor(
                text: Binding(
                    get: { bodyDraft },
                    set: { newValue in
                        updateBodyDraft(newValue)
                    }
                ),
                imageAttachments: imageAttachments,
                commandRequest: commandRequest,
                undoBoundaryID: textUndoBoundaryID,
                onYouTubeLinksDetected: { references, bodyMarkdown in
                    embedDetectedYouTubeLinks(
                        references,
                        bodyMarkdown: bodyMarkdown
                    )
                },
                onImagePasted: { data, suggestedAltText in
                    attachPastedImage(
                        data,
                        suggestedAltText: suggestedAltText
                    )
                },
                onImageAttachmentsRemoved: { attachmentIDs, bodyMarkdown in
                    removeInlineImages(
                        attachmentIDs,
                        bodyMarkdown: bodyMarkdown
                    )
                },
                onTeardown: commitBodyEditing,
                onContentStateChange: { isEmpty in
                    isBodyLocallyEmpty = isEmpty
                },
                onFormattingStateChange: { state in
                    formattingState = state
                },
                onValidationFailure: { message in
                    validationMessage = message
                }
            )

            if isBodyLocallyEmpty {
                Text("Write a note…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 220, idealHeight: 320, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .layoutPriority(1)
    }

    private var formattingToolbar: some View {
        HStack(spacing: 10) {
            BrainstormGlassGroup(spacing: 4) {
                HStack(spacing: 4) {
                    formattingButton(
                        label: "Bold",
                        shortcut: "⌘B",
                        systemImage: "bold",
                        identifier: "noteFormatBold",
                        command: .bold
                    )
                    formattingButton(
                        label: "Italic",
                        shortcut: "⌘I",
                        systemImage: "italic",
                        identifier: "noteFormatItalic",
                        command: .italic
                    )

                    Divider()
                        .frame(height: 18)

                    formattingButton(
                        label: "Bulleted list",
                        shortcut: "⇧⌘8",
                        systemImage: "list.bullet",
                        identifier: "noteFormatUnorderedList",
                        command: .unorderedList
                    )
                    formattingButton(
                        label: "Numbered list",
                        shortcut: "⇧⌘7",
                        systemImage: "list.number",
                        identifier: "noteFormatOrderedList",
                        command: .orderedList
                    )
                }
            }

            Text("Paste links or images directly")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            if hasContent {
                Button {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .brainstormGlassCapsule(interactive: true)
                .contentShape(Capsule(style: .continuous))
                .help("Clear note")
                .accessibilityLabel("Clear note")
                .accessibilityIdentifier("clearNodeNote")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note formatting")
    }

    private func formattingButton(
        label: String,
        shortcut: String,
        systemImage: String,
        identifier: String,
        command: NodeNoteTextCommand
    ) -> some View {
        let state = formattingState.state(for: command)
        let tint: Color? = switch state {
        case .off:
            nil
        case .on:
            store.theme.selectionColor.opacity(0.82)
        case .mixed:
            store.theme.selectionColor.opacity(0.38)
        }

        return Button {
            commandRequest = NodeNoteTextCommandRequest(command: command)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: systemImage)

                if state == .mixed {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(store.theme.selectionColor)
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(command.keyboardShortcut)
        .brainstormGlassCapsule(interactive: true, tint: tint)
        .contentShape(Capsule(style: .continuous))
        .help("\(label) (\(shortcut)): \(state.accessibilityValue)")
        .accessibilityLabel(label)
        .accessibilityValue(state.accessibilityValue)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func beginBodyEditing() {
        guard !isBodySessionActive else { return }
        let currentNote = note
        bodyDraft = currentNote?.bodyMarkdown ?? ""
        isBodyLocallyEmpty = currentNote?.isEmpty ?? true
        store.beginNoteEditing(id: nodeID)
        isBodySessionActive = true
        expectedHistoryEpoch = store.historyEpoch
        validationMessage = nil
    }

    private func updateBodyDraft(_ newValue: String) {
        do {
            try NodeNoteValidator.validateBody(newValue)
            // Save checkpoints the current coalesced edit and immediately
            // starts a continuation session. Also recover defensively if a
            // lifecycle action ended the store session while this view stayed
            // mounted.
            if !isBodySessionActive || store.noteEditingID != nodeID {
                store.beginNoteEditing(id: nodeID)
                isBodySessionActive = true
            }
            try store.updateNoteEditingDraft(newValue)
            bodyDraft = newValue
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func commitBodyEditing() {
        guard isBodySessionActive else { return }
        store.commitNoteEditing()
        isBodySessionActive = false
    }

    private func synchronizeBodyFromStoreIfNeeded() {
        guard store.noteEditingID != nodeID else { return }
        isBodySessionActive = false
        let storedNote = store.node(id: nodeID)?.note
        let storedBody = storedNote?.bodyMarkdown ?? ""
        if bodyDraft != storedBody {
            bodyDraft = storedBody
        }
        isBodyLocallyEmpty = storedNote?.isEmpty ?? true
    }

    @discardableResult
    private func performDiscreteMutation(
        resetsTextUndo: Bool = true,
        _ mutation: () throws -> Void
    ) -> Bool {
        let shouldResume = isBodySessionActive
        commitBodyEditing()
        let succeeded: Bool
        var failureMessage: String?
        do {
            try mutation()
            succeeded = true
        } catch {
            failureMessage = error.localizedDescription
            succeeded = false
        }
        if shouldResume {
            beginBodyEditing()
        }
        if succeeded, resetsTextUndo {
            textUndoBoundaryID = UUID()
        }
        if succeeded {
            expectedHistoryEpoch = store.historyEpoch
        }
        validationMessage = failureMessage
        return succeeded
    }

    private func embedDetectedYouTubeLinks(
        _ references: [String],
        bodyMarkdown: String
    ) -> NodeNoteYouTubeLinkTransaction? {
        let existingVideos = Set(
            note?.attachments.compactMap { attachment -> String? in
                guard case .youtube(let video) = attachment else {
                    return nil
                }
                return Self.youtubeIdentity(
                    videoID: video.videoID,
                    startSeconds: video.startSeconds
                )
            } ?? []
        )
        var seen = existingVideos
        let missingReferences = references.filter { reference in
            guard let parsed = try? YouTubeReferenceParser.parse(reference)
            else {
                return false
            }
            return seen.insert(
                Self.youtubeIdentity(
                    videoID: parsed.videoID,
                    startSeconds: parsed.startSeconds
                )
            ).inserted
        }
        guard !missingReferences.isEmpty else { return nil }

        let before = note
        var addedIDs: [UUID] = []
        guard performDiscreteMutation(resetsTextUndo: false, {
            addedIDs = try store.embedNoteYouTubeLinks(
                missingReferences,
                bodyMarkdown: bodyMarkdown,
                for: nodeID
            )
        }) else {
            return nil
        }
        let after = note
        let added = indexedAttachments(
            in: after,
            matching: Set(addedIDs)
        )
        guard !added.isEmpty else { return nil }
        return attachmentTransaction(
            added,
            undoShouldContainAttachments: false,
            fallbackNote: after ?? before
        )
    }

    private func attachPastedImage(
        _ data: Data,
        suggestedAltText: String
    ) -> NodeNoteImageInsertion? {
        let altText = suggestedAltText.nilIfBlank ?? "Pasted image"
        let attachment: NoteImageAttachment
        do {
            attachment = try store.prepareNoteImageForEditor(
                data,
                altText: altText,
                for: nodeID
            )
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            return nil
        }
        let before = note
        let insertionIndex = before?.attachments.count ?? 0

        return NodeNoteImageInsertion(
            attachment: attachment,
            commit: {
                do {
                    let inserted = try store.commitPreparedNoteImageForEditor(
                        attachment,
                        for: nodeID
                    )
                    guard inserted, let after = note else {
                        _ = try? store.restoreNoteEditorTransaction(
                            nodeID: nodeID,
                            note: before
                        )
                        validationMessage = "The image could not be added to this note."
                        return nil
                    }
                    isBodySessionActive = true
                    expectedHistoryEpoch = store.historyEpoch
                    validationMessage = nil

                    return attachmentTransaction(
                        [
                            IndexedAttachment(
                                index: insertionIndex,
                                attachment: .image(attachment)
                            )
                        ],
                        undoShouldContainAttachments: false,
                        fallbackNote: after
                    )
                } catch {
                    validationMessage = error.localizedDescription
                    return nil
                }
            }
        )
    }

    private func removeInlineImages(
        _ attachmentIDs: [UUID],
        bodyMarkdown: String
    ) -> NodeNoteStoreTransaction? {
        if bodyDraft != bodyMarkdown {
            updateBodyDraft(bodyMarkdown)
            guard bodyDraft == bodyMarkdown else { return nil }
        }

        let ids = Set(attachmentIDs)
        let before = note
        let removed = indexedAttachments(in: before, matching: ids)
        guard removed.count == ids.count else { return nil }

        var removedAll = true
        guard performDiscreteMutation(resetsTextUndo: false, {
            for id in attachmentIDs {
                removedAll = store.removeNoteAttachment(id, from: nodeID)
                    && removedAll
            }
        }),
        removedAll
        else {
            if let before {
                _ = try? store.restoreNoteEditorTransaction(
                    nodeID: nodeID,
                    note: before
                )
            }
            return nil
        }

        return attachmentTransaction(
            removed,
            undoShouldContainAttachments: true,
            fallbackNote: before
        )
    }

    private func indexedAttachments(
        in note: NodeNote?,
        matching ids: Set<UUID>
    ) -> [IndexedAttachment] {
        note?.attachments.enumerated().compactMap { index, attachment in
            ids.contains(attachment.id)
                ? IndexedAttachment(index: index, attachment: attachment)
                : nil
        } ?? []
    }

    private func attachmentTransaction(
        _ attachments: [IndexedAttachment],
        undoShouldContainAttachments: Bool,
        fallbackNote: NodeNote?
    ) -> NodeNoteStoreTransaction {
        NodeNoteStoreTransaction(
            undo: {
                restoreAttachments(
                    attachments,
                    shouldContainAttachments: undoShouldContainAttachments,
                    fallbackNote: fallbackNote
                )
            },
            redo: {
                restoreAttachments(
                    attachments,
                    shouldContainAttachments: !undoShouldContainAttachments,
                    fallbackNote: fallbackNote
                )
            }
        )
    }

    private func restoreAttachments(
        _ attachments: [IndexedAttachment],
        shouldContainAttachments: Bool,
        fallbackNote: NodeNote?
    ) {
        let attachmentIDs = Set(attachments.map(\.attachment.id))
        guard shouldContainAttachments || note != nil else {
            return
        }
        var restored = note ?? fallbackNote ?? NodeNote()
        restored.attachments.removeAll { attachmentIDs.contains($0.id) }
        if shouldContainAttachments {
            for entry in attachments.sorted(by: { $0.index < $1.index }) {
                restored.attachments.insert(
                    entry.attachment,
                    at: min(entry.index, restored.attachments.count)
                )
            }
        }

        do {
            try store.restoreNoteEditorTransaction(
                nodeID: nodeID,
                note: restored.isEmpty ? nil : restored
            )
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func clearNote() {
        commitBodyEditing()
        if store.clearNote(for: nodeID) {
            textUndoBoundaryID = UUID()
        }
        bodyDraft = ""
        isBodyLocallyEmpty = true
        validationMessage = nil
        beginBodyEditing()
    }

    private static func youtubeIdentity(
        videoID: String,
        startSeconds: Int?
    ) -> String {
        "\(videoID):\(startSeconds ?? 0)"
    }
}

struct MultiSelectionNotesView: View {
    let count: Int
    let note: NodeNote?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    "Select one node to edit its note. The primary node’s note is shown read-only.",
                    systemImage: "square.stack.3d.up.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let note, !note.isEmpty {
                    NodeNoteContentView(note: note, mode: .preview)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityIdentifier("multiSelectionNotePreview")
                } else {
                    Text("The primary node has no note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                }
            }
            .padding(12)
        }
        .disabled(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) nodes selected. Notes are read-only.")
        .accessibilityIdentifier("multiSelectionNotesReadOnly")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
