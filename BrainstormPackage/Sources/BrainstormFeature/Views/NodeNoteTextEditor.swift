import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NodeNoteTextCommand: Equatable, Sendable {
    case bold
    case italic
    case unorderedList
    case orderedList

    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .bold:
            KeyboardShortcut("b", modifiers: .command)
        case .italic:
            KeyboardShortcut("i", modifiers: .command)
        case .unorderedList:
            KeyboardShortcut("8", modifiers: [.command, .shift])
        case .orderedList:
            KeyboardShortcut("7", modifiers: [.command, .shift])
        }
    }
}

enum NodeNoteFormatSelectionState: Equatable, Sendable {
    case off
    case on
    case mixed

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .mixed: "Mixed"
        }
    }
}

struct NodeNoteFormattingState: Equatable, Sendable {
    var bold: NodeNoteFormatSelectionState = .off
    var italic: NodeNoteFormatSelectionState = .off
    var unorderedList: NodeNoteFormatSelectionState = .off
    var orderedList: NodeNoteFormatSelectionState = .off

    func state(for command: NodeNoteTextCommand) -> NodeNoteFormatSelectionState {
        switch command {
        case .bold: bold
        case .italic: italic
        case .unorderedList: unorderedList
        case .orderedList: orderedList
        }
    }
}

struct NodeNoteTextCommandRequest: Equatable, Sendable {
    let id = UUID()
    let command: NodeNoteTextCommand
}

struct NodeNoteStoreTransaction {
    let undo: () -> Void
    let redo: () -> Void
}

typealias NodeNoteYouTubeLinkTransaction = NodeNoteStoreTransaction

struct NodeNoteImageInsertion {
    let attachment: NoteImageAttachment
    /// Commits the already-rendered attachment to the document model.
    ///
    /// TextKit inserts first so an observation-driven SwiftUI refresh cannot
    /// race ahead of the local selection and attachment update.
    let commit: () -> NodeNoteStoreTransaction?
}

/// WYSIWYG note editor backed by TextKit 2.
///
/// AppKit owns rich text, selection, native copy/paste, and the local undo
/// stack. SwiftUI receives only deterministic Markdown for `.bs` persistence;
/// Markdown punctuation is never inserted into the visible editor.
struct NodeNoteTextEditor: NSViewRepresentable {
    private static let publishDelay: TimeInterval = 0.22

    @Binding var text: String
    let imageAttachments: [NoteImageAttachment]
    let commandRequest: NodeNoteTextCommandRequest?
    let undoBoundaryID: UUID?
    let onYouTubeLinksDetected:
        (_ references: [String], _ bodyMarkdown: String) -> NodeNoteYouTubeLinkTransaction?
    let onImagePasted:
        (_ data: Data, _ suggestedAltText: String) -> NodeNoteImageInsertion?
    let onImageAttachmentsRemoved:
        (_ attachmentIDs: [UUID], _ bodyMarkdown: String) -> NodeNoteStoreTransaction?
    let onTeardown: () -> Void
    let onContentStateChange: (_ isEmpty: Bool) -> Void
    let onFormattingStateChange: (NodeNoteFormattingState) -> Void
    let onValidationFailure: (String) -> Void

