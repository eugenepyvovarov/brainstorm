import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BrainstormFeature

@Suite("Node note editor regressions", .serialized)
@MainActor
struct NodeNoteEditorRegressionTests {
    @Test func deletingInlineImagePersistsAndParticipatesInLocalUndo() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let attachment = try NodeNoteImageNormalizer.normalize(
            data,
            altText: "Diagram"
        )

        var bodyDraft = "Before"
        var modelImages = [attachment]
        let editor = NodeNoteTextEditor(
            text: Binding(
                get: { bodyDraft },
                set: { bodyDraft = $0 }
            ),
            imageAttachments: modelImages,
            commandRequest: nil,
            onImageAttachmentsRemoved: { ids, _ in
                #expect(ids == [attachment.id])
                modelImages.removeAll { ids.contains($0.id) }
                return NodeNoteStoreTransaction(
                    undo: {
                        modelImages = [attachment]
                    },
                    redo: {
                        modelImages = []
                    }
                )
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.textStorage?.setAttributedString(
            NodeNoteInlineImageLayout.editingDocument(
                bodyMarkdown: bodyDraft,
                images: modelImages,
                maximumWidth: 320
            )
        )
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        let imageRange = try #require(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).first?.range
        )
        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: imageRange,
                replacementString: ""
            )
        )
        textView.textStorage?.deleteCharacters(in: imageRange)
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(modelImages.isEmpty)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).isEmpty
        )
        coordinator.reconcileInlineImages(modelImages, in: textView)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).isEmpty
        )

        textView.undoManager?.undo()
        #expect(modelImages.map(\.id) == [attachment.id])
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).map(\.attachment.noteImageID) == [attachment.id]
        )

        textView.undoManager?.redo()
        #expect(modelImages.isEmpty)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).isEmpty
        )
    }

    @Test func bareURLKeepsBalancedClosingParenthesisAndTrimsSentencePunctuation() {
        let balanced = "https://en.wikipedia.org/wiki/Function_(mathematics)"
        let source = "Read \(balanced), then continue."
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )

        #expect(NodeNoteRichTextCodec.applyDetectedWebLinks(to: attributed))

        let linkRange = (source as NSString).range(of: balanced)
        let destination = attributed.attribute(
            .link,
            at: linkRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(destination?.absoluteString == balanced)
        #expect(
            attributed.attribute(
                .link,
                at: NSMaxRange(linkRange),
                effectiveRange: nil
            ) == nil
        )
    }

    @Test func bareURLTrimsOnlyUnmatchedClosingDelimiters() {
        let balanced = "https://example.com/a_(b)"
        let source = "(\(balanced)))."
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )

        #expect(NodeNoteRichTextCodec.applyDetectedWebLinks(to: attributed))

        let linkRange = (source as NSString).range(of: balanced)
        let destination = attributed.attribute(
            .link,
            at: linkRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(destination?.absoluteString == balanced)
        for offset in 0..<2 {
            #expect(
                attributed.attribute(
                    .link,
                    at: NSMaxRange(linkRange) + offset,
                    effectiveRange: nil
                ) == nil
            )
        }
    }

    @Test func finderPasteboardImportsEveryFileInsteadOfOnePreviewBitmap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BrainstormFinderImages-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstData = try imageData(color: .systemBlue)
        let secondData = try imageData(color: .systemOrange)
        let firstURL = directory.appendingPathComponent("First-image.tiff")
        let secondURL = directory.appendingPathComponent("Second-image.tiff")
        try firstData.write(to: firstURL)
        try secondData.write(to: secondURL)

        let firstItem = NSPasteboardItem()
        firstItem.setString(firstURL.absoluteString, forType: .fileURL)
        firstItem.setData(firstData, forType: .tiff)
        let secondItem = NSPasteboardItem()
        secondItem.setString(secondURL.absoluteString, forType: .fileURL)
        secondItem.setData(secondData, forType: .tiff)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-finder-images-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([firstItem, secondItem]))

        var imported: [Data] = []
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, _ in
            imported.append(data)
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(imported == [firstData, secondData])
    }

    @Test func bitmapPasteboardImportsEveryImageItem() throws {
        let firstData = try imageData(color: .systemPurple)
        let secondData = try imageData(color: .systemGreen)
        let firstItem = NSPasteboardItem()
        firstItem.setData(firstData, forType: .tiff)
        let secondItem = NSPasteboardItem()
        secondItem.setData(secondData, forType: .tiff)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-bitmap-images-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([firstItem, secondItem]))

        var imported: [Data] = []
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, _ in
            imported.append(data)
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(imported == [firstData, secondData])
    }

    @Test func mixedPasteboardImportsFileAndBitmapItemsOnceEach() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BrainstormMixedImages-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileData = try imageData(color: .systemPink)
        let bitmapData = try imageData(color: .systemIndigo)
        let fileURL = directory.appendingPathComponent("File-image.tiff")
        try fileData.write(to: fileURL)

        let fileItem = NSPasteboardItem()
        fileItem.setString(fileURL.absoluteString, forType: .fileURL)
        fileItem.setData(fileData, forType: .tiff)
        let bitmapItem = NSPasteboardItem()
        bitmapItem.setData(bitmapData, forType: .tiff)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-mixed-images-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([fileItem, bitmapItem]))

        var imported: [Data] = []
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, _ in
            imported.append(data)
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(imported == [fileData, bitmapData])
    }

    @Test func rejectedPreparedImageDoesNotStartHiddenEditSession() throws {
        let source = try NodeNoteImageNormalizer.normalize(
            imageData(color: .systemCyan),
            altText: "Existing image"
        )
        let fullAttachments = (0..<NodeNoteValidator.maxAttachmentsPerNote)
            .map { index in
                NodeNoteAttachment.image(
                    NoteImageAttachment(
                        id: UUID(),
                        pngBase64: source.pngBase64,
                        pixelWidth: source.pixelWidth,
                        pixelHeight: source.pixelHeight,
                        altText: "Existing image \(index + 1)"
                    )
                )
            }
        let child = BrainstormNode(
            title: "Full note",
            note: NodeNote(attachments: fullAttachments)
        )
        let root = BrainstormNode(title: "Root", children: [child])
        let store = BrainstormStore(root: root, startEditing: false)
        let prepared = try store.prepareNoteImageForEditor(
            imageData(color: .systemYellow),
            altText: "Rejected image",
            for: child.id
        )

        #expect(throws: NodeNoteValidationError.self) {
            try store.commitPreparedNoteImageForEditor(
                prepared,
                for: child.id
            )
        }
        #expect(store.noteEditingID == nil)
        #expect(store.selectedID == root.id)
        #expect(
            store.note(for: child.id)?.attachments.count
                == NodeNoteValidator.maxAttachmentsPerNote
        )
    }

    @Test func storeBackedEditorAcceptsTwoImagePastesAndContinuesTyping() throws {
        let root = BrainstormNode(title: "Image note")
        let store = BrainstormStore(root: root, startEditing: false)
        store.beginNoteEditing(id: root.id)
        var bodyDraft = ""

        func currentImages() -> [NoteImageAttachment] {
            store.note(for: root.id)?.imageAttachments ?? []
        }

        func makeEditor() -> NodeNoteTextEditor {
            NodeNoteTextEditor(
                text: Binding(
                    get: { bodyDraft },
                    set: { newValue in
                        if (try? store.updateNoteEditingDraft(newValue)) != nil {
                            bodyDraft = newValue
                        }
                    }
                ),
                imageAttachments: currentImages(),
                commandRequest: nil,
                onImagePasted: { data, altText in
                    guard let image = try? store.prepareNoteImageForEditor(
                        data,
                        altText: altText,
                        for: root.id
                    )
                    else {
                        return nil
                    }
                    let before = store.note(for: root.id)
                    return NodeNoteImageInsertion(
                        attachment: image,
                        commit: {
                            guard (
                                try? store.commitPreparedNoteImageForEditor(
                                    image,
                                    for: root.id
                                )
                            ) == true,
                            let after = store.note(for: root.id)
                            else {
                                return nil
                            }
                            return NodeNoteStoreTransaction(
                                undo: {
                                    _ = try? store.restoreNoteEditorTransaction(
                                        nodeID: root.id,
                                        note: before
                                    )
                                },
                                redo: {
                                    _ = try? store.restoreNoteEditorTransaction(
                                        nodeID: root.id,
                                        note: after
                                    )
                                }
                            )
                        }
                    )
                }
            )
        }

        let coordinator = makeEditor().makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.delegate = coordinator
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView
        textView.onPasteImage = { data, altText in
            coordinator.handlePastedImage(
                data,
                suggestedAltText: altText
            )
        }
        textView.onFlushPendingChanges = {
            coordinator.flushPendingChanges()
        }
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false

        let firstPasteboard = try imagePasteboard(
            data: imageData(color: .systemBlue)
        )
        defer { firstPasteboard.clearContents() }
        textView.notePasteboard = firstPasteboard
        undoManager.beginUndoGrouping()
        textView.paste(nil)
        undoManager.endUndoGrouping()

        #expect(store.note(for: root.id)?.imageAttachments.count == 1)
        coordinator.parent = makeEditor()
        coordinator.reconcileInlineImages(currentImages(), in: textView)

        let secondPasteboard = try imagePasteboard(
            data: imageData(color: .systemOrange),
            remoteURL: "https://example.com/second-image.png"
        )
        defer { secondPasteboard.clearContents() }
        textView.notePasteboard = secondPasteboard
        undoManager.beginUndoGrouping()
        textView.paste(nil)
        undoManager.endUndoGrouping()
        coordinator.parent = makeEditor()
        coordinator.reconcileInlineImages(currentImages(), in: textView)

        let storedImages = try #require(store.note(for: root.id)?.imageAttachments)
        #expect(storedImages.count == 2)
        #expect(Set(storedImages.map(\.id)).count == 2)

        let inlineIDs = NodeNoteInlineImageLayout.attachments(
            in: textView.attributedString()
        ).map(\.attachment.noteImageID)
        #expect(inlineIDs.count == 2)
        #expect(Set(inlineIDs) == Set(storedImages.map(\.id)))

        textView.undoManager?.undo()
        #expect(store.note(for: root.id)?.imageAttachments.count == 1)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).count == 1
        )
        textView.undoManager?.undo()
        #expect((store.note(for: root.id)?.imageAttachments.count ?? 0) == 0)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).isEmpty
        )
        textView.undoManager?.redo()
        #expect(store.note(for: root.id)?.imageAttachments.count == 1)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).count == 1
        )
        textView.undoManager?.redo()
        #expect(store.note(for: root.id)?.imageAttachments.count == 2)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).count == 2
        )

        undoManager.groupsByEvent = true
        let end = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText(
            "Text after two images",
            replacementRange: textView.selectedRange()
        )
        textView.flushPendingNoteChanges()

        #expect(
            store.note(for: root.id)?.bodyMarkdown.contains(
                "Text after two images"
            ) == true
        )
    }

    private func imageData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return try #require(image.tiffRepresentation)
    }

    private func imagePasteboard(
        data: Data,
        remoteURL: String? = nil
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-sequential-image-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        if let remoteURL {
            pasteboard.declareTypes([.URL, .tiff, .string], owner: nil)
            #expect(pasteboard.setString(remoteURL, forType: .URL))
            #expect(pasteboard.setString(remoteURL, forType: .string))
        } else {
            pasteboard.declareTypes([.tiff], owner: nil)
        }
        #expect(pasteboard.setData(data, forType: .tiff))
        return pasteboard
    }
}

private extension NodeNote {
    var imageAttachments: [NoteImageAttachment] {
        attachments.compactMap { attachment in
            guard case .image(let image) = attachment else { return nil }
            return image
        }
    }
}