    init(
        text: Binding<String>,
        imageAttachments: [NoteImageAttachment] = [],
        commandRequest: NodeNoteTextCommandRequest?,
        undoBoundaryID: UUID? = nil,
        onYouTubeLinksDetected: @escaping (
            _ references: [String],
            _ bodyMarkdown: String
        ) -> NodeNoteYouTubeLinkTransaction? = { _, _ in nil },
        onImagePasted: @escaping (
            _ data: Data,
            _ suggestedAltText: String
        ) -> NodeNoteImageInsertion? = { _, _ in nil },
        onImageAttachmentsRemoved: @escaping (
            _ attachmentIDs: [UUID],
            _ bodyMarkdown: String
        ) -> NodeNoteStoreTransaction? = { _, _ in nil },
        onTeardown: @escaping () -> Void = {},
        onContentStateChange: @escaping (_ isEmpty: Bool) -> Void = { _ in },
        onFormattingStateChange: @escaping (NodeNoteFormattingState) -> Void = { _ in },
        onValidationFailure: @escaping (String) -> Void = { _ in }
    ) {
        _text = text
        self.imageAttachments = imageAttachments
        self.commandRequest = commandRequest
        self.undoBoundaryID = undoBoundaryID
        self.onYouTubeLinksDetected = onYouTubeLinksDetected
        self.onImagePasted = onImagePasted
        self.onImageAttachmentsRemoved = onImageAttachmentsRemoved
        self.onTeardown = onTeardown
        self.onContentStateChange = onContentStateChange
        self.onFormattingStateChange = onFormattingStateChange
        self.onValidationFailure = onValidationFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        textView.textStorage?.setAttributedString(
            NodeNoteInlineImageLayout.editingDocument(
                bodyMarkdown: text,
                images: imageAttachments,
                maximumWidth: NodeNoteEmbeddedImageSizing.maximumSize.width
            )
        )
        textView.setAccessibilityLabel("Note text")
        textView.setAccessibilityRoleDescription("Rich text note editor")
        textView.setAccessibilityIdentifier("nodeNoteTextEditor")
        textView.refreshAccessibleValue()

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier("nodeNoteTextEditorScrollView")

        context.coordinator.textView = textView
        textView.onFormattingCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.apply(command)
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] data, altText in
            coordinator?.handlePastedImage(data, suggestedAltText: altText) == true
        }
        textView.onFlushPendingChanges = { [weak coordinator = context.coordinator] in
            coordinator?.flushPendingChanges()
        }
        textView.onViewportWidthChange = {
            [weak coordinator = context.coordinator, weak textView] _ in
            guard let coordinator, let textView else { return }
            coordinator.resizeInlineImages(
                maximumWidth: coordinator.availableImageWidth(in: textView)
            )
        }
        let noteDragTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            .png,
            .tiff,
            .string,
        ]
        textView.registerForDraggedTypes(
            Array(Set(textView.registeredDraggedTypes + noteDragTypes))
        )
        context.coordinator.representedMarkdown = text
        context.coordinator.estimatedCanonicalCount = text.count
        context.coordinator.canonicalMarkupOverhead = max(
            0,
            text.count - textView.string.count
        )
        context.coordinator.lastUndoBoundaryID = undoBoundaryID
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.resizeInlineImages(
                maximumWidth: coordinator.availableImageWidth(in: textView)
            )
            coordinator.publishFormattingState(from: textView)
            coordinator.publishContentState(from: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NodeNoteTextView else { return }
        context.coordinator.textView = textView

        if context.coordinator.lastUndoBoundaryID != undoBoundaryID {
            context.coordinator.lastUndoBoundaryID = undoBoundaryID
            textView.undoManager?.removeAllActions()
        }

        if context.coordinator.representedMarkdown != text,
           !context.coordinator.isSynchronizing
        {
            context.coordinator.replaceContents(
                with: text,
                images: imageAttachments,
                in: textView
            )
        } else if !context.coordinator.isSynchronizing {
            context.coordinator.reconcileInlineImages(
                imageAttachments,
                in: textView
            )
        }
        context.coordinator.resizeInlineImages(
            maximumWidth: context.coordinator.availableImageWidth(in: textView)
        )

        guard let commandRequest,
              context.coordinator.lastCommandID != commandRequest.id
        else {
            return
        }
        context.coordinator.lastCommandID = commandRequest.id
        context.coordinator.apply(commandRequest.command)
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.flushPendingChanges()
        coordinator.parent.onTeardown()
        let textView = scrollView.documentView as? NodeNoteTextView
        textView?.onFormattingCommand = nil
        textView?.onPasteImage = nil
        textView?.onFlushPendingChanges = nil
        textView?.onViewportWidthChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private enum TransactionDirection {
            case undo
            case redo
        }

        private enum TextChangeValidation: Equatable {
            case allowed
            case invalidRange
            case bodyTooLong
        }

        private final class RichTextSnapshot: NSObject {
            let attributedString: NSAttributedString
            let selection: NSRange
            var actionName: String
            var storeTransaction: NodeNoteStoreTransaction?
            var transactionDirection: TransactionDirection?

            init(
                attributedString: NSAttributedString,
                selection: NSRange,
                actionName: String = "Format Note",
                storeTransaction: NodeNoteStoreTransaction? = nil,
                transactionDirection: TransactionDirection? = nil
            ) {
                self.attributedString = attributedString
                self.selection = selection
                self.actionName = actionName
                self.storeTransaction = storeTransaction
                self.transactionDirection = transactionDirection
            }
        }

        private struct PendingRichInsertion {
            var range: NSRange
            var source: String
        }

        private struct YouTubeExtraction {
            let attributedString: NSAttributedString
            let selection: NSRange
        }

        var parent: NodeNoteTextEditor
        var representedMarkdown = ""
        var estimatedCanonicalCount = 0
        var canonicalMarkupOverhead = 0
        var lastCommandID: UUID?
        var lastUndoBoundaryID: UUID?
        var isSynchronizing = false
        var shouldScanForYouTube = false
        private var pendingRichInsertion: PendingRichInsertion?
        private var pendingRemovedImageIDs: [UUID] = []
        private var pendingManagedUndoSnapshot: RichTextSnapshot?
        private var isUndoRegistrationDisabled = false
        private var lastFormattingState: NodeNoteFormattingState?
        private var pendingPublish: DispatchWorkItem?
        private var pendingEstimatedCanonicalCount: Int?
        weak var textView: NodeNoteTextView?

        init(parent: NodeNoteTextEditor) {
            self.parent = parent
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }
            let removedImageIDs = inlineImageIDs(
                in: textView.attributedString(),
                intersecting: affectedCharRange
            )
            let canonicalPaste = (textView as? NodeNoteTextView)?
                .canonicalMarkdownBeingInserted
            let validation = validateChange(
                in: textView,
                range: affectedCharRange,
                replacementString: replacementString,
                canonicalMarkdown: canonicalPaste
            )
            guard validation == .allowed else {
                shouldScanForYouTube = false
                pendingRichInsertion = nil
                pendingRemovedImageIDs = []
                pendingEstimatedCanonicalCount = nil
                if validation == .bodyTooLong {
                    reportBodyLimitRejection(in: textView)
                } else {
                    NSSound.beep()
                }
                return false
            }

            let isBulkInsertion = replacementString.utf16.count > 1
            let explicitScanTrigger = isBulkInsertion
                || replacementString == ")"
                || replacementString.unicodeScalars.contains {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
            shouldScanForYouTube = explicitScanTrigger
                || changeCompletesYouTubeReference(
                    in: textView,
                    range: affectedCharRange,
                    replacementString: replacementString
                )
            if canonicalPaste != nil {
                pendingRichInsertion = nil
            } else if isBulkInsertion, shouldInterpretAsRichText(replacementString) {
                pendingRichInsertion = PendingRichInsertion(
                    range: affectedCharRange,
                    source: replacementString
                )
            } else {
                pendingRichInsertion = nil
            }
            pendingRemovedImageIDs = removedImageIDs
            if !removedImageIDs.isEmpty
                || canonicalPaste != nil
                || pendingRichInsertion != nil
                || shouldScanForYouTube && proposedChangeContainsYouTube(
                    in: textView,
                    range: affectedCharRange,
                    replacementString: replacementString,
                    canonicalMarkdown: canonicalPaste
                )
            {
                beginManagedUndo(for: textView)
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSynchronizing,
                  let textView = notification.object as? NSTextView
            else {
                return
            }
            publishFormattingState(from: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let textView = notification.object as? NodeNoteTextView
            else {
                return
            }

            isSynchronizing = true
            let scanForYouTube = shouldScanForYouTube
            shouldScanForYouTube = false

            normalizePendingRichInsertion(in: textView)
            if scanForYouTube {
                normalizeTypedMarkdownLinks(in: textView)
                if let storage = textView.textStorage {
                    NodeNoteRichTextCodec.applyDetectedWebLinks(to: storage)
                }
            }
            let detections = scanForYouTube
                ? NodeNoteRichTextCodec.youtubeDetections(in: textView.attributedString())
                : []
            var transactions: [NodeNoteStoreTransaction] = []
            let removedImageIDs = pendingRemovedImageIDs.filter { imageID in
                !NodeNoteInlineImageLayout.attachments(
                    in: textView.attributedString()
                ).contains { $0.attachment.noteImageID == imageID }
            }
            pendingRemovedImageIDs = []
            if !removedImageIDs.isEmpty {
                let finalMarkdown = NodeNoteRichTextCodec.markdown(
                    from: textView.attributedString()
                )
                isSynchronizing = false
                let transaction = parent.onImageAttachmentsRemoved(
                    removedImageIDs,
                    finalMarkdown
                )
                isSynchronizing = true
                if let transaction {
                    transactions.append(transaction)
                } else {
                    restorePendingManagedSnapshot(in: textView)
                    isSynchronizing = false
                    publishFormattingState(from: textView)
                    return
                }
            }
            if !detections.isEmpty {
                let extraction = youtubeExtraction(
                    detections,
                    from: textView.attributedString(),
                    selection: textView.selectedRange()
                )
                let finalMarkdown = NodeNoteRichTextCodec.markdown(
                    from: extraction.attributedString
                )
                isSynchronizing = false
                let transaction = parent.onYouTubeLinksDetected(
                    detections.map(\.reference),
                    finalMarkdown
                )
                isSynchronizing = true
                if let transaction {
                    apply(extraction, to: textView)
                    transactions.append(transaction)
                }
            }
            estimatedCanonicalCount = pendingEstimatedCanonicalCount
                ?? max(0, textView.string.count + canonicalMarkupOverhead)
            pendingEstimatedCanonicalCount = nil
            textView.refreshAccessibleValue()
            publishContentState(from: textView)
            scheduleMarkdownPublish(from: textView)
            isSynchronizing = false
            finishManagedUndo(
                for: textView,
                actionName: transactions.isEmpty
                    ? "Edit Note"
                    : !removedImageIDs.isEmpty
                        ? removedImageIDs.count == 1
                            ? "Remove Note Image"
                            : "Remove Note Images"
                    : detections.count == 1
                        ? "Embed YouTube Video"
                        : "Embed YouTube Videos",
                storeTransaction: combinedTransaction(transactions)
            )
            publishFormattingState(from: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard notification.object is NSTextView else { return }
            // File actions and the foreground workspace close path resign the
            // editor before committing the store session. Flush synchronously
            // so the final sub-debounce keystrokes are never lost.
            flushPendingChanges()
        }

        func replaceContents(
            with markdown: String,
            images: [NoteImageAttachment],
            in textView: NodeNoteTextView
        ) {
            isSynchronizing = true
            defer { isSynchronizing = false }

            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                NodeNoteInlineImageLayout.editingDocument(
                    bodyMarkdown: markdown,
                    images: images,
                    maximumWidth: availableImageWidth(in: textView)
                )
            )
            textView.typingAttributes = typingAttributes(at: selection.location, in: textView)
            textView.setSelectedRange(clamped(selection, to: textView.string.utf16.count))
            textView.undoManager?.removeAllActions()
            textView.refreshAccessibleValue()
            representedMarkdown = markdown
            estimatedCanonicalCount = markdown.count
            canonicalMarkupOverhead = max(
                0,
                markdown.count - textView.string.count
            )
            publishContentState(from: textView)
            publishFormattingState(from: textView)
        }

        func reconcileInlineImages(
            _ images: [NoteImageAttachment],
            in textView: NodeNoteTextView
        ) {
            guard let storage = textView.textStorage else { return }
            let desired = Dictionary(
                uniqueKeysWithValues: images.map { ($0.id, $0) }
            )
            let current = NodeNoteInlineImageLayout.attachments(in: storage)
            let currentIDs = Set(current.map(\.attachment.noteImageID))
            let maximumWidth = availableImageWidth(in: textView)
            var changed = false

            isSynchronizing = true
            storage.beginEditing()
            for entry in current {
                guard let image = desired[entry.attachment.noteImageID] else {
                    continue
                }
                if entry.attachment.update(
                    from: image,
                    maximumWidth: maximumWidth
                ) {
                    let safeRange = NSIntersectionRange(
                        entry.range,
                        NSRange(location: 0, length: storage.length)
                    )
                    if safeRange.length > 0 {
                        storage.addAttribute(
                            .attachment,
                            value: entry.attachment,
                            range: safeRange
                        )
                    }
                    changed = true
                }
            }
            for entry in current.reversed()
            where desired[entry.attachment.noteImageID] == nil {
                storage.deleteCharacters(in: entry.range)
                changed = true
            }
            storage.endEditing()

            for image in images where !currentIDs.contains(image.id) {
                changed = NodeNoteInlineImageLayout.append(
                    image,
                    to: storage,
                    maximumWidth: maximumWidth
                ) || changed
            }

            if images.isEmpty,
               NodeNoteRichTextCodec.markdown(from: storage).isEmpty,
               !storage.string.isEmpty
            {
                storage.setAttributedString(
                    NodeNoteRichTextCodec.attributedString(from: parent.text)
                )
                changed = true
            }

            if changed {
                textView.typingAttributes = typingAttributes(
                    at: textView.selectedRange().location,
                    in: textView
                )
                textView.setSelectedRange(
                    clamped(textView.selectedRange(), to: storage.length)
                )
                textView.refreshAccessibleValue()
                publishContentState(from: textView)
                publishFormattingState(from: textView)
            }
            isSynchronizing = false
        }

        func availableImageWidth(in textView: NSTextView) -> CGFloat {
            let viewportWidth = textView.enclosingScrollView?.contentSize.width
                ?? textView.bounds.width
            let inset = max(0, textView.textContainerInset.width * 2)
            return max(
                44,
                min(
                    NodeNoteEmbeddedImageSizing.maximumSize.width,
                    viewportWidth - inset - 4
                )
            )
        }

        func resizeInlineImages(maximumWidth: CGFloat) {
            guard let textView,
                  let storage = textView.textStorage
            else {
                return
            }
            let constrainedWidth = max(
                44,
                min(
                    NodeNoteEmbeddedImageSizing.maximumSize.width,
                    maximumWidth
                )
            )
            let entries = NodeNoteInlineImageLayout.attachments(in: storage)
            guard !entries.isEmpty else { return }

            var changedEntries: [NodeNoteInlineImageLayout.Entry] = []
            for entry in entries
            where entry.attachment.resize(maximumWidth: constrainedWidth) {
                changedEntries.append(entry)
            }
            guard !changedEntries.isEmpty else { return }

            isSynchronizing = true
            storage.beginEditing()
            for entry in changedEntries {
                storage.addAttribute(
                    .attachment,
                    value: entry.attachment,
                    range: entry.range
                )
            }
            storage.endEditing()
            textView.needsDisplay = true
            isSynchronizing = false
        }

        func apply(_ command: NodeNoteTextCommand) {
            guard let textView else { return }
            let before = RichTextSnapshot(
                attributedString: NSAttributedString(
                    attributedString: textView.attributedString()
                ),
                selection: textView.selectedRange()
            )
            isSynchronizing = true

            switch command {
            case .bold:
                toggleFontTrait(.boldFontMask, in: textView)
            case .italic:
                toggleFontTrait(.italicFontMask, in: textView)
            case .unorderedList:
                toggleList(ordered: false, in: textView)
            case .orderedList:
                toggleList(ordered: true, in: textView)
            }

            let candidateMarkdown = NodeNoteRichTextCodec.markdown(
                from: textView.attributedString()
            )
            guard candidateMarkdown.count <= NodeNoteValidator.maxBodyCharacters else {
                textView.textStorage?.setAttributedString(before.attributedString)
                textView.setSelectedRange(
                    clamped(before.selection, to: textView.string.utf16.count)
                )
                textView.typingAttributes = typingAttributes(
                    at: before.selection.location,
                    in: textView
                )
                isSynchronizing = false
                reportBodyLimitRejection(in: textView)
                publishFormattingState(from: textView)
                textView.window?.makeFirstResponder(textView)
                return
            }
            scheduleMarkdownPublish(from: textView)
            isSynchronizing = false
            if !before.attributedString.isEqual(to: textView.attributedString()) {
                registerFormattingUndo(before, in: textView)
            }
            publishFormattingState(from: textView)
            textView.window?.makeFirstResponder(textView)
        }

        private func registerFormattingUndo(
            _ snapshot: RichTextSnapshot,
            in textView: NSTextView
        ) {
            guard let undoManager = textView.undoManager else { return }
            textView.breakUndoCoalescing()
            undoManager.registerUndo(
                withTarget: self,
                selector: #selector(restoreRichTextSnapshot(_:)),
                object: snapshot
            )
            undoManager.setActionName("Format Note")
        }

        @objc
        private func restoreRichTextSnapshot(_ snapshot: RichTextSnapshot) {
            guard let textView, let undoManager = textView.undoManager else { return }
            let inverseDirection: TransactionDirection?
            switch snapshot.transactionDirection {
            case .undo:
                inverseDirection = .redo
            case .redo:
                inverseDirection = .undo
            case nil:
                inverseDirection = nil
            }
            let inverse = RichTextSnapshot(
                attributedString: NSAttributedString(
                    attributedString: textView.attributedString()
                ),
                selection: textView.selectedRange(),
                actionName: snapshot.actionName,
                storeTransaction: snapshot.storeTransaction,
                transactionDirection: inverseDirection
            )
            undoManager.registerUndo(
                withTarget: self,
                selector: #selector(restoreRichTextSnapshot(_:)),
                object: inverse
            )
            undoManager.setActionName(snapshot.actionName)

            switch snapshot.transactionDirection {
            case .undo:
                snapshot.storeTransaction?.undo()
            case .redo:
                snapshot.storeTransaction?.redo()
            case nil:
                break
            }
            isSynchronizing = true
            textView.textStorage?.setAttributedString(snapshot.attributedString)
            textView.setSelectedRange(
                clamped(snapshot.selection, to: textView.string.utf16.count)
            )
            textView.refreshAccessibleValue()
            textView.typingAttributes = typingAttributes(
                at: NSMaxRange(snapshot.selection),
                in: textView
            )
            publishContentState(from: textView)
            scheduleMarkdownPublish(from: textView)
            isSynchronizing = false
            publishFormattingState(from: textView)
            textView.window?.makeFirstResponder(textView)
        }

        private func validateChange(
            in textView: NSTextView,
            range: NSRange,
            replacementString: String,
            canonicalMarkdown: String?
        ) -> TextChangeValidation {
            let source = textView.string as NSString
            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= source.length
            else {
                return .invalidRange
            }

            let removedVisibleCount = source.substring(with: range).count
            var replacementVisibleCount = replacementString.count
            var replacementMarkupOverhead = 0
            if let canonicalMarkdown {
                let attributed = NodeNoteRichTextCodec.attributedString(
                    from: canonicalMarkdown
                )
                replacementVisibleCount = attributed.string.count
                replacementMarkupOverhead = max(
                    0,
                    canonicalMarkdown.count - replacementVisibleCount
                )
            }
            let estimated = max(
                0,
                textView.string.count
                    - removedVisibleCount
                    + replacementVisibleCount
                    + canonicalMarkupOverhead
                    + replacementMarkupOverhead
            )
            pendingEstimatedCanonicalCount = estimated

            // Formatting punctuation makes visible length only an estimate.
            // The expensive whole-document conversion is reserved for the
            // boundary where an exact answer is required.
            guard estimated > NodeNoteValidator.maxBodyCharacters - 256 else {
                return .allowed
            }
            guard let proposed = proposedAttributedString(
                in: textView,
                range: range,
                replacementString: replacementString,
                canonicalMarkdown: canonicalMarkdown
            ) else {
                pendingEstimatedCanonicalCount = nil
                return .invalidRange
            }
            let exactCount = NodeNoteRichTextCodec.markdown(from: proposed).count
            pendingEstimatedCanonicalCount = exactCount
            return exactCount <= NodeNoteValidator.maxBodyCharacters
                ? .allowed
                : .bodyTooLong
        }

        private var bodyLimitMessage: String {
            "Note text exceeds \(NodeNoteValidator.maxBodyCharacters) characters."
        }

        private func reportBodyLimitRejection(in textView: NSTextView) {
            parent.onValidationFailure(bodyLimitMessage)
            NSAccessibility.post(
                element: textView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: bodyLimitMessage,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
            NSSound.beep()
        }

        func publishFormattingState(from textView: NSTextView) {
            let state = currentFormattingState(in: textView)
            guard state != lastFormattingState else { return }
            lastFormattingState = state
            parent.onFormattingStateChange(state)
        }

        private func currentFormattingState(
            in textView: NSTextView
        ) -> NodeNoteFormattingState {
            NodeNoteFormattingState(
                bold: fontTraitState(.boldFontMask, in: textView),
                italic: fontTraitState(.italicFontMask, in: textView),
                unorderedList: listState(ordered: false, in: textView),
                orderedList: listState(ordered: true, in: textView)
            )
        }

        private func fontTraitState(
            _ trait: NSFontTraitMask,
            in textView: NSTextView
        ) -> NodeNoteFormatSelectionState {
            let selection = clamped(
                textView.selectedRange(),
                to: textView.attributedString().length
            )
            if selection.length == 0 {
                let font = textView.typingAttributes[.font] as? NSFont
                    ?? NodeNoteRichTextCodec.baseFont
                return NodeNoteRichTextCodec.fontHasTrait(trait, font: font)
                    ? .on
                    : .off
            }

            var values = Set<Bool>()
            textView.attributedString().enumerateAttribute(
                .font,
                in: selection
            ) { value, _, stop in
                let font = value as? NSFont ?? NodeNoteRichTextCodec.baseFont
                values.insert(
                    NodeNoteRichTextCodec.fontHasTrait(trait, font: font)
                )
                if values.count > 1 {
                    stop.pointee = true
                }
            }
            return selectionState(for: values)
        }

        private func listState(
            ordered: Bool,
            in textView: NSTextView
        ) -> NodeNoteFormatSelectionState {
            guard let storage = textView.textStorage else { return .off }
            let source = textView.string as NSString
            if source.length == 0 {
                let style = textView.typingAttributes[.paragraphStyle]
                    as? NSParagraphStyle
                return style?.textLists.last?.isOrdered == ordered ? .on : .off
            }

            let selection = clamped(textView.selectedRange(), to: source.length)
            let paragraphs = paragraphRanges(in: source, selection: selection)
            var values = Set<Bool>()
            for range in paragraphs {
                let location = min(range.location, storage.length - 1)
                let style = storage.attribute(
                    .paragraphStyle,
                    at: location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
                values.insert(style?.textLists.last?.isOrdered == ordered)
                if values.count > 1 {
                    break
                }
            }
            return selectionState(for: values)
        }

        private func selectionState(
            for values: Set<Bool>
        ) -> NodeNoteFormatSelectionState {
            if values.count == 1, values.contains(true) {
                return .on
            }
            if values.count > 1 {
                return .mixed
            }
            return .off
        }

        private func proposedChangeContainsYouTube(
            in textView: NSTextView,
            range: NSRange,
            replacementString: String,
            canonicalMarkdown: String?
        ) -> Bool {
            guard let proposed = proposedAttributedString(
                in: textView,
                range: range,
                replacementString: replacementString,
                canonicalMarkdown: canonicalMarkdown
            ) else {
                return false
            }
            NodeNoteRichTextCodec.applyDetectedWebLinks(to: proposed)
            return !NodeNoteRichTextCodec.youtubeDetections(in: proposed).isEmpty
        }

        private func changeCompletesYouTubeReference(
            in textView: NSTextView,
            range: NSRange,
            replacementString: String
        ) -> Bool {
            guard replacementString.utf16.count == 1,
                  !replacementString.unicodeScalars.contains(where: {
                      CharacterSet.whitespacesAndNewlines.contains($0)
                  })
            else {
                return false
            }

            let proposed = NSMutableString(string: textView.string)
            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= proposed.length
            else {
                return false
            }
            proposed.replaceCharacters(in: range, with: replacementString)

            let insertionEnd = min(
                proposed.length,
                range.location + replacementString.utf16.count
            )
            var lower = insertionEnd
            var upper = insertionEnd
            let maximumTokenLength = 2_048
            while lower > 0,
                  insertionEnd - lower < maximumTokenLength,
                  !isYouTubeTokenBoundary(proposed.character(at: lower - 1))
            {
                lower -= 1
            }
            while upper < proposed.length,
                  upper - lower < maximumTokenLength,
                  !isYouTubeTokenBoundary(proposed.character(at: upper))
            {
                upper += 1
            }

            let token = proposed.substring(
                with: NSRange(location: lower, length: upper - lower)
            )
            guard token.range(of: "youtu", options: .caseInsensitive) != nil else {
                return false
            }
            let attributed = NodeNoteRichTextCodec.attributedString(from: token)
            return !NodeNoteRichTextCodec.youtubeDetections(in: attributed).isEmpty
        }

        private func isYouTubeTokenBoundary(_ character: unichar) -> Bool {
            guard let scalar = UnicodeScalar(character) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        private func proposedAttributedString(
            in textView: NSTextView,
            range: NSRange,
            replacementString: String,
            canonicalMarkdown: String?
        ) -> NSMutableAttributedString? {
            let proposed = NSMutableAttributedString(
                attributedString: textView.attributedString()
            )
            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= proposed.length
            else {
                return nil
            }

            let replacement: NSAttributedString
            if let canonicalMarkdown {
                replacement = NodeNoteRichTextCodec.attributedString(
                    from: canonicalMarkdown
                )
            } else if replacementString.utf16.count > 1,
                      shouldInterpretAsRichText(replacementString)
            {
                replacement = NodeNoteRichTextCodec.attributedString(
                    from: replacementString
                )
            } else {
                replacement = NSAttributedString(
                    string: replacementString,
                    attributes: textView.typingAttributes
                )
            }
            proposed.replaceCharacters(in: range, with: replacement)
            return proposed
        }

        private func beginManagedUndo(for textView: NSTextView) {
            guard pendingManagedUndoSnapshot == nil else { return }
            pendingManagedUndoSnapshot = RichTextSnapshot(
                attributedString: NSAttributedString(
                    attributedString: textView.attributedString()
                ),
                selection: textView.selectedRange(),
                actionName: "Edit Note"
            )
            textView.breakUndoCoalescing()
            textView.undoManager?.disableUndoRegistration()
            isUndoRegistrationDisabled = true
        }

        private func restorePendingManagedSnapshot(in textView: NSTextView) {
            if isUndoRegistrationDisabled {
                textView.undoManager?.enableUndoRegistration()
                isUndoRegistrationDisabled = false
            }
            guard let snapshot = pendingManagedUndoSnapshot else { return }
            pendingManagedUndoSnapshot = nil
            textView.textStorage?.setAttributedString(snapshot.attributedString)
            textView.setSelectedRange(
                clamped(snapshot.selection, to: textView.string.utf16.count)
            )
            textView.typingAttributes = typingAttributes(
                at: snapshot.selection.location,
                in: textView
            )
            (textView as? NodeNoteTextView)?.refreshAccessibleValue()
            publishContentState(from: textView)
        }

        private func combinedTransaction(
            _ transactions: [NodeNoteStoreTransaction]
        ) -> NodeNoteStoreTransaction? {
            guard !transactions.isEmpty else { return nil }
            return NodeNoteStoreTransaction(
                undo: {
                    for transaction in transactions.reversed() {
                        transaction.undo()
                    }
                },
                redo: {
                    for transaction in transactions {
                        transaction.redo()
                    }
                }
            )
        }

        private func inlineImageIDs(
            in attributedString: NSAttributedString,
            intersecting range: NSRange
        ) -> [UUID] {
            guard range.length > 0,
                  range.location >= 0,
                  NSMaxRange(range) <= attributedString.length
            else {
                return []
            }
            var result: [UUID] = []
            attributedString.enumerateAttribute(
                .nodeNoteInlineImageID,
                in: range
            ) { value, _, _ in
                guard let rawID = value as? String,
                      let id = UUID(uuidString: rawID),
                      !result.contains(id)
                else {
                    return
                }
                result.append(id)
            }
            return result
        }

        private func finishManagedUndo(
            for textView: NSTextView,
            actionName: String,
            storeTransaction: NodeNoteStoreTransaction?
        ) {
            if isUndoRegistrationDisabled {
                textView.undoManager?.enableUndoRegistration()
                isUndoRegistrationDisabled = false
            }
            guard let snapshot = pendingManagedUndoSnapshot,
                  let undoManager = textView.undoManager
            else {
                pendingManagedUndoSnapshot = nil
                return
            }
            pendingManagedUndoSnapshot = nil
            snapshot.actionName = actionName
            snapshot.storeTransaction = storeTransaction
            snapshot.transactionDirection = storeTransaction == nil ? nil : .undo
            textView.breakUndoCoalescing()
            undoManager.registerUndo(
                withTarget: self,
                selector: #selector(restoreRichTextSnapshot(_:)),
                object: snapshot
            )
            undoManager.setActionName(actionName)
        }

        private func shouldInterpretAsRichText(_ value: String) -> Bool {
            value.contains("http://")
                || value.contains("https://")
                || value.contains("**")
                || value.contains("](")
                || value.range(
                    of: #"(?:^|\n)\s*(?:[-*+] |\d+\. )"#,
                    options: .regularExpression
                ) != nil
                || value.range(
                    of: #"_[^_\n]+_"#,
                    options: .regularExpression
                ) != nil
        }

        private func normalizePendingRichInsertion(in textView: NSTextView) {
            guard let pendingRichInsertion,
                  let storage = textView.textStorage
            else {
                self.pendingRichInsertion = nil
                return
            }
            self.pendingRichInsertion = nil

            let insertedLength = pendingRichInsertion.source.utf16.count
            let insertedRange = NSRange(
                location: min(pendingRichInsertion.range.location, storage.length),
                length: min(
                    insertedLength,
                    max(0, storage.length - pendingRichInsertion.range.location)
                )
            )
            guard insertedRange.length > 0 else { return }

            let richText = NodeNoteRichTextCodec.attributedString(
                from: pendingRichInsertion.source
            )
            storage.replaceCharacters(in: insertedRange, with: richText)
            textView.setSelectedRange(NSRange(
                location: insertedRange.location + richText.length,
                length: 0
            ))
        }

        private func normalizeTypedMarkdownLinks(in textView: NSTextView) {
            guard let storage = textView.textStorage,
                  storage.length > 0,
                  let expression = try? NSRegularExpression(
                      pattern: #"\[[^\]\n]+\]\(https?://[^\s\)]+\)"#,
                      options: [.caseInsensitive]
                  )
            else {
                return
            }

            let source = storage.string as NSString
            let matches = expression.matches(
                in: source as String,
                range: NSRange(location: 0, length: source.length)
            )
            guard !matches.isEmpty else { return }

            var selection = textView.selectedRange()
            storage.beginEditing()
            for match in matches.reversed() {
                let token = source.substring(with: match.range)
                let replacement = NodeNoteRichTextCodec.attributedString(from: token)
                storage.replaceCharacters(in: match.range, with: replacement)
                if match.range.location < selection.location {
                    selection.location = max(
                        match.range.location,
                        selection.location - match.range.length + replacement.length
                    )
                }
            }
            storage.endEditing()
            textView.setSelectedRange(clamped(selection, to: storage.length))
        }

        private func toggleFontTrait(
            _ trait: NSFontTraitMask,
            in textView: NSTextView
        ) {
            let selection = clamped(textView.selectedRange(), to: textView.string.utf16.count)
            guard selection.length > 0, let storage = textView.textStorage else {
                var attributes = textView.typingAttributes
                let font = attributes[.font] as? NSFont ?? NodeNoteRichTextCodec.baseFont
                let removing = NodeNoteRichTextCodec.fontHasTrait(trait, font: font)
                attributes[.font] = NodeNoteRichTextCodec.font(
                    byToggling: trait,
                    in: font,
                    removing: removing
                )
                textView.typingAttributes = attributes
                return
            }

            var shouldRemove = true
            storage.enumerateAttribute(.font, in: selection) { value, _, stop in
                let font = value as? NSFont ?? NodeNoteRichTextCodec.baseFont
                if !NodeNoteRichTextCodec.fontHasTrait(trait, font: font) {
                    shouldRemove = false
                    stop.pointee = true
                }
            }

            var replacements: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                let font = value as? NSFont ?? NodeNoteRichTextCodec.baseFont
                replacements.append((
                    range,
                    NodeNoteRichTextCodec.font(
                        byToggling: trait,
                        in: font,
                        removing: shouldRemove
                    )
                ))
            }
            storage.beginEditing()
            for (range, font) in replacements {
                storage.addAttribute(.font, value: font, range: range)
            }
            storage.endEditing()
            textView.setSelectedRange(selection)
            textView.typingAttributes = typingAttributes(
                at: NSMaxRange(selection),
                in: textView
            )
        }

        private func toggleList(ordered: Bool, in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string as NSString
            let selection = clamped(textView.selectedRange(), to: source.length)

            if source.length == 0 {
                let list = makeTextList(ordered: ordered)
                var attributes = textView.typingAttributes
                attributes[.paragraphStyle] = NodeNoteRichTextCodec.paragraphStyle(
                    textList: list,
                    basedOn: attributes[.paragraphStyle] as? NSParagraphStyle
                )
                textView.typingAttributes = attributes
                return
            }

            let paragraphs = paragraphRanges(
                in: source,
                selection: selection
            )
            let alreadyDesired = paragraphs.allSatisfy { range in
                guard let style = storage.attribute(
                    .paragraphStyle,
                    at: min(range.location, max(0, storage.length - 1)),
                    effectiveRange: nil
                ) as? NSParagraphStyle,
                    let list = style.textLists.last
                else {
                    return false
                }
                return list.isOrdered == ordered
            }
            let newList = alreadyDesired ? nil : makeTextList(ordered: ordered)

            storage.beginEditing()
            for range in paragraphs where range.length > 0 {
                let location = min(range.location, max(0, storage.length - 1))
                let existing = storage.attribute(
                    .paragraphStyle,
                    at: location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
                let style = NodeNoteRichTextCodec.paragraphStyle(
                    textList: newList,
                    basedOn: existing
                )
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
            storage.endEditing()
            textView.setSelectedRange(selection)
            textView.typingAttributes = typingAttributes(
                at: selection.location,
                in: textView
            )
        }

        private func makeTextList(ordered: Bool) -> NSTextList {
            NSTextList(
                markerFormat: ordered ? .decimal : .disc,
                options: [],
                startingItemNumber: 1
            )
        }

        private func youtubeExtraction(
            _ detections: [NodeNoteRichTextCodec.YouTubeDetection],
            from attributedString: NSAttributedString,
            selection: NSRange
        ) -> YouTubeExtraction {
            _ = detections
            let storage = NSAttributedString(
                attributedString: attributedString
            )
            return YouTubeExtraction(
                attributedString: storage,
                selection: clamped(selection, to: storage.length)
            )
        }

        private func apply(
            _ extraction: YouTubeExtraction,
            to textView: NSTextView
        ) {
            textView.textStorage?.setAttributedString(extraction.attributedString)
            textView.setSelectedRange(extraction.selection)
            textView.typingAttributes = typingAttributes(
                at: extraction.selection.location,
                in: textView
            )
        }

        private func youtubeURLDeletionRange(
            for rawRange: NSRange,
            in source: NSString
        ) -> NSRange {
            let tokenRange = trimmingHorizontalWhitespace(
                from: rawRange,
                in: source
            )
            let lineRange = source.lineRange(
                for: NSRange(location: tokenRange.location, length: 0)
            )
            let contentRange = rangeRemovingLineEnding(lineRange, in: source)
            if trimmingHorizontalWhitespace(from: contentRange, in: source)
                == tokenRange
            {
                return lineRange
            }

            var lower = tokenRange.location
            var upper = NSMaxRange(tokenRange)
            let contentEnd = NSMaxRange(contentRange)
            if upper < contentEnd, isHorizontalWhitespace(source.character(at: upper)) {
                while upper < contentEnd,
                      isHorizontalWhitespace(source.character(at: upper))
                {
                    upper += 1
                }
            } else if lower > contentRange.location,
                      isHorizontalWhitespace(source.character(at: lower - 1))
            {
                while lower > contentRange.location,
                      isHorizontalWhitespace(source.character(at: lower - 1))
                {
                    lower -= 1
                }
            }
            return NSRange(location: lower, length: upper - lower)
        }

        private func adjustedOffset(
            _ offset: Int,
            afterRemoving ranges: [NSRange]
        ) -> Int {
            var removed = 0
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                guard offset > range.location else { break }
                removed += min(offset, NSMaxRange(range)) - range.location
                if offset < NSMaxRange(range) {
                    break
                }
            }
            return max(0, offset - removed)
        }

        private func rangeRemovingLineEnding(
            _ range: NSRange,
            in source: NSString
        ) -> NSRange {
            var length = range.length
            while length > 0 {
                let character = source.character(at: range.location + length - 1)
                guard character == 10 || character == 13 else { break }
                length -= 1
            }
            return NSRange(location: range.location, length: length)
        }

        private func trimmingHorizontalWhitespace(
            from range: NSRange,
            in source: NSString
        ) -> NSRange {
            var lower = range.location
            var upper = NSMaxRange(range)
            while lower < upper, isHorizontalWhitespace(source.character(at: lower)) {
                lower += 1
            }
            while upper > lower, isHorizontalWhitespace(source.character(at: upper - 1)) {
                upper -= 1
            }
            return NSRange(location: lower, length: upper - lower)
        }

        private func isHorizontalWhitespace(_ character: unichar) -> Bool {
            character == 9 || character == 32
        }

        private func scheduleMarkdownPublish(from textView: NSTextView) {
            pendingPublish?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.publishCurrentMarkdown(from: textView)
            }
            pendingPublish = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NodeNoteTextEditor.publishDelay,
                execute: work
            )
        }

        func flushPendingChanges() {
            pendingPublish?.cancel()
            pendingPublish = nil
            guard let textView else { return }
            publishCurrentMarkdown(from: textView)
        }

        func handlePastedImage(
            _ data: Data,
            suggestedAltText: String
        ) -> Bool {
            flushPendingChanges()
            guard let textView else { return false }

            let before = RichTextSnapshot(
                attributedString: NSAttributedString(
                    attributedString: textView.attributedString()
                ),
                selection: textView.selectedRange(),
                actionName: "Embed Image"
            )
            guard let insertion = parent.onImagePasted(
                data,
                suggestedAltText
            ) else {
                return false
            }

            isSynchronizing = true
            let inserted = NodeNoteInlineImageLayout.insert(
                insertion.attachment,
                at: textView.selectedRange(),
                in: textView,
                maximumWidth: availableImageWidth(in: textView)
            )
            isSynchronizing = false
            guard inserted else {
                parent.onValidationFailure(
                    "The image could not be inserted at the current position."
                )
                NSSound.beep()
                return false
            }
            guard let transaction = insertion.commit() else {
                isSynchronizing = true
                textView.textStorage?.setAttributedString(
                    before.attributedString
                )
                textView.setSelectedRange(
                    clamped(before.selection, to: textView.string.utf16.count)
                )
                textView.typingAttributes = typingAttributes(
                    at: before.selection.location,
                    in: textView
                )
                textView.refreshAccessibleValue()
                publishContentState(from: textView)
                isSynchronizing = false
                publishFormattingState(from: textView)
                return false
            }

            pendingManagedUndoSnapshot = before
            finishManagedUndo(
                for: textView,
                actionName: "Embed Image",
                storeTransaction: transaction
            )
            textView.refreshAccessibleValue()
            publishContentState(from: textView)
            scheduleMarkdownPublish(from: textView)
            publishFormattingState(from: textView)
            return true
        }

        private func publishCurrentMarkdown(from textView: NSTextView) {
            pendingPublish = nil
            let markdown = NodeNoteRichTextCodec.markdown(
                from: textView.attributedString()
            )
            guard markdown.count <= NodeNoteValidator.maxBodyCharacters else {
                reportBodyLimitRejection(in: textView)
                return
            }
            representedMarkdown = markdown
            estimatedCanonicalCount = markdown.count
            canonicalMarkupOverhead = max(
                0,
                markdown.count - textView.string.count
            )
            if parent.text != markdown {
                parent.text = markdown
            }
        }

        func publishContentState(from textView: NSTextView) {
            parent.onContentStateChange(
                NodeNoteInlineImageLayout.isSemanticallyEmpty(
                    textView.attributedString()
                )
            )
        }

        private func paragraphRanges(
            in source: NSString,
            selection: NSRange
        ) -> [NSRange] {
            let paragraphRange = source.paragraphRange(for: selection)
            var ranges: [NSRange] = []
            var location = paragraphRange.location
            while location < NSMaxRange(paragraphRange) {
                let range = source.paragraphRange(
                    for: NSRange(location: location, length: 0)
                )
                ranges.append(range)
                let next = NSMaxRange(range)
                guard next > location else { break }
                location = next
            }
            return ranges
        }

        private func typingAttributes(
            at proposedLocation: Int,
            in textView: NSTextView
        ) -> [NSAttributedString.Key: Any] {
            let attributed = textView.attributedString()
            guard attributed.length > 0 else {
                return NodeNoteRichTextCodec.baseAttributes
            }
            let location = min(max(0, proposedLocation - 1), attributed.length - 1)
            var attributes = attributed.attributes(at: location, effectiveRange: nil)
            attributes.removeValue(forKey: .link)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .nodeNoteInlineImageID)
            return attributes
        }

        private func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            return NSRange(
                location: location,
                length: min(max(0, range.length), length - location)
            )
        }
    }
}

extension NSAttributedString.Key {
    static let nodeNoteInlineImageID = NSAttributedString.Key(
        "Brainstorm.NodeNote.InlineImageID"
    )
}

@MainActor
final class NodeNoteInlineImageAttachment: NSTextAttachment {
    let noteImageID: UUID

    private(set) var altText: String
    private var sourceImage: NSImage
    private var sourceSize: CGSize
    private var payloadFingerprint: Int
    private var currentMaximumWidth: CGFloat = 0

    init?(
        noteImage: NoteImageAttachment,
        maximumWidth: CGFloat
    ) {
        guard let data = noteImage.pngData,
              let sourceImage = NSImage(data: data)
        else {
            return nil
        }
        self.noteImageID = noteImage.id
        self.altText = noteImage.altText
        self.sourceImage = sourceImage
        self.sourceSize = CGSize(
            width: max(1, noteImage.pixelWidth),
            height: max(1, noteImage.pixelHeight)
        )
        self.payloadFingerprint = noteImage.pngBase64.hashValue
        super.init(data: nil, ofType: nil)
        _ = resize(maximumWidth: maximumWidth)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func update(
        from noteImage: NoteImageAttachment,
        maximumWidth: CGFloat
    ) -> Bool {
        let fingerprint = noteImage.pngBase64.hashValue
        var changed = false
        if fingerprint != payloadFingerprint,
           let data = noteImage.pngData,
           let decoded = NSImage(data: data)
        {
            sourceImage = decoded
            sourceSize = CGSize(
                width: max(1, noteImage.pixelWidth),
                height: max(1, noteImage.pixelHeight)
            )
            payloadFingerprint = fingerprint
            changed = true
        }
        if altText != noteImage.altText {
            altText = noteImage.altText
            changed = true
        }
        return resize(
            maximumWidth: maximumWidth,
            force: changed
        ) || changed
    }

    @discardableResult
    func resize(
        maximumWidth: CGFloat,
        force: Bool = false
    ) -> Bool {
        let constrainedWidth = max(
            44,
            min(
                NodeNoteEmbeddedImageSizing.maximumSize.width,
                maximumWidth
            )
        )
        guard force || abs(currentMaximumWidth - constrainedWidth) > 0.5 else {
            return false
        }
        currentMaximumWidth = constrainedWidth

        let scale = min(
            1,
            min(
                constrainedWidth / sourceSize.width,
                NodeNoteEmbeddedImageSizing.maximumSize.height
                    / sourceSize.height
            )
        )
        let displaySize = CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
        let rendered = roundedDisplayImage(size: displaySize)
        rendered.accessibilityDescription = altText
        image = rendered
        bounds = NSRect(origin: .zero, size: displaySize)
        return true
    }

    private func roundedDisplayImage(size: CGSize) -> NSImage {
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        defer { rendered.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(
            roundedRect: rect,
            xRadius: min(12, size.width / 5),
            yRadius: min(12, size.height / 5)
        ).addClip()
        sourceImage.draw(
            in: rect,
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        return rendered
    }
}

@MainActor
enum NodeNoteInlineImageLayout {
    struct Entry {
        let range: NSRange
        let attachment: NodeNoteInlineImageAttachment
    }

    static func editingDocument(
        bodyMarkdown: String,
        images: [NoteImageAttachment],
        maximumWidth: CGFloat
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            attributedString: NodeNoteRichTextCodec.attributedString(
                from: bodyMarkdown
            )
        )
        for image in images {
            _ = append(
                image,
                to: output,
                maximumWidth: maximumWidth
            )
        }
        return output
    }

    @discardableResult
    static func append(
        _ image: NoteImageAttachment,
        to storage: NSMutableAttributedString,
        maximumWidth: CGFloat
    ) -> Bool {
        guard let attachment = NodeNoteInlineImageAttachment(
            noteImage: image,
            maximumWidth: maximumWidth
        ) else {
            return false
        }
        let source = storage.string as NSString
        if source.length > 0,
           source.character(at: source.length - 1) != 0x0A
        {
            storage.append(
                NSAttributedString(
                    string: "\n",
                    attributes: NodeNoteRichTextCodec.baseAttributes
                )
            )
        }
        storage.append(attributedString(for: attachment))
        storage.append(
            NSAttributedString(
                string: "\n",
                attributes: NodeNoteRichTextCodec.baseAttributes
            )
        )
        return true
    }

    @discardableResult
    static func insert(
        _ image: NoteImageAttachment,
        at proposedRange: NSRange,
        in textView: NSTextView,
        maximumWidth: CGFloat
    ) -> Bool {
        guard let storage = textView.textStorage,
              proposedRange.location != NSNotFound,
              proposedRange.location >= 0,
              proposedRange.length >= 0,
              NSMaxRange(proposedRange) <= storage.length,
              let attachment = NodeNoteInlineImageAttachment(
                  noteImage: image,
                  maximumWidth: maximumWidth
              )
        else {
            return false
        }

        let source = storage.string as NSString
        let needsLeadingBreak = proposedRange.location > 0
            && source.character(at: proposedRange.location - 1) != 0x0A
        let characterAfterSelection = NSMaxRange(proposedRange)
        let hasFollowingBreak = characterAfterSelection < source.length
            && source.character(at: characterAfterSelection) == 0x0A

        let block = NSMutableAttributedString(string: "")
        if needsLeadingBreak {
            block.append(
                NSAttributedString(
                    string: "\n",
                    attributes: NodeNoteRichTextCodec.baseAttributes
                )
            )
        }
        block.append(attributedString(for: attachment))
        if !hasFollowingBreak {
            block.append(
                NSAttributedString(
                    string: "\n",
                    attributes: NodeNoteRichTextCodec.baseAttributes
                )
            )
        }

        storage.replaceCharacters(in: proposedRange, with: block)
        var caret = proposedRange.location + block.length
        if hasFollowingBreak {
            caret += 1
        }
        caret = min(caret, storage.length)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        let revealLocation = max(proposedRange.location, caret - 1)
        let revealRange = NSRange(
            location: min(revealLocation, storage.length),
            length: min(1, max(0, storage.length - revealLocation))
        )
        textView.scrollRangeToVisible(revealRange)
        DispatchQueue.main.async { [weak textView] in
            textView?.scrollRangeToVisible(revealRange)
        }
        return true
    }

    static func attachments(
        in attributedString: NSAttributedString
    ) -> [Entry] {
        guard attributedString.length > 0 else { return [] }
        var result: [Entry] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let attachment = value
                as? NodeNoteInlineImageAttachment
            else {
                return
            }
            result.append(
                Entry(range: range, attachment: attachment)
            )
        }
        return result
    }

    static func isSemanticallyEmpty(
        _ attributedString: NSAttributedString
    ) -> Bool {
        if !attachments(in: attributedString).isEmpty {
            return false
        }
        return attributedString.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func accessibleText(
        from attributedString: NSAttributedString
    ) -> String {
        let value = NSMutableString(string: attributedString.string)
        for entry in attachments(in: attributedString).reversed() {
            value.replaceCharacters(
                in: entry.range,
                with: "\nImage: \(entry.attachment.altText)\n"
            )
        }
        return (value as String)
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributedString(
        for attachment: NodeNoteInlineImageAttachment
    ) -> NSAttributedString {
        let value = NSMutableAttributedString(
            attachment: attachment
        )
        value.addAttributes(
            [
                .nodeNoteInlineImageID:
                    attachment.noteImageID.uuidString,
                .paragraphStyle:
                    NodeNoteRichTextCodec.paragraphStyle(),
            ],
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }
}

/// Marker subclass used by the document-level key monitor to identify note
/// editing and leave native text-editing shortcuts with AppKit.
final class NodeNoteTextView: NSTextView {
    static let canonicalMarkdownPasteboardType = NSPasteboard.PasteboardType(
        "ninja.selfhosted.brainstorm.note-markdown"
    )

    private let noteUndoManager = UndoManager()
    var notePasteboard = NSPasteboard.general
    var onFormattingCommand: ((NodeNoteTextCommand) -> Void)?
    var onPasteImage: ((_ data: Data, _ suggestedAltText: String) -> Bool)?
    var onFlushPendingChanges: (() -> Void)?
    var onViewportWidthChange: ((CGFloat) -> Void)?
    private(set) var canonicalMarkdownBeingInserted: String?

    override var undoManager: UndoManager? {
        noteUndoManager
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            onViewportWidthChange?(newSize.width)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        let command: NodeNoteTextCommand?
        switch (key, modifiers.contains(.shift)) {
        case ("b", false):
            command = .bold
        case ("i", false):
            command = .italic
        case ("8", true), ("*", true):
            command = .unorderedList
        case ("7", true), ("&", true):
            command = .orderedList
        default:
            command = nil
        }

        guard let command, let onFormattingCommand else {
            return super.performKeyEquivalent(with: event)
        }
        onFormattingCommand(command)
        return true
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else {
            NSSound.beep()
            return
        }
        let selected = attributedString().attributedSubstring(from: selection)
        let canonical = NodeNoteRichTextCodec.markdown(from: selected)
        notePasteboard.declareTypes(
            [Self.canonicalMarkdownPasteboardType, .string],
            owner: nil
        )
        notePasteboard.setString(
            canonical,
            forType: Self.canonicalMarkdownPasteboardType
        )
        notePasteboard.setString(selected.string, forType: .string)
    }

    override func cut(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else {
            NSSound.beep()
            return
        }
        copy(sender)
        insertText("", replacementRange: selection)
    }

    override func paste(_ sender: Any?) {
        if importImage(from: notePasteboard) {
            return
        }
        if let canonical = notePasteboard.string(
            forType: Self.canonicalMarkdownPasteboardType
        ) {
            canonicalMarkdownBeingInserted = canonical
            defer { canonicalMarkdownBeingInserted = nil }
            insertText(
                NodeNoteRichTextCodec.attributedString(from: canonical),
                replacementRange: selectedRange()
            )
            return
        }
        guard let plainText = notePasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        insertText(plainText, replacementRange: selectedRange())
    }

    override func readSelection(
        from pboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        if importImage(from: pboard) {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canImportImage(from: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let localPoint = convert(sender.draggingLocation, from: nil)
        let insertionLocation = characterIndexForInsertion(at: localPoint)
        if insertionLocation != NSNotFound {
            setSelectedRange(
                NSRange(
                    location: min(insertionLocation, string.utf16.count),
                    length: 0
                )
            )
        }
        if importImage(from: sender.draggingPasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Publish TextKit's current attributed string immediately, bypassing the
    /// normal short idle debounce. Document actions call this directly instead
    /// of depending on an AppKit focus transition.
    func flushPendingNoteChanges() {
        onFlushPendingChanges?()
    }

    /// AppKit normally derives an editable text view's accessibility value
    /// from its backing storage. Post the value-change notification explicitly
    /// because SwiftUI's representable binding contains canonical Markdown
    /// while the user-facing TextKit storage intentionally contains only
    /// rendered text. Calling `setAccessibilityValue` here would invoke
    /// NSTextView's editable value setter and replace the attributed storage,
    /// discarding rich-text formatting and links.
    func refreshAccessibleValue() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    @objc func accessibilityValue() -> Any? {
        NodeNoteInlineImageLayout.accessibleText(
            from: attributedString()
        )
    }

    /// Shared paste/drop image importer. URL payloads are deliberately probed
    /// only when they are local files; browser URLs remain ordinary note text
    /// and can continue through link/YouTube extraction.
    @discardableResult
    func importImage(from pasteboard: NSPasteboard) -> Bool {
        guard let onPasteImage else { return false }

        // Process each logical item once. Finder commonly adds a TIFF preview
        // to the same item as its file URL, while mixed drags may include
        // separate bitmap-only items. Prefer a valid image file for that item,
        // otherwise use its bitmap representation.
        var foundItemImage = false
        var importedItemImage = false
        for item in pasteboard.pasteboardItems ?? [] {
            if let rawURL = item.string(forType: .fileURL),
               let url = URL(string: rawURL),
               url.isFileURL,
               let data = try? Data(contentsOf: url),
               NSImage(data: data) != nil
            {
                foundItemImage = true
                let name = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                importedItemImage = onPasteImage(data, name)
                    || importedItemImage
                continue
            }
            if let bitmapType = item.availableType(from: [.png, .tiff]),
               let data = item.data(forType: bitmapType),
               NSImage(data: data) != nil
            {
                foundItemImage = true
                importedItemImage = onPasteImage(data, "Pasted image")
                    || importedItemImage
            }
        }
        if foundItemImage {
            return importedItemImage
        }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL] ?? []
        let localURLs = urls.filter(\.isFileURL)

        // Finder may publish several file URLs plus one synthesized TIFF
        // preview. Import every file and ignore that singleton preview.
        if !localURLs.isEmpty {
            var importedImage = false
            for url in localURLs {
                guard let data = try? Data(contentsOf: url),
                      NSImage(data: data) != nil
                else {
                    continue
                }
                let name = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                importedImage = onPasteImage(data, name) || importedImage
            }
            return importedImage
        }

        if let bitmapType = pasteboard.availableType(from: [.png, .tiff]),
           let data = pasteboard.data(forType: bitmapType),
           NSImage(data: data) != nil
        {
            return onPasteImage(data, "Pasted image")
        }

        // A remote NSURL must never fall through to NSImage(pasteboard:),
        // which may synchronously resolve URL-backed image representations.
        if !urls.isEmpty {
            return false
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let data = image.tiffRepresentation
        else {
            return false
        }
        return onPasteImage(data, "Pasted image")
    }

    private func canImportImage(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            return true
        }
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL] else {
            return false
        }
        return urls.contains { url in
            guard url.isFileURL else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }
}
