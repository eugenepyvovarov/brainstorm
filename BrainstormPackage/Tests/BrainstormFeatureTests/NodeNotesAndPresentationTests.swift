import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import BrainstormFeature

@Suite("Node notes and presentation exports", .serialized)
@MainActor
struct NodeNotesAndPresentationTests {
    private let firstVideoID = "dQw4w9WgXcQ"
    private let secondVideoID = "M7lc1UVf-VE"

    @Test func v3CodecIsSparseAndLegacyFilesUpgradeWhenWritten() throws {
        let note = NodeNote(bodyMarkdown: "A **small** note")
        let file = BrainstormFile(
            root: BrainstormNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                title: "Sparse",
                note: note
            )
        )

        let encoded = try BrainstormCodec.encode(file)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\"version\" : 3"))
        #expect(text.contains("\"bodyMarkdown\" : \"A **small** note\""))
        #expect(!text.contains("\"visibility\""))
        #expect(!text.contains("\"attachments\""))
        #expect(!text.contains("\"style\""))
        #expect(!text.contains("\"media\""))
        #expect(!text.contains("\"children\""))
        #expect(try BrainstormCodec.decode(from: encoded) == file)

        for legacyVersion in [1, 2] {
            let legacy = """
            {
              "version": \(legacyVersion),
              "root": {
                "id": "00000000-0000-0000-0000-00000000030\(legacyVersion)",
                "title": "Legacy \(legacyVersion)"
              }
            }
            """
            let decoded = try BrainstormCodec.decode(from: Data(legacy.utf8))
            #expect(decoded.version == legacyVersion)
            #expect(decoded.root.note == nil)
            #expect(decoded.root.isExpanded)
            #expect(decoded.root.style.isDefault)

            let upgraded = try BrainstormCodec.encode(decoded)
            let object = try #require(
                JSONSerialization.jsonObject(with: upgraded) as? [String: Any]
            )
            #expect(object["version"] as? Int == BrainstormFile.currentVersion)
            #expect(try BrainstormCodec.decode(from: upgraded).version == 3)
        }
    }

    @Test func codecRejectsFutureVersions() {
        let future = """
        {
          "version": \(BrainstormFile.currentVersion + 1),
          "root": {
            "id": "00000000-0000-0000-0000-000000000399",
            "title": "From the future"
          }
        }
        """

        do {
            _ = try BrainstormCodec.decode(from: Data(future.utf8))
            Issue.record("Expected a future document version to be rejected.")
        } catch BrainstormCodecError.unsupportedVersion(let version) {
            #expect(version == BrainstormFile.currentVersion + 1)
        } catch {
            Issue.record("Expected unsupportedVersion, got \(error).")
        }
    }

    @Test func hostileImageDimensionsReturnAValidationErrorWithoutOverflowing() {
        let attachment = NodeNoteAttachment.image(
            NoteImageAttachment(
                pngBase64: "",
                pixelWidth: .max,
                pixelHeight: .max,
                altText: "Overflow probe"
            )
        )

        do {
            try NodeNoteValidator.validate(attachment: attachment)
            Issue.record("Expected hostile image dimensions to be rejected.")
        } catch let issue as NodeNoteValidationError {
            #expect(issue.code == .imageDimensions)
            #expect(issue.path == "$.attachment")
        } catch {
            Issue.record("Expected NodeNoteValidationError, got \(error).")
        }
    }

    @Test func safeMarkdownRecognizesOnlyTheSupportedFormattingSubset() throws {
        let source = """
        Intro **bold** and _italic_ <script>alert("x")</script>
        second line

        - First
        * **Second**

        3. Third
        4. _Fourth_
        """
        let document = try SafeMarkdownParser.parse(source)
        #expect(document.blocks.count == 3)

        guard case .paragraph(let paragraph) = document.blocks[0] else {
            Issue.record("Expected a paragraph block.")
            return
        }
        #expect(paragraph.contains(.bold([.text("bold")])))
        #expect(paragraph.contains(.italic([.text("italic")])))
        #expect(paragraph.contains(.text(#" <script>alert("x")</script>"#)))
        #expect(paragraph.contains(.lineBreak))

        guard case .unorderedList(let unordered) = document.blocks[1] else {
            Issue.record("Expected an unordered-list block.")
            return
        }
        #expect(unordered.count == 2)
        #expect(unordered[1].content == [.bold([.text("Second")])])

        guard case .orderedList(let start, let ordered) = document.blocks[2] else {
            Issue.record("Expected an ordered-list block.")
            return
        }
        #expect(start == 3)
        #expect(ordered.count == 2)
        #expect(ordered[1].content == [.italic([.text("Fourth")])])

        let html = NodeNoteRendering.htmlBody(source)
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<ul><li>First</li><li><strong>Second</strong></li></ul>"))
        #expect(html.contains(#"<ol start="3">"#))
        #expect(html.contains(#"&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"#))
        #expect(!html.contains(#"<script>alert("x")</script>"#))
    }

    @Test func safeMarkdownPreservesBalancedParenthesesInLinkDestinations() throws {
        let destination = "https://en.wikipedia.org/wiki/Function_(mathematics)"
        let document = try SafeMarkdownParser.parse("[Wiki](\(destination))")

        guard case .paragraph(let content) = document.blocks.first,
              case .link(let label, let url) = content.first
        else {
            Issue.record("Expected one safe Markdown link")
            return
        }

        #expect(label.map(\.plainText).joined() == "Wiki")
        #expect(url.absoluteString == destination)
    }

    @Test func wysiwygYouTubeDetectionKeepsEveryVisibleLink() {
        let source = """
        Watch [the walkthrough](https://youtu.be/M7lc1UVf-VE).

        https://www.youtube.com/watch?v=dQw4w9WgXcQ
        """
        let extraction = NodeNoteRichTextCodec.extractingYouTubeReferences(
            from: source
        )

        #expect(
            extraction.references == [
                "https://youtu.be/M7lc1UVf-VE",
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            ]
        )
        #expect(extraction.bodyMarkdown == source)
    }

    @Test func wysiwygKeepsYouTubeLinksVisibleWhileDetectingPlayers() {
        let source = """
        Watch [the walkthrough](https://youtu.be/M7lc1UVf-VE).

        https://www.youtube.com/watch?v=dQw4w9WgXcQ
        """

        #expect(
            NodeNoteRichTextCodec.youtubeReferences(in: source) == [
                "https://youtu.be/M7lc1UVf-VE",
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            ]
        )
        #expect(source.contains("[the walkthrough](https://youtu.be/M7lc1UVf-VE)"))
        #expect(source.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    @Test func embeddedNoteImagesStayWithinACompactViewport() {
        let landscape = NodeNoteEmbeddedImageSizing.displaySize(
            for: CGSize(width: 4_000, height: 3_000)
        )
        #expect(abs(landscape.width - (880.0 / 3.0)) < 0.001)
        #expect(landscape.height == 220)
        #expect(
            NodeNoteEmbeddedImageSizing.displaySize(
                for: CGSize(width: 1_000, height: 4_000)
            ) == CGSize(width: 55, height: 220)
        )
        #expect(
            NodeNoteEmbeddedImageSizing.displaySize(
                for: CGSize(width: 120, height: 80)
            ) == CGSize(width: 120, height: 80)
        )
    }

    @Test func pngAndPDFExportsAlwaysUseANoteFreeLayout() {
        #expect(BrainstormExporter.layoutNoteInclusion(for: .png) == .none)
        #expect(BrainstormExporter.layoutNoteInclusion(for: .pdf) == .none)
    }

    @Test func wysiwygCodecHidesSourceSyntaxAndRoundTripsRichContent() throws {
        let source = """
        Intro **bold** and _italic_ with [Example](https://example.com/guide)

        - First
        - **Second**

        3. Third
        4. _Fourth_
        """

        let attributed = NodeNoteRichTextCodec.attributedString(from: source)
        #expect(!attributed.string.contains("**"))
        #expect(!attributed.string.contains("_italic_"))
        #expect(!attributed.string.contains("[Example]"))
        #expect(!attributed.string.contains("- First"))
        #expect(attributed.string.contains("Intro bold and italic with Example"))

        let exampleRange = (attributed.string as NSString).range(of: "Example")
        let destination = attributed.attribute(
            .link,
            at: exampleRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(destination?.absoluteString == "https://example.com/guide")

        let firstRange = (attributed.string as NSString).range(of: "First")
        let firstStyle = attributed.attribute(
            .paragraphStyle,
            at: firstRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(firstStyle?.textLists.last?.isOrdered == false)

        let thirdRange = (attributed.string as NSString).range(of: "Third")
        let thirdStyle = attributed.attribute(
            .paragraphStyle,
            at: thirdRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(thirdStyle?.textLists.last?.isOrdered == true)
        #expect(thirdStyle?.textLists.last?.startingItemNumber == 3)

        #expect(NodeNoteRichTextCodec.markdown(from: attributed) == source)
    }

    @Test func wysiwygCodecFindsInlineBareAndMarkdownYouTubeLinks() throws {
        let bareYouTubeURL = "https://youtu.be/\(firstVideoID)?t=90"
        let linkedYouTubeURL = "https://www.youtube.com/watch?v=\(secondVideoID)"
        let source = """
        Read https://example.com/reference, watch \(bareYouTubeURL), or open [Demo](\(linkedYouTubeURL)).
        """
        let attributed = NodeNoteRichTextCodec.attributedString(from: source)
        let ordinaryURLRange = (attributed.string as NSString).range(
            of: "https://example.com/reference"
        )
        let ordinaryDestination = attributed.attribute(
            .link,
            at: ordinaryURLRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(ordinaryDestination?.absoluteString == "https://example.com/reference")

        let detections = NodeNoteRichTextCodec.youtubeDetections(
            in: attributed
        )
        #expect(detections.count == 2)
        #expect(detections[0].reference == bareYouTubeURL)
        #expect(!detections[0].retainsVisibleText)
        #expect(
            (attributed.string as NSString).substring(with: detections[0].range)
                == bareYouTubeURL
        )
        #expect(detections[1].reference == linkedYouTubeURL)
        #expect(detections[1].retainsVisibleText)
        #expect(
            (attributed.string as NSString).substring(with: detections[1].range)
                == "Demo"
        )
        #expect(
            NodeNoteRichTextCodec.markdown(from: attributed)
                .contains("[https://example.com/reference](https://example.com/reference)")
        )
    }

    @Test func wysiwygToolbarChangesAttributesWithoutExposingMarkdownMarkers() {
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.textStorage?.setAttributedString(
            NodeNoteRichTextCodec.attributedString(from: "One\nTwo")
        )
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        textView.setSelectedRange(NSRange(location: 0, length: 3))
        coordinator.apply(.bold)
        #expect(textView.string == "One\nTwo")
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == "**One**\nTwo"
        )
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == "One\nTwo"
        )
        textView.undoManager?.redo()
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == "**One**\nTwo"
        )

        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        coordinator.apply(.unorderedList)
        #expect(textView.string == "One\nTwo")
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == "- **One**\n- Two"
        )
    }

    @Test func wysiwygSelectionPublishesOnOffAndMixedFormattingState() throws {
        var states: [NodeNoteFormattingState] = []
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onFormattingStateChange: { states.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.textStorage?.setAttributedString(
            NodeNoteRichTextCodec.attributedString(
                from: "**Bold** _italic_ plain\n\n1. First\n2. Second"
            )
        )
        coordinator.textView = textView

        let boldRange = (textView.string as NSString).range(of: "Bold")
        textView.setSelectedRange(boldRange)
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        #expect(states.last?.bold == .on)
        #expect(states.last?.italic == .off)
        #expect(states.last?.orderedList == .off)

        let paragraphRange = (textView.string as NSString).range(
            of: "Bold italic plain"
        )
        textView.setSelectedRange(paragraphRange)
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        #expect(states.last?.bold == .mixed)
        #expect(states.last?.italic == .mixed)

        let firstItemRange = (textView.string as NSString).range(of: "First")
        textView.setSelectedRange(
            NSRange(location: firstItemRange.location, length: 0)
        )
        textView.typingAttributes = textView.attributedString().attributes(
            at: firstItemRange.location,
            effectiveRange: nil
        )
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        #expect(states.last?.orderedList == .on)
        #expect(states.last?.unorderedList == .off)
    }

    @Test func wysiwygPasteEmbedsYouTubeWithoutRemovingVisibleLinks() {
        let root = BrainstormNode(id: UUID(), title: "Root")
        let store = BrainstormStore(root: root, startEditing: false)
        var detectedYouTube: [String] = []
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onYouTubeLinksDetected: { references, bodyMarkdown in
                detectedYouTube = references
                do {
                    _ = try store.embedNoteYouTubeLinks(
                        references,
                        bodyMarkdown: bodyMarkdown,
                        for: root.id
                    )
                    return NodeNoteYouTubeLinkTransaction(
                        undo: store.undo,
                        redo: store.redo
                    )
                } catch {
                    Issue.record("Unexpected embed failure: \(error)")
                    return nil
                }
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        let bareYouTubeURL = "https://youtu.be/\(firstVideoID)?t=90"
        let linkedYouTubeURL = "https://www.youtube.com/watch?v=\(secondVideoID)"
        let source = """
        Before \(bareYouTubeURL) after [Demo](\(linkedYouTubeURL)), plus [Example](https://example.com/guide).
        """
        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: source
            )
        )
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: source
        )
        textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        #expect(
            textView.string
                == "Before \(bareYouTubeURL) after Demo, plus Example."
        )
        #expect(detectedYouTube == [bareYouTubeURL, linkedYouTubeURL])
        #expect(
            store.note(for: root.id)?.bodyMarkdown
                == "Before [\(bareYouTubeURL)](\(bareYouTubeURL)) after [Demo](\(linkedYouTubeURL)), plus [Example](https://example.com/guide)."
        )
        #expect(store.note(for: root.id)?.attachments.count == 2)
        #expect(
            textView.selectedRange()
                == NSRange(location: textView.string.utf16.count, length: 0)
        )

        let demoRange = (textView.string as NSString).range(of: "Demo")
        let demoDestination = textView.attributedString().attribute(
            .link,
            at: demoRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(demoDestination?.absoluteString == linkedYouTubeURL)
        let exampleRange = (textView.string as NSString).range(of: "Example")
        let ordinaryDestination = textView.attributedString().attribute(
            .link,
            at: exampleRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(ordinaryDestination?.absoluteString == "https://example.com/guide")

        textView.undoManager?.undo()
        #expect(textView.string.isEmpty)
        #expect(store.note(for: root.id) == nil)
        textView.undoManager?.redo()
        #expect(
            textView.string
                == "Before \(bareYouTubeURL) after Demo, plus Example."
        )
        #expect(store.note(for: root.id)?.attachments.count == 2)
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == "Before [\(bareYouTubeURL)](\(bareYouTubeURL)) after [Demo](\(linkedYouTubeURL)), plus [Example](https://example.com/guide)."
        )
    }

    @Test func wysiwygTypedYouTubeURLAtEndEmbedsWithoutTrailingWhitespace() {
        var detectedReferences: [String] = []
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onYouTubeLinksDetected: { references, _ in
                detectedReferences = references
                return NodeNoteYouTubeLinkTransaction(
                    undo: {},
                    redo: {}
                )
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView
        let youtubeURL = "https://youtu.be/\(firstVideoID)"

        for character in youtubeURL {
            let insertion = String(character)
            let range = NSRange(location: textView.string.utf16.count, length: 0)
            #expect(
                coordinator.textView(
                    textView,
                    shouldChangeTextIn: range,
                    replacementString: insertion
                )
            )
            textView.textStorage?.replaceCharacters(in: range, with: insertion)
            textView.setSelectedRange(
                NSRange(location: textView.string.utf16.count, length: 0)
            )
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: textView)
            )
        }

        #expect(detectedReferences == [youtubeURL])
        #expect(textView.string == youtubeURL)
    }

    @Test func wysiwygYouTubeCapacityFailureRetainsTextLinksAndUndo() {
        let attachments = (0..<NodeNoteValidator.maxAttachmentsPerNote).map { _ in
            NodeNoteAttachment.youtube(
                NoteYouTubeAttachment(videoID: firstVideoID)
            )
        }
        let root = BrainstormNode(
            id: UUID(),
            title: "Full",
            note: NodeNote(attachments: attachments)
        )
        let store = BrainstormStore(root: root, startEditing: false)
        var attemptedReferences: [String] = []
        var insertionError: Error?
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onYouTubeLinksDetected: { references, bodyMarkdown in
                attemptedReferences = references
                do {
                    _ = try store.embedNoteYouTubeLinks(
                        references,
                        bodyMarkdown: bodyMarkdown,
                        for: root.id
                    )
                    return NodeNoteYouTubeLinkTransaction(
                        undo: store.undo,
                        redo: store.redo
                    )
                } catch {
                    insertionError = error
                    return nil
                }
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        let bareYouTubeURL = "https://youtu.be/\(firstVideoID)"
        let linkedYouTubeURL = "https://www.youtube.com/watch?v=\(secondVideoID)"
        let source = "Keep \(bareYouTubeURL) and [Demo](\(linkedYouTubeURL)) available."
        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: source
            )
        )
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: source
        )
        textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(insertionError != nil)
        #expect(attemptedReferences == [bareYouTubeURL, linkedYouTubeURL])
        #expect(store.note(for: root.id)?.attachments.count == attachments.count)
        #expect(textView.string == "Keep \(bareYouTubeURL) and Demo available.")
        #expect(
            textView.selectedRange()
                == NSRange(location: textView.string.utf16.count, length: 0)
        )

        let bareRange = (textView.string as NSString).range(of: bareYouTubeURL)
        let bareDestination = textView.attributedString().attribute(
            .link,
            at: bareRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(bareDestination?.absoluteString == bareYouTubeURL)
        let demoRange = (textView.string as NSString).range(of: "Demo")
        let demoDestination = textView.attributedString().attribute(
            .link,
            at: demoRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(demoDestination?.absoluteString == linkedYouTubeURL)

        textView.undoManager?.undo()
        #expect(textView.string.isEmpty)
        textView.undoManager?.redo()
        #expect(textView.string == "Keep \(bareYouTubeURL) and Demo available.")
        let restoredDemoDestination = textView.attributedString().attribute(
            .link,
            at: demoRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(restoredDemoDestination?.absoluteString == linkedYouTubeURL)
    }

    @Test func wysiwygRejectsBodyInsertionBeyondMaximumBeforeMutation() {
        var validationFailures: [String] = []
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onValidationFailure: { validationFailures.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        let baseline = String(
            repeating: "a",
            count: NodeNoteValidator.maxBodyCharacters - 1
        )
        textView.textStorage?.setAttributedString(
            NodeNoteRichTextCodec.attributedString(from: baseline)
        )
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView
        let insertionRange = NSRange(location: textView.string.utf16.count, length: 0)

        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: insertionRange,
                replacementString: "b"
            )
        )
        #expect(
            !coordinator.textView(
                textView,
                shouldChangeTextIn: insertionRange,
                replacementString: "bc"
            )
        )
        #expect(textView.string == baseline)
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == baseline
        )
        #expect(
            validationFailures
                == ["Note text exceeds \(NodeNoteValidator.maxBodyCharacters) characters."]
        )
    }

    @Test func wysiwygRejectsFormattingThatWouldExceedMaximum() {
        var validationFailures: [String] = []
        let editor = NodeNoteTextEditor(
            text: .constant(""),
            commandRequest: nil,
            onValidationFailure: { validationFailures.append($0) }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        let maximumBody = String(
            repeating: "a",
            count: NodeNoteValidator.maxBodyCharacters
        )
        textView.textStorage?.setAttributedString(
            NodeNoteRichTextCodec.attributedString(from: maximumBody)
        )
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        textView.setSelectedRange(
            NSRange(location: 0, length: textView.string.utf16.count)
        )
        coordinator.textView = textView

        coordinator.apply(.bold)
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == maximumBody
        )
        coordinator.apply(.unorderedList)
        #expect(
            NodeNoteRichTextCodec.markdown(from: textView.attributedString())
                == maximumBody
        )
        let paragraphStyle = textView.attributedString().attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(paragraphStyle?.textLists.isEmpty == true)
        #expect(validationFailures.count == 2)
        #expect(
            validationFailures.allSatisfy {
                $0 == "Note text exceeds \(NodeNoteValidator.maxBodyCharacters) characters."
            }
        )
    }

    @Test func wysiwygLiteralInlineDelimitersRemainLiteralAfterReopen() {
        let visible = #"_literal_ **literal** [x](y)"#
        let attributed = NSAttributedString(
            string: visible,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )

        let canonical = NodeNoteRichTextCodec.markdown(from: attributed)
        #expect(canonical == #"\_literal\_ \*\*literal\*\* \[x\](y)"#)

        let reopened = NodeNoteRichTextCodec.attributedString(from: canonical)
        #expect(reopened.string == visible)
        #expect(NodeNoteRichTextCodec.markdown(from: reopened) == canonical)

        let literalRange = (reopened.string as NSString).range(of: "literal")
        let font = reopened.attribute(
            .font,
            at: literalRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(
            font.map {
                !NodeNoteRichTextCodec.fontHasTrait(.italicFontMask, font: $0)
            } == true
        )
        let linkRange = (reopened.string as NSString).range(of: "x")
        #expect(
            reopened.attribute(.link, at: linkRange.location, effectiveRange: nil)
                == nil
        )

        let html = NodeNoteRendering.htmlBody(canonical)
        #expect(html.contains("_literal_ **literal** [x](y)"))
        #expect(!html.contains("<strong>"))
        #expect(!html.contains("<em>"))
        #expect(!html.contains("<a "))
    }

    @Test func wysiwygBackslashesAndBracketsRoundTripExactly() {
        let visible = #"\path [brackets] \[escaped-looking\] [x](y)"#
        let attributed = NSAttributedString(
            string: visible,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )

        let canonical = NodeNoteRichTextCodec.markdown(from: attributed)
        #expect(canonical.contains(#"\\path"#))
        #expect(canonical.contains(#"\[brackets\]"#))
        #expect(canonical.contains(#"\\\[escaped-looking\\\]"#))

        let reopened = NodeNoteRichTextCodec.attributedString(from: canonical)
        #expect(reopened.string == visible)
        #expect(NodeNoteRichTextCodec.markdown(from: reopened) == canonical)
    }

    @Test func wysiwygListLikeParagraphsDoNotBecomeListsAfterReopen() throws {
        let visible = """
        - item
        + item
        * item
        1. item
        42. item
        """
        let attributed = NSAttributedString(
            string: visible,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )
        let canonical = NodeNoteRichTextCodec.markdown(from: attributed)
        #expect(canonical == #"""
        \- item
        \+ item
        \* item
        1\. item
        42\. item
        """#)

        let parsed = try SafeMarkdownParser.parse(canonical)
        #expect(parsed.blocks.count == 1)
        guard case .paragraph = parsed.blocks[0] else {
            Issue.record("Escaped list lookalikes must remain one paragraph.")
            return
        }

        let reopened = NodeNoteRichTextCodec.attributedString(from: canonical)
        #expect(reopened.string == visible)
        for token in ["- item", "+ item", "* item", "1. item", "42. item"] {
            let range = (reopened.string as NSString).range(of: token)
            let style = reopened.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(style?.textLists.isEmpty == true)
        }
        #expect(NodeNoteRichTextCodec.markdown(from: reopened) == canonical)
        #expect(NodeNoteRendering.sanitizedMarkdownBody(canonical) == canonical)
    }

    @Test func wysiwygActualFormattingAndLiteralMarkersStayDistinct() {
        let visible = "actual formatted and **literal** plus _literal_ and [x](y)"
        let attributed = NSMutableAttributedString(
            string: visible,
            attributes: NodeNoteRichTextCodec.baseAttributes
        )
        let source = visible as NSString
        let actualRange = source.range(of: "actual")
        let formattedRange = source.range(of: "formatted")
        attributed.addAttribute(
            .font,
            value: NodeNoteRichTextCodec.font(
                byToggling: .boldFontMask,
                in: NodeNoteRichTextCodec.baseFont,
                removing: false
            ),
            range: actualRange
        )
        attributed.addAttribute(
            .font,
            value: NodeNoteRichTextCodec.font(
                byToggling: .italicFontMask,
                in: NodeNoteRichTextCodec.baseFont,
                removing: false
            ),
            range: formattedRange
        )

        let canonical = NodeNoteRichTextCodec.markdown(from: attributed)
        #expect(
            canonical
                == #"**actual** _formatted_ and \*\*literal\*\* plus \_literal\_ and \[x\](y)"#
        )

        let reopened = NodeNoteRichTextCodec.attributedString(from: canonical)
        #expect(reopened.string == visible)
        let actualFont = reopened.attribute(
            .font,
            at: actualRange.location,
            effectiveRange: nil
        ) as? NSFont
        let formattedFont = reopened.attribute(
            .font,
            at: formattedRange.location,
            effectiveRange: nil
        ) as? NSFont
        let literalRange = (reopened.string as NSString).range(of: "**literal**")
        let literalFont = reopened.attribute(
            .font,
            at: literalRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(
            actualFont.map {
                NodeNoteRichTextCodec.fontHasTrait(.boldFontMask, font: $0)
            } == true
        )
        #expect(
            formattedFont.map {
                NodeNoteRichTextCodec.fontHasTrait(.italicFontMask, font: $0)
            } == true
        )
        #expect(
            literalFont.map {
                !NodeNoteRichTextCodec.fontHasTrait(.boldFontMask, font: $0)
            } == true
        )
        #expect(NodeNoteRichTextCodec.markdown(from: reopened) == canonical)
    }

    @Test func noteTextViewPasteDiscardsRichPasteboardFormatting() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("brainstorm-note-test-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let rich = NSAttributedString(
            string: "Plain pasted text",
            attributes: [
                .font: NSFont.systemFont(ofSize: 42, weight: .black),
                .foregroundColor: NSColor.systemRed,
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
            ]
        )
        let rtf = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        #expect(pasteboard.setData(rtf, forType: .rtf))
        #expect(pasteboard.setString(rich.string, forType: .string))

        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        textView.notePasteboard = pasteboard
        textView.paste(nil)

        #expect(textView.string == rich.string)
        let pastedFont = textView.attributedString().attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        let pastedColor = textView.attributedString().attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        let underline = textView.attributedString().attribute(
            .underlineStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSNumber
        #expect(pastedFont?.pointSize == NodeNoteRichTextCodec.baseFont.pointSize)
        #expect(pastedColor != NSColor.systemRed)
        #expect(underline == nil)
    }

    @Test func noteTextViewHandlesNativeFormattingShortcuts() throws {
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        var received: [NodeNoteTextCommand] = []
        textView.onFormattingCommand = { received.append($0) }

        let shortcuts: [
            (characters: String, ignored: String, modifiers: NSEvent.ModifierFlags)
        ] = [
            ("b", "b", [.command]),
            ("i", "i", [.command]),
            ("&", "&", [.command, .shift]),
            ("*", "*", [.command, .shift]),
        ]
        for (characters, ignored, modifiers) in shortcuts {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: ignored,
                    isARepeat: false,
                    keyCode: 0
                )
            )
            #expect(textView.performKeyEquivalent(with: event))
        }

        #expect(
            received == [
                .bold,
                .italic,
                .orderedList,
                .unorderedList,
            ]
        )
    }

    @Test func noteTextViewInternalCopyPastePreservesSupportedFormatting() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("brainstorm-note-test-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let canonical = """
        **Bold** _italic_ [Link](https://example.com/guide)

        - One
        - Two
        """
        let source = NodeNoteTextView(usingTextLayoutManager: true)
        source.isRichText = true
        source.notePasteboard = pasteboard
        source.textStorage?.setAttributedString(
            NodeNoteRichTextCodec.attributedString(from: canonical)
        )
        source.setSelectedRange(
            NSRange(location: 0, length: source.attributedString().length)
        )
        source.copy(nil)

        #expect(
            pasteboard.string(forType: NodeNoteTextView.canonicalMarkdownPasteboardType)
                == canonical
        )
        #expect(pasteboard.string(forType: .string) == source.string)

        let destination = NodeNoteTextView(usingTextLayoutManager: true)
        destination.isRichText = true
        destination.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        destination.notePasteboard = pasteboard
        destination.paste(nil)

        #expect(destination.string == source.string)
        #expect(
            NodeNoteRichTextCodec.markdown(from: destination.attributedString())
                == canonical
        )

        let boldRange = (destination.string as NSString).range(of: "Bold")
        let boldFont = destination.attributedString().attribute(
            .font,
            at: boldRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(
            boldFont.map {
                NodeNoteRichTextCodec.fontHasTrait(.boldFontMask, font: $0)
            } == true
        )

        let linkRange = (destination.string as NSString).range(of: "Link")
        let link = destination.attributedString().attribute(
            .link,
            at: linkRange.location,
            effectiveRange: nil
        ) as? URL
        #expect(link?.absoluteString == "https://example.com/guide")

        let itemRange = (destination.string as NSString).range(of: "One")
        let itemStyle = destination.attributedString().attribute(
            .paragraphStyle,
            at: itemRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(itemStyle?.textLists.last?.isOrdered == false)
    }

    @Test func wysiwygPublishesCanonicalMarkdownAfterTypingSettles() async throws {
        var published = ""
        let editor = NodeNoteTextEditor(
            text: Binding(
                get: { published },
                set: { published = $0 }
            ),
            commandRequest: nil
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        let insertion = "Responsive typing"
        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: insertion
            )
        )
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: insertion
        )
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(published.isEmpty)
        try await Task.sleep(nanoseconds: 320_000_000)
        #expect(published == insertion)
    }

    @Test func documentCheckpointFlushesSubDebounceTextIntoTheStoreSynchronously() throws {
        let root = BrainstormNode(id: UUID(), title: "Root")
        let store = BrainstormStore(root: root, startEditing: false)
        store.beginNoteEditing(id: root.id)

        var bodyDraft = ""
        let editor = NodeNoteTextEditor(
            text: Binding(
                get: { bodyDraft },
                set: { markdown in
                    bodyDraft = markdown
                    do {
                        try store.updateNoteEditingDraft(markdown)
                    } catch {
                        Issue.record("Unexpected draft validation failure: \(error)")
                    }
                }
            ),
            commandRequest: nil
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        textView.onFlushPendingChanges = coordinator.flushPendingChanges
        coordinator.textView = textView

        let insertion = "Saved before the debounce expires"
        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: insertion
            )
        )
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: insertion
        )
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(bodyDraft.isEmpty)
        #expect(store.note(for: root.id) == nil)
        textView.flushPendingNoteChanges()
        #expect(bodyDraft == insertion)
        #expect(store.note(for: root.id)?.bodyMarkdown == insertion)
        #expect(store.isDirty)
    }

    @Test func noteTextViewPastesImagesAsAttachmentsInsteadOfInlineText() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("brainstorm-note-image-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let data = image.tiffRepresentation else {
            Issue.record("Could not create image pasteboard data")
            return
        }
        pasteboard.declareTypes([.tiff], owner: nil)
        #expect(pasteboard.setData(data, forType: .tiff))

        var receivedImage: Data?
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.notePasteboard = pasteboard
        textView.onPasteImage = { data, _ in
            receivedImage = data
            return true
        }
        textView.paste(nil)

        #expect(receivedImage != nil)
        #expect(textView.string.isEmpty)
    }

    @Test func noteTextViewPrefersEmbeddedImageBytesOverRemoteSourceURL() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-note-web-image-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let remoteURL = "https://example.com/second-image.png"
        pasteboard.declareTypes([.URL, .tiff, .string], owner: nil)
        #expect(pasteboard.setString(remoteURL, forType: .URL))
        #expect(pasteboard.setData(data, forType: .tiff))
        #expect(pasteboard.setString(remoteURL, forType: .string))

        var receivedImage: Data?
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, _ in
            receivedImage = data
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(receivedImage == data)
    }

    @Test func noteTextViewImportsLocalImageFilesThroughThePasteAndDropPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BrainstormNoteDrop-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let sourceData = try #require(image.tiffRepresentation)
        let imageURL = directory.appendingPathComponent("Dragged-image.tiff")
        try sourceData.write(to: imageURL)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("brainstorm-note-file-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        pasteboard.declareTypes([.fileURL], owner: nil)
        #expect(pasteboard.setString(imageURL.absoluteString, forType: .fileURL))

        var receivedImage: Data?
        var receivedAltText = ""
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, altText in
            receivedImage = data
            receivedAltText = altText
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(receivedImage == sourceData)
        #expect(receivedAltText == "Dragged image")
    }

    @Test func noteTextViewImportsEveryImageFromOneMultiFileDrop() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BrainstormNoteMultiDrop-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstImage = NSImage(size: NSSize(width: 8, height: 8))
        firstImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        firstImage.unlockFocus()
        let firstData = try #require(firstImage.tiffRepresentation)
        let firstURL = directory.appendingPathComponent("First-image.tiff")
        try firstData.write(to: firstURL)

        let secondImage = NSImage(size: NSSize(width: 8, height: 8))
        secondImage.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        secondImage.unlockFocus()
        let secondData = try #require(secondImage.tiffRepresentation)
        let secondURL = directory.appendingPathComponent("Second_image.tiff")
        try secondData.write(to: secondURL)

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "brainstorm-note-multi-file-\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(
            pasteboard.writeObjects([
                firstURL as NSURL,
                secondURL as NSURL,
            ])
        )

        var receivedImages: [(data: Data, altText: String)] = []
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.onPasteImage = { data, altText in
            receivedImages.append((data, altText))
            return true
        }

        #expect(textView.importImage(from: pasteboard))
        #expect(receivedImages.count == 2)
        #expect(receivedImages.map(\.data) == [firstData, secondData])
        #expect(receivedImages.map(\.altText) == ["First image", "Second image"])
    }

    @Test func wysiwygEditorKeepsTwoSequentiallyInsertedImages() throws {
        var bodyDraft = ""
        var attachments: [NoteImageAttachment] = []
        let editor = NodeNoteTextEditor(
            text: Binding(
                get: { bodyDraft },
                set: { bodyDraft = $0 }
            ),
            imageAttachments: attachments,
            commandRequest: nil,
            onImagePasted: { data, altText in
                guard let image = try? NodeNoteImageNormalizer.normalize(
                    data,
                    altText: altText
                ) else {
                    return nil
                }
                return NodeNoteImageInsertion(
                    attachment: image,
                    commit: {
                        attachments.append(image)
                        return NodeNoteStoreTransaction(
                            undo: {},
                            redo: {}
                        )
                    }
                )
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.typingAttributes = NodeNoteRichTextCodec.baseAttributes
        coordinator.textView = textView

        let firstImage = NSImage(size: NSSize(width: 8, height: 8))
        firstImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        firstImage.unlockFocus()
        let firstData = try #require(firstImage.tiffRepresentation)

        let secondImage = NSImage(size: NSSize(width: 8, height: 8))
        secondImage.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        secondImage.unlockFocus()
        let secondData = try #require(secondImage.tiffRepresentation)

        #expect(
            coordinator.handlePastedImage(
                firstData,
                suggestedAltText: "First image"
            )
        )
        #expect(
            coordinator.handlePastedImage(
                secondData,
                suggestedAltText: "Second image"
            )
        )
        #expect(attachments.count == 2)
        #expect(
            NodeNoteInlineImageLayout.attachments(
                in: textView.attributedString()
            ).map(\.attachment.noteImageID)
                == attachments.map(\.id)
        )
        #expect(
            textView.selectedRange()
                == NSRange(location: textView.string.utf16.count, length: 0)
        )
    }

    @Test func remoteURLPasteRemainsTextAndNeverEntersTheImageImporter() {
        let remoteURL = "https://www.youtube.com/watch?v=\(firstVideoID)"
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("brainstorm-note-url-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        pasteboard.declareTypes([.URL, .string], owner: nil)
        #expect(pasteboard.setString(remoteURL, forType: .URL))
        #expect(pasteboard.setString(remoteURL, forType: .string))

        var imageImporterWasCalled = false
        let textView = NodeNoteTextView(usingTextLayoutManager: true)
        textView.notePasteboard = pasteboard
        textView.onPasteImage = { _, _ in
            imageImporterWasCalled = true
            return true
        }
        textView.paste(nil)

        #expect(!imageImporterWasCalled)
        #expect(textView.string == remoteURL)
    }

    @Test func safeMarkdownRendersOnlyValidatedWebLinks() throws {
        let source = """
        [Brainstorm](https://selfhosted.ninja/projects/brainstorm/) and [bold **docs**](https://example.com/guide?q=1)
        [unsafe](javascript:alert(1))
        """
        let document = try SafeMarkdownParser.parse(source)
        guard case .paragraph(let content) = document.blocks[0] else {
            Issue.record("Expected linked paragraph.")
            return
        }
        #expect(content.contains {
            if case .link(let label, let destination) = $0 {
                return label.map(\.plainText).joined() == "Brainstorm"
                    && destination.host == "selfhosted.ninja"
            }
            return false
        })

        let html = NodeNoteRendering.htmlBody(source)
        #expect(html.contains(
            #"href="https://selfhosted.ninja/projects/brainstorm/""#
        ))
        #expect(html.contains(#"rel="noopener noreferrer""#))
        #expect(html.contains(#"<strong>docs</strong>"#))
        #expect(!html.contains(#"href="javascript:"#))
        #expect(html.contains("[unsafe](javascript:alert(1))"))
    }

    @Test func youtubeParserAcceptsPortableIDsAndCommonStartTimeURLs() throws {
        #expect(
            try YouTubeReferenceParser.parse(firstVideoID)
                == ParsedYouTubeReference(videoID: firstVideoID)
        )
        #expect(
            try YouTubeReferenceParser.parse(
                "https://www.youtube.com/watch?v=\(firstVideoID)&t=1m30s"
            ) == ParsedYouTubeReference(videoID: firstVideoID, startSeconds: 90)
        )
        #expect(
            try YouTubeReferenceParser.parse(
                "youtu.be/\(firstVideoID)#t=45s"
            ) == ParsedYouTubeReference(videoID: firstVideoID, startSeconds: 45)
        )
        #expect(
            try YouTubeReferenceParser.parse(
                "https://www.youtube-nocookie.com/embed/\(firstVideoID)?start=125"
            ) == ParsedYouTubeReference(videoID: firstVideoID, startSeconds: 125)
        )
        #expect(
            try YouTubeReferenceParser.parse(
                "https://youtube.com/shorts/\(firstVideoID)?time_continue=2h3m4s"
            ) == ParsedYouTubeReference(videoID: firstVideoID, startSeconds: 7_384)
        )
        #expect(try YouTubeReferenceParser.parseStartSeconds("1h2m3s") == 3_723)
    }

    @Test func nativeYouTubePlayerProvidesAStableHTTPSClientIdentity() {
        let document = NodeNoteRendering.nativeYouTubePlayerDocument(
            videoID: firstVideoID,
            startSeconds: 90
        )
        let decodedDocument = document.removingPercentEncoding ?? document

        #expect(
            NodeNoteRendering.nativeYouTubeClientPageURL.absoluteString
                == "https://selfhosted.ninja/projects/brainstorm/"
        )
        #expect(
            document.contains(
                "https://www.youtube-nocookie.com/embed/\(firstVideoID)"
            )
        )
        #expect(document.contains("start=90"))
        #expect(document.contains("playsinline=1"))
        #expect(decodedDocument.contains("origin=https://selfhosted.ninja"))
        #expect(
            decodedDocument.contains(
                "widget_referrer=https://selfhosted.ninja/projects/brainstorm/"
            )
        )
        #expect(
            document.contains(
                #"referrerpolicy="strict-origin-when-cross-origin""#
            )
        )
        #expect(!document.contains("com.eugenep.brainstorm"))
    }

    @Test func nativeYouTubeWebKitSendsTheClientReferrer() async throws {
        let capture = YouTubeNavigationCapture()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 360)
        )
        webView.navigationDelegate = capture
        webView.loadHTMLString(
            NodeNoteRendering.nativeYouTubePlayerDocument(
                videoID: firstVideoID,
                startSeconds: nil
            ),
            baseURL: NodeNoteRendering.nativeYouTubeClientPageURL
        )

        for _ in 0..<100 where !capture.didObserveYouTubeNavigation {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capture.didObserveYouTubeNavigation)
        #expect(
            capture.referrer?.hasPrefix("https://selfhosted.ninja/") == true
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    @Test func youtubeParserRejectsLookalikeHostsBadIDsAndUnboundedStarts() {
        let invalidReferences = [
            "https://youtube.com.evil.example/watch?v=\(firstVideoID)",
            "https://example.com/\(firstVideoID)",
            "not-an-id",
            "https://youtube.com/watch?v=too_short",
        ]
        for reference in invalidReferences {
            do {
                _ = try YouTubeReferenceParser.parse(reference)
                Issue.record("Expected rejection for \(reference).")
            } catch let issue as NodeNoteValidationError {
                #expect(issue.code == .invalidYouTubeReference)
            } catch {
                Issue.record("Expected NodeNoteValidationError, got \(error).")
            }
        }

        for start in ["999999999999999999999999h", "7d", "-1", "604801"] {
            do {
                _ = try YouTubeReferenceParser.parseStartSeconds(start)
                Issue.record("Expected rejection for start time \(start).")
            } catch let issue as NodeNoteValidationError {
                #expect(issue.code == .invalidYouTubeStart)
            } catch {
                Issue.record("Expected NodeNoteValidationError, got \(error).")
            }
        }
    }

    @Test func presentationKeyboardLeavesSpaceToFocusedControls() {
        #expect(
            presentationKeyboardAction(
                keyCode: 49,
                modifierFlags: [],
                handlesSpace: true
            ) == .next
        )
        #expect(
            presentationKeyboardAction(
                keyCode: 49,
                modifierFlags: [],
                handlesSpace: false
            ) == nil
        )
        #expect(
            presentationKeyboardAction(
                keyCode: 123,
                modifierFlags: [],
                handlesSpace: false
            ) == .previous
        )
        #expect(
            presentationKeyboardAction(
                keyCode: 124,
                modifierFlags: [.command],
                handlesSpace: true
            ) == nil
        )
        #expect(
            presentationKeyboardAction(
                keyCode: 45,
                modifierFlags: [],
                handlesSpace: true
            ) == .toggleNote
        )
    }

    @Test func liveNoteEditingCoalescesTypingIntoOneUndoStep() throws {
        let root = BrainstormNode(id: UUID(), title: "Root")
        let store = BrainstormStore(root: root, startEditing: false)

        store.beginNoteEditing(id: root.id)
        try store.updateNoteEditingDraft("F")
        try store.updateNoteEditingDraft("First")
        try store.updateNoteEditingDraft("First **complete** note")
        store.commitNoteEditing()

        #expect(store.note(for: root.id)?.bodyMarkdown == "First **complete** note")
        #expect(store.undoManager.undoActionName == "Edit Note")
        store.undo()
        #expect(store.note(for: root.id) == nil)
        #expect(!store.canUndo)
        store.redo()
        #expect(store.note(for: root.id)?.bodyMarkdown == "First **complete** note")
    }

    @Test func savingCheckpointsAndResumesTheMountedNoteEditingSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BrainstormNoteSave-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Note-session.bs")

        let root = BrainstormNode(id: UUID(), title: "Root")
        let store = BrainstormStore(root: root, startEditing: false)
        store.beginNoteEditing(id: root.id)
        try store.updateNoteEditingDraft("Persisted checkpoint")

        #expect(store.save(to: url))
        #expect(store.noteEditingID == root.id)
        #expect(store.noteEditingDraft == "Persisted checkpoint")
        #expect(!store.isDirty)
        #expect(
            try BrainstormCodec.load(from: url).root.note?.bodyMarkdown
                == "Persisted checkpoint"
        )

        try store.updateNoteEditingDraft("Typing continues after Save")
        #expect(store.noteEditingID == root.id)
        #expect(
            store.note(for: root.id)?.bodyMarkdown
                == "Typing continues after Save"
        )
        #expect(store.isDirty)
        #expect(
            try BrainstormCodec.load(from: url).root.note?.bodyMarkdown
                == "Persisted checkpoint"
        )
    }

    @Test func visibilityAttachmentOrderAndClearAreIndependentlyUndoable() throws {
        let root = BrainstormNode(
            id: UUID(),
            title: "Root",
            note: NodeNote(bodyMarkdown: "Keep me")
        )
        let store = BrainstormStore(root: root, startEditing: false)

        #expect(store.setNoteVisibility(.hidden, for: root.id))
        #expect(store.note(for: root.id)?.visibility == .hidden)
        store.undo()
        #expect(store.note(for: root.id)?.visibility == .shown)
        store.redo()
        #expect(store.note(for: root.id)?.visibility == .hidden)

        let firstID = try store.addNoteYouTube(firstVideoID, for: root.id)
        let secondID = try store.addNoteYouTube(secondVideoID, for: root.id)
        #expect(store.note(for: root.id)?.attachments.map(\.id) == [firstID, secondID])

        #expect(store.moveNoteAttachment(firstID, to: 1, in: root.id))
        #expect(store.note(for: root.id)?.attachments.map(\.id) == [secondID, firstID])
        store.undo()
        #expect(store.note(for: root.id)?.attachments.map(\.id) == [firstID, secondID])
        store.redo()
        #expect(store.note(for: root.id)?.attachments.map(\.id) == [secondID, firstID])

        #expect(store.clearNote(for: root.id))
        #expect(store.note(for: root.id) == nil)
        store.undo()
        #expect(store.note(for: root.id)?.visibility == .hidden)
        #expect(store.note(for: root.id)?.attachments.map(\.id) == [secondID, firstID])
    }

    @Test func layoutNoteInclusionRespectsVisibleAllAndNone() {
        let rootID = UUID()
        let childID = UUID()
        let root = BrainstormNode(
            id: rootID,
            title: "Root",
            children: [
                BrainstormNode(
                    id: childID,
                    title: "Child",
                    note: NodeNote(
                        visibility: .hidden,
                        bodyMarkdown: "Hidden layout note"
                    )
                ),
            ],
            note: NodeNote(bodyMarkdown: "Shown layout note")
        )
        let engine = LayoutEngine()

        let visible = engine.layout(root: root, noteInclusion: .visible)
        #expect(visible.nodes.first(where: { $0.id == rootID })?.note != nil)
        #expect(visible.nodes.first(where: { $0.id == rootID })?.noteFrame != nil)
        #expect(visible.nodes.first(where: { $0.id == childID })?.note == nil)
        #expect(visible.nodes.first(where: { $0.id == childID })?.noteFrame == nil)

        let all = engine.layout(root: root, noteInclusion: .all)
        #expect(all.nodes.first(where: { $0.id == rootID })?.note != nil)
        #expect(all.nodes.first(where: { $0.id == childID })?.note?.visibility == .hidden)
        #expect(all.nodes.first(where: { $0.id == childID })?.noteFrame != nil)

        let none = engine.layout(root: root, noteInclusion: .none)
        #expect(none.nodes.allSatisfy { $0.note == nil && $0.noteFrame == nil })
        #expect(none.contentSize.height < all.contentSize.height)
    }

    @Test func shortNodeTitlesStillProduceReadableNonOverlappingNoteCards() throws {
        let child = BrainstormNode(title: "Child")
        let root = BrainstormNode(
            title: "A",
            children: [child],
            note: NodeNote(
                bodyMarkdown: "- Unordered item remains readable",
                attachments: [
                    .youtube(NoteYouTubeAttachment(videoID: firstVideoID)),
                ]
            )
        )
        let engine = LayoutEngine()
        let layout = engine.layout(root: root, noteInclusion: .all)
        let rootLayout = try #require(layout.nodes.first { $0.id == root.id })
        let childLayout = try #require(layout.nodes.first { $0.id == child.id })
        let noteFrame = try #require(rootLayout.noteFrame)

        #expect(noteFrame.width >= engine.minNoteWidth)
        #expect(noteFrame.width <= engine.maxNoteWidth)
        #expect(noteFrame.width > rootLayout.frame.width)
        #expect(childLayout.frame.minX >= noteFrame.maxX + engine.levelGap - 1)
    }

    @Test func allDescendantPlacementMatchesFullyExpandedManualGeometry() {
        let rootID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000601"
        )!
        let branchID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000602"
        )!
        let middleID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000603"
        )!
        let deepID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000604"
        )!
        let siblingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000605"
        )!
        let collapsedRoot = BrainstormNode(
            id: rootID,
            title: "Root",
            children: [
                BrainstormNode(
                    id: branchID,
                    title: "Collapsed branch",
                    isExpanded: false,
                    children: [
                        BrainstormNode(
                            id: middleID,
                            title: "Offset middle",
                            children: [
                                BrainstormNode(
                                    id: deepID,
                                    title: "Offset deep leaf",
                                    offsetX: -11,
                                    offsetY: 27
                                ),
                            ],
                            offsetX: 31,
                            offsetY: 14
                        ),
                    ],
                    offsetX: 18,
                    offsetY: -22
                ),
                BrainstormNode(
                    id: siblingID,
                    title: "Offset sibling",
                    offsetX: 9,
                    offsetY: -16
                ),
            ]
        )
        var expandedRoot = collapsedRoot
        expandedRoot.children[0].isExpanded = true

        let engine = LayoutEngine()
        let defaultLayout = engine.layout(root: collapsedRoot)
        let completeLayout = engine.layout(
            root: collapsedRoot,
            placementPolicy: .allDescendants
        )
        let expandedLayout = engine.layout(root: expandedRoot)
        let defaultIDs = Set(defaultLayout.nodes.map(\.id))
        let completeFrames = Dictionary(
            uniqueKeysWithValues: completeLayout.nodes.map { ($0.id, $0.frame) }
        )
        let expandedFrames = Dictionary(
            uniqueKeysWithValues: expandedLayout.nodes.map { ($0.id, $0.frame) }
        )

        #expect(defaultIDs == [rootID, branchID, siblingID])
        #expect(completeFrames.keys.count == 5)
        #expect(completeFrames == expandedFrames)
        #expect(completeLayout.edges == expandedLayout.edges)
        #expect(completeLayout.contentSize == expandedLayout.contentSize)
    }

    @Test func nativePresentationNavigationPlacesEachNoteAfterItsNode() {
        let root = BrainstormNode(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-0000000006A1"
            )!,
            title: "Root",
            children: [
                BrainstormNode(
                    id: UUID(
                        uuidString: "00000000-0000-0000-0000-0000000006A2"
                    )!,
                    title: "Branch",
                    children: [
                        BrainstormNode(
                            id: UUID(
                                uuidString: "00000000-0000-0000-0000-0000000006A3"
                            )!,
                            title: "Noted leaf",
                            note: NodeNote(
                                attachments: [
                                    .youtube(
                                        NoteYouTubeAttachment(
                                            videoID: firstVideoID
                                        )
                                    ),
                                ]
                            )
                        ),
                    ],
                    note: NodeNote(bodyMarkdown: "   ")
                ),
                BrainstormNode(
                    id: UUID(
                        uuidString: "00000000-0000-0000-0000-0000000006A4"
                    )!,
                    title: "Sibling"
                ),
            ],
            note: NodeNote(bodyMarkdown: "Root note")
        )
        let sequence = PresentationSequence(root: root)
        let plan = PresentationNavigationPlan(sequence: sequence)

        #expect(plan.count == 6)
        #expect(plan.steps.map(\.nodeID) == [
            root.id,
            root.id,
            root.children[0].id,
            root.children[0].children[0].id,
            root.children[0].children[0].id,
            root.children[1].id,
        ])
        #expect(plan.steps.map(\.face) == [
            .node,
            .note,
            .node,
            .node,
            .note,
            .node,
        ])
        #expect(plan.index(itemIndex: 0, face: .node) == 0)
        #expect(plan.index(itemIndex: 0, face: .note) == 1)
        #expect(plan.index(itemIndex: 1, face: .note) == nil)
        #expect(Set(plan.steps.map(\.id)).count == plan.count)
    }

    @Test func nativePresentationReverseNavigationRevisitsNoteBeforeNodeTitle() throws {
        let root = BrainstormNode(
            title: "Previous node",
            children: [
                BrainstormNode(title: "Next node"),
            ],
            note: NodeNote(
                bodyMarkdown: "The note remains one reversible step.",
                attachments: [
                    .youtube(
                        NoteYouTubeAttachment(videoID: firstVideoID)
                    ),
                    .youtube(
                        NoteYouTubeAttachment(videoID: secondVideoID)
                    ),
                ]
            )
        )
        let plan = PresentationNavigationPlan(
            sequence: PresentationSequence(root: root)
        )
        let nextNodeIndex = try #require(
            plan.steps.firstIndex { $0.nodeID == root.children[0].id }
        )
        let reverseSteps = [
            plan[nextNodeIndex - 1],
            plan[nextNodeIndex - 2],
        ]

        #expect(plan.count == 3)
        #expect(reverseSteps.map(\.nodeID) == [root.id, root.id])
        #expect(reverseSteps.map(\.face) == [.note, .node])
        #expect(plan.steps.filter { $0.nodeID == root.id }.count == 2)
    }

    @Test func nativePresentationStartsOnSelectedNodeTitleWithinFullSequence() {
        let selected = BrainstormNode(
            title: "Selected branch",
            note: NodeNote(bodyMarkdown: "Selected note")
        )
        let following = BrainstormNode(title: "Following branch")
        let root = BrainstormNode(
            title: "Root",
            children: [selected, following],
            note: NodeNote(bodyMarkdown: "Root note")
        )
        let plan = PresentationNavigationPlan(
            sequence: PresentationSequence(root: root)
        )
        let startIndex = plan.initialNodeStepIndex(for: selected.id)

        #expect(plan.count == 5)
        #expect(plan[startIndex].nodeID == selected.id)
        #expect(plan[startIndex].face == .node)
        #expect(plan[startIndex - 1].nodeID == root.id)
        #expect(plan[startIndex - 1].face == .note)
        #expect(plan[startIndex + 1].nodeID == selected.id)
        #expect(plan[startIndex + 1].face == .note)
        #expect(plan.steps.last?.nodeID == following.id)
        #expect(plan.initialNodeStepIndex(for: nil) == 0)
        #expect(plan.initialNodeStepIndex(for: UUID()) == 0)
    }

    @Test func nativePresentationVisibleNeighborClickTargetsNodeTitle() throws {
        let root = BrainstormNode(
            title: "Noted root",
            children: [
                BrainstormNode(
                    title: "Noted child",
                    note: NodeNote(bodyMarkdown: "Child note")
                ),
                BrainstormNode(title: "Following sibling"),
            ],
            note: NodeNote(bodyMarkdown: "Root note")
        )
        let plan = PresentationNavigationPlan(
            sequence: PresentationSequence(root: root)
        )

        let rootNodeStep = try #require(
            plan.index(itemIndex: 0, face: .node)
        )
        let rootNoteStep = try #require(
            plan.index(itemIndex: 0, face: .note)
        )
        let childNodeStep = try #require(
            plan.index(itemIndex: 1, face: .node)
        )
        let childNoteStep = try #require(
            plan.index(itemIndex: 1, face: .note)
        )
        let siblingNodeStep = try #require(
            plan.index(itemIndex: 2, face: .node)
        )

        #expect(rootNodeStep == 0)
        #expect(rootNoteStep == 1)
        #expect(childNodeStep == 2)
        #expect(childNoteStep == 3)
        #expect(siblingNodeStep == 4)

        #expect(
            plan.nodeStepIndex(
                forAdjacentItem: 1,
                relativeTo: 0
            ) == childNodeStep
        )
        #expect(
            plan.nodeStepIndex(
                forAdjacentItem: 0,
                relativeTo: 1
            ) == rootNodeStep
        )
        #expect(
            plan.nodeStepIndex(
                forAdjacentItem: 2,
                relativeTo: 1
            ) == siblingNodeStep
        )
        #expect(
            plan.nodeStepIndex(
                forAdjacentItem: 2,
                relativeTo: 0
            ) == nil
        )

        #expect(plan[rootNodeStep + 1].face == .note)
        #expect(plan[childNodeStep + 1].face == .note)
        #expect(plan[siblingNodeStep - 1].face == .note)
    }

    @Test func nativePresentationTransformsWholeNodesOnTheCameraTimeline() {
        #expect(
            PresentationNodeAnimationPolicy.surfaceScale(
                cameraZoom: 2.25,
                focusedRenderScale: 4.5
            ) == 0.5
        )
        #expect(
            !PresentationNodeAnimationPolicy.shouldPixelAlign(
                isNavigating: true
            )
        )
        #expect(
            PresentationNodeAnimationPolicy.shouldPixelAlign(
                isNavigating: false
            )
        )
        #expect(
            PresentationNodeAnimationPolicy.screenPoint(
                for: CGPoint(x: 20, y: 30),
                viewportCenter: CGPoint(x: 100, y: 100),
                cameraCenter: CGPoint(x: 10, y: 15),
                zoom: 2
            ) == CGPoint(x: 120, y: 130)
        )
    }

    @Test func presentationNeighborZoomKeepsBothSequentialPeeksWhenFeasible() {
        let previousID = UUID()
        let currentID = UUID()
        let nextID = UUID()
        let nodes = [
            PresentationNeighborZoomPolicy.Node(
                id: previousID,
                parentID: nil,
                siblingIndex: 0,
                frame: CGRect(x: -160, y: -20, width: 60, height: 40)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: currentID,
                parentID: nil,
                siblingIndex: 1,
                frame: CGRect(x: -40, y: -20, width: 80, height: 40)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: nextID,
                parentID: nil,
                siblingIndex: 2,
                frame: CGRect(x: 100, y: -20, width: 60, height: 40)
            ),
        ]
        let viewport = CGSize(width: 1_000, height: 700)
        let zoom = PresentationNeighborZoomPolicy.magnification(
            base: 6,
            currentID: currentID,
            nodes: nodes,
            viewportSize: viewport,
            controlsAtBottom: false
        )
        let safeRect = PresentationNeighborZoomPolicy.safeRect(
            viewportSize: viewport,
            controlsAtBottom: false
        )

        #expect(abs(zoom - 4.79) < 0.0001)
        #expect(abs((viewport.width / 2 - 100 * zoom) - safeRect.minX) < 0.001)
        #expect(abs((viewport.width / 2 + 100 * zoom) - safeRect.maxX) < 0.001)
    }

    @Test func presentationNeighborZoomChoosesOneRealCandidateAboveItsFloor() {
        let previousID = UUID()
        let currentID = UUID()
        let nextID = UUID()
        let parentID = UUID()
        let nodes = [
            PresentationNeighborZoomPolicy.Node(
                id: previousID,
                parentID: nil,
                siblingIndex: 0,
                frame: CGRect(x: -500, y: -20, width: 60, height: 40)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: currentID,
                parentID: parentID,
                siblingIndex: 0,
                frame: CGRect(x: -40, y: -20, width: 80, height: 40)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: nextID,
                parentID: nil,
                siblingIndex: 0,
                frame: CGRect(x: 500, y: -20, width: 60, height: 40)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: parentID,
                parentID: nil,
                siblingIndex: 0,
                frame: CGRect(x: 100, y: -20, width: 60, height: 40)
            ),
        ]
        let zoom = PresentationNeighborZoomPolicy.magnification(
            base: 6,
            currentID: currentID,
            nodes: nodes,
            viewportSize: CGSize(width: 1_000, height: 700),
            controlsAtBottom: false
        )

        #expect(abs(zoom - 4.79) < 0.0001)
    }

    @Test func presentationNeighborZoomUsesRestrainedFloorForRemoteGeometry() {
        let currentID = UUID()
        let remoteID = UUID()
        let zoom = PresentationNeighborZoomPolicy.magnification(
            base: 6,
            currentID: currentID,
            nodes: [
                PresentationNeighborZoomPolicy.Node(
                    id: currentID,
                    parentID: nil,
                    siblingIndex: 0,
                    frame: CGRect(x: -40, y: -20, width: 80, height: 40)
                ),
                PresentationNeighborZoomPolicy.Node(
                    id: remoteID,
                    parentID: currentID,
                    siblingIndex: 0,
                    frame: CGRect(x: 2_000, y: 2_000, width: 80, height: 40)
                ),
            ],
            viewportSize: CGSize(width: 1_000, height: 700),
            controlsAtBottom: false
        )

        #expect(abs(zoom - 4.08) < 0.0001)
    }

    @Test func presentationSafeRectMovesItsControlClearanceOnCompactHTML() {
        let viewport = CGSize(width: 400, height: 800)
        let topControls = PresentationNeighborZoomPolicy.safeRect(
            viewportSize: viewport,
            controlsAtBottom: false
        )
        let bottomControls = PresentationNeighborZoomPolicy.safeRect(
            viewportSize: viewport,
            controlsAtBottom: true
        )

        #expect(topControls == CGRect(x: 16, y: 64, width: 368, height: 720))
        #expect(bottomControls == CGRect(x: 16, y: 16, width: 368, height: 720))
    }

    @Test func presentationTraversalRoutesThroughEveryHierarchyDirection() throws {
        let rootID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000611"
        )!
        let firstBranchID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000612"
        )!
        let middleID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000613"
        )!
        let deepID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000614"
        )!
        let secondBranchID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000615"
        )!
        let secondLeafID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000616"
        )!
        let root = BrainstormNode(
            id: rootID,
            title: "Root",
            children: [
                BrainstormNode(
                    id: firstBranchID,
                    title: "First branch",
                    children: [
                        BrainstormNode(
                            id: middleID,
                            title: "Middle",
                            children: [
                                BrainstormNode(id: deepID, title: "Deep"),
                            ]
                        ),
                    ]
                ),
                BrainstormNode(
                    id: secondBranchID,
                    title: "Second branch",
                    children: [
                        BrainstormNode(id: secondLeafID, title: "Second leaf"),
                    ]
                ),
            ]
        )
        let sequence = PresentationSequence(root: root)

        let descendant = try #require(sequence.traversalRoute(
            from: rootID,
            to: deepID
        ))
        #expect(
            descendant.nodeIDs
                == [rootID, firstBranchID, middleID, deepID]
        )
        #expect(descendant.relationship == .child(levels: 3))

        let ancestor = try #require(sequence.traversalRoute(
            from: deepID,
            to: rootID
        ))
        #expect(
            ancestor.nodeIDs
                == [deepID, middleID, firstBranchID, rootID]
        )
        #expect(ancestor.relationship == .parent(levels: 3))

        let sibling = try #require(sequence.traversalRoute(
            from: firstBranchID,
            to: secondBranchID
        ))
        #expect(
            sibling.nodeIDs == [firstBranchID, rootID, secondBranchID]
        )
        #expect(sibling.relationship == .sibling(parentID: rootID))

        let branchJump = try #require(sequence.traversalRoute(
            from: deepID,
            to: secondLeafID
        ))
        #expect(
            branchJump.nodeIDs
                == [
                    deepID,
                    middleID,
                    firstBranchID,
                    rootID,
                    secondBranchID,
                    secondLeafID,
                ]
        )
        #expect(branchJump.relationship == .branchJump(
            lowestCommonAncestorID: rootID,
            ascendingLevels: 3,
            descendingLevels: 2
        ))
        #expect(branchJump.points == nil)
        #expect(!branchJump.hasCompleteSpatialPath)

        let reverse = try #require(sequence.traversalRoute(
            from: secondLeafID,
            to: deepID
        ))
        #expect(reverse.nodeIDs == branchJump.nodeIDs.reversed())
        #expect(reverse.relationship == .branchJump(
            lowestCommonAncestorID: rootID,
            ascendingLevels: 2,
            descendingLevels: 3
        ))
        #expect(sequence.traversalRoute(from: rootID, to: rootID) == nil)
        #expect(sequence.traversalRoute(from: UUID(), to: rootID) == nil)
        #expect(sequence.traversalRoute(from: -1, to: 0) == nil)
    }

    @Test func presentationTraversalPointsUseCompleteLayoutCenters() throws {
        let rootID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000621"
        )!
        let branchID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000622"
        )!
        let deepID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000623"
        )!
        let siblingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000624"
        )!
        let root = BrainstormNode(
            id: rootID,
            title: "Root",
            children: [
                BrainstormNode(
                    id: branchID,
                    title: "Collapsed",
                    isExpanded: false,
                    children: [
                        BrainstormNode(
                            id: deepID,
                            title: "Deep",
                            offsetX: 24,
                            offsetY: -13
                        ),
                    ],
                    offsetX: -7,
                    offsetY: 19
                ),
                BrainstormNode(id: siblingID, title: "Sibling"),
            ]
        )
        let layout = LayoutEngine().layout(
            root: root,
            placementPolicy: .allDescendants
        )
        let frames = Dictionary(
            uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) }
        )
        let sequence = PresentationSequence(root: root, layout: layout)
        let route = try #require(sequence.traversalRoute(
            from: deepID,
            to: siblingID
        ))
        let expectedPoints = route.nodeIDs.compactMap { id in
            frames[id].map { frame in
                CGPoint(x: frame.midX, y: frame.midY)
            }
        }

        #expect(route.nodeIDs == [deepID, branchID, rootID, siblingID])
        #expect(route.points == expectedPoints)
        #expect(route.hasCompleteSpatialPath)
        #expect(sequence.layoutFrame(for: deepID) == frames[deepID])
        #expect(sequence.layoutCenter(for: deepID) == expectedPoints.first)
        #expect(sequence[sequence.index(of: deepID)!].layoutFrame == frames[deepID])
        #expect(
            sequence[sequence.index(of: deepID)!].layoutCenter
                == expectedPoints.first
        )
    }

    @Test func markdownLinksIncludedNotesAndOmitsPrivatePayloads() throws {
        let root = exportFixture()
        let rootNotePath =
            "notes/export-root--00000000-0000-0000-0000-000000000501.md"
        let childNotePath =
            "notes/hidden-child--00000000-0000-0000-0000-000000000502.md"

        let visible = BrainstormTextExporter.string(
            root: root,
            format: .markdown,
            options: BrainstormExportOptions(noteInclusion: .visible)
        )
        #expect(visible.contains("Export root — [Note](\(rootNotePath))"))
        #expect(visible.contains("    - Hidden child"))
        #expect(!visible.contains("<details"))
        #expect(!visible.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(!visible.contains(firstVideoID))
        #expect(!visible.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(!visible.contains(secondVideoID))

        let visibleBundle = try BrainstormMarkdownBundle.make(
            root: root,
            inclusion: .visible
        )
        #expect(visibleBundle.noteFileCount == 1)
        #expect(visibleBundle.isArchive)
        let visibleEntries = Dictionary(
            uniqueKeysWithValues: visibleBundle.entries.map {
                ($0.path, $0.data)
            }
        )
        #expect(Set(visibleEntries.keys) == ["map.md", rootNotePath])
        let visibleNote = String(
            decoding: try #require(visibleEntries[rootNotePath]),
            as: UTF8.self
        )
        #expect(visibleNote.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(visibleNote.contains(firstVideoID))
        #expect(!visibleNote.contains("PRIVATE-NOTE-TOKEN-9B"))
        let visibleArchive = try BrainstormExporter.data(
            root: root,
            theme: .system,
            colorScheme: .light,
            format: .markdown,
            options: BrainstormExportOptions(noteInclusion: .visible)
        )
        let exportedVisibleEntries = try storedZIPEntries(visibleArchive)
        #expect(Set(exportedVisibleEntries.keys) == ["map.md", rootNotePath])
        #expect(exportedVisibleEntries.values.allSatisfy {
            !String(decoding: $0, as: UTF8.self)
                .contains("PRIVATE-NOTE-TOKEN-9B")
        })

        let all = BrainstormTextExporter.string(
            root: root,
            format: .markdown,
            options: BrainstormExportOptions(noteInclusion: .all)
        )
        #expect(all.contains("Export root — [Note](\(rootNotePath))"))
        #expect(all.contains("Hidden child — [Note](\(childNotePath))"))
        #expect(!all.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(!all.contains("PRIVATE-NOTE-TOKEN-9B"))

        let allBundle = try BrainstormMarkdownBundle.make(
            root: root,
            inclusion: .all
        )
        #expect(allBundle.noteFileCount == 2)
        let allEntries = Dictionary(
            uniqueKeysWithValues: allBundle.entries.map {
                ($0.path, $0.data)
            }
        )
        #expect(
            Set(allEntries.keys)
                == ["map.md", rootNotePath, childNotePath]
        )
        let hiddenNote = String(
            decoding: try #require(allEntries[childNotePath]),
            as: UTF8.self
        )
        #expect(hiddenNote.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(hiddenNote.contains(secondVideoID))

        let none = BrainstormTextExporter.string(
            root: root,
            format: .markdown,
            options: BrainstormExportOptions(noteInclusion: .none)
        )
        #expect(!none.contains("<details"))
        #expect(!none.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(!none.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(!none.contains(firstVideoID))
        #expect(!none.contains(secondVideoID))

        let noneBundle = try BrainstormMarkdownBundle.make(
            root: root,
            inclusion: .none
        )
        #expect(noneBundle.noteFileCount == 0)
        #expect(!noneBundle.isArchive)
        #expect(noneBundle.entries.map(\.path) == ["map.md"])
    }

    @Test func markdownBundleExtractsImagesAndProducesDeterministicZIP() throws {
        let rootID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000601"
        )!
        let childID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000602"
        )!
        let imageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000603"
        )!
        let pngData = Data([
            137, 80, 78, 71, 13, 10, 26, 10,
            0, 0, 0, 0,
        ])
        let root = BrainstormNode(
            id: rootID,
            title: "../ Résumé / Plan",
            children: [
                BrainstormNode(
                    id: childID,
                    title: "../ Résumé / Plan",
                    note: NodeNote(bodyMarkdown: "Child **context**")
                ),
            ],
            note: NodeNote(
                bodyMarkdown: "Root _context_",
                attachments: [
                    .image(
                        NoteImageAttachment(
                            id: imageID,
                            pngBase64: pngData.base64EncodedString(),
                            pixelWidth: 1,
                            pixelHeight: 1,
                            altText: "A [safe] image",
                            caption: "Image *caption*"
                        )
                    ),
                    .youtube(
                        NoteYouTubeAttachment(
                            id: UUID(
                                uuidString:
                                    "00000000-0000-0000-0000-000000000604"
                            )!,
                            videoID: firstVideoID,
                            startSeconds: 42,
                            caption: "Walkthrough"
                        )
                    ),
                ]
            )
        )
        let options = BrainstormExportOptions(noteInclusion: .all)
        let bundle = try BrainstormMarkdownBundle.make(
            root: root,
            inclusion: .all
        )
        let rootStem =
            "resume-plan--00000000-0000-0000-0000-000000000601"
        let childStem =
            "resume-plan--00000000-0000-0000-0000-000000000602"
        let rootNotePath = "notes/\(rootStem).md"
        let childNotePath = "notes/\(childStem).md"
        let assetPath =
            "assets/\(rootStem)--00000000-0000-0000-0000-000000000603.png"
        let expectedPaths = [
            "map.md",
            rootNotePath,
            childNotePath,
            assetPath,
        ]
        #expect(bundle.entries.map(\.path) == expectedPaths)
        #expect(bundle.entries.allSatisfy { !$0.path.contains("..") })
        #expect(bundle.entries.allSatisfy {
            $0.path.utf8.allSatisfy { $0 < 128 }
        })

        let entries = Dictionary(
            uniqueKeysWithValues: bundle.entries.map { ($0.path, $0.data) }
        )
        let map = String(
            decoding: try #require(entries["map.md"]),
            as: UTF8.self
        )
        #expect(map.contains("../ Résumé / Plan — [Note](\(rootNotePath))"))
        #expect(map.contains("../ Résumé / Plan — [Note](\(childNotePath))"))
        #expect(!map.contains("Root _context_"))
        let rootNote = String(
            decoding: try #require(entries[rootNotePath]),
            as: UTF8.self
        )
        #expect(rootNote.contains("Root _context_"))
        #expect(rootNote.contains(
            "![A \\[safe\\] image](../\(assetPath))"
        ))
        #expect(rootNote.contains("*Image \\*caption\\**"))
        #expect(rootNote.contains(
            "[Walkthrough](https://youtu.be/\(firstVideoID)?t=42)"
        ))
        #expect(entries[assetPath] == pngData)

        let descriptor = BrainstormExporter.descriptor(
            root: root,
            format: .markdown,
            options: options
        )
        #expect(descriptor.fileExtension == "zip")
        #expect(descriptor.contentType == .zip)
        #expect(descriptor.isArchive)

        let firstArchive = try BrainstormExporter.data(
            root: root,
            theme: .system,
            colorScheme: .light,
            format: .markdown,
            options: options
        )
        let secondArchive = try BrainstormExporter.data(
            root: root,
            theme: .system,
            colorScheme: .light,
            format: .markdown,
            options: options
        )
        #expect(firstArchive == secondArchive)
        #expect(Array(firstArchive.prefix(4)) == [80, 75, 3, 4])
        #expect(try storedZIPEntries(firstArchive) == entries)
    }

    @Test func markdownWithoutIncludedNotesRemainsOneMarkdownFile() throws {
        let root = exportFixture()
        let options = BrainstormExportOptions(noteInclusion: .none)
        let descriptor = BrainstormExporter.descriptor(
            root: root,
            format: .markdown,
            options: options
        )
        #expect(descriptor.fileExtension == "md")
        #expect(!descriptor.isArchive)

        let data = try BrainstormExporter.data(
            root: root,
            theme: .system,
            colorScheme: .light,
            format: .markdown,
            options: options
        )
        let markdown = String(decoding: data, as: UTF8.self)
        #expect(markdown.hasPrefix("# Export root\n\n"))
        #expect(markdown.contains("- Export root"))
        #expect(markdown.contains("    - Hidden child"))
        #expect(!markdown.contains("notes/"))
        #expect(!data.starts(with: Data([80, 75, 3, 4])))
    }

    @Test func htmlEscapesNotesAndLoadsOnlyTheActivePresentationPlayer() throws {
        let hostileBody = #"""
        Before <script id="evil">alert("x")</script> & **safe**
        """#
        let root = BrainstormNode(
            id: UUID(),
            title: #"Root <script data-root="yes">"#,
            note: NodeNote(
                bodyMarkdown: hostileBody,
                attachments: [
                    .youtube(
                        NoteYouTubeAttachment(
                            videoID: firstVideoID,
                            startSeconds: 90,
                            caption: #"<img src=x onerror="alert(1)">"#
                        )
                    ),
                ]
            )
        )

        let html = try htmlString(
            root: root,
            options: BrainstormExportOptions(noteInclusion: .all)
        )
        #expect(html.contains("&lt;script id=&quot;evil&quot;&gt;"))
        #expect(html.contains("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"))
        #expect(html.contains("<strong>safe</strong>"))
        #expect(!html.contains(#"<script id="evil">"#))
        #expect(!html.contains(#"<img src=x onerror="alert(1)">"#))
        #expect(html.contains("data-youtube-play"))
        #expect(html.contains("data-youtube-host"))
        #expect(html.contains(#"data-auto-load="true""#))
        #expect(html.contains(#"data-has-note="true""#))
        #expect(html.contains(#"data-face="node""#))
        #expect(html.contains(#"class="presentation-note-back""#))
        #expect(html.contains(#"class="presentation-note-indicator""#))
        #expect(!html.contains(#"id="notes-button""#))
        #expect(!html.contains("notesLayerVisible"))
        #expect(!html.contains("applyMapNoteVisibility"))
        #expect(html.contains(#".node[data-has-note="true"]"#))
        #expect(html.contains("const openMapNodeNote = node =>"))
        #expect(html.contains("openMapNodeNote(nodeActivation.node);"))
        #expect(html.contains("openMapNodeNote(mapNoteNode);"))
        #expect(!html.contains("data-presentation-note-toggle"))
        #expect(
            html.contains(
                #"class="note-sticker-icon icon-tabler icon-tabler-note""#
            )
        )
        #expect(html.contains("icon-tabler-note"))
        #expect(
            html.contains(
                #"d="M5 3h9l7 7v9a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z""#
            )
        )
        #expect(html.contains(#"class="note-detail-line""#))
        #expect(html.contains("width: 26px"))
        #expect(html.contains("height: 26px"))
        #expect(html.contains("color: var(--accent)"))
        #expect(html.contains("transition: transform 640ms"))
        #expect(html.contains("@media (prefers-reduced-motion: reduce)"))
        #expect(html.contains("transition: opacity 120ms linear"))
        #expect(html.contains("transform: none !important;"))
        #expect(html.contains(#"slide.dataset.face === "note""#))
        #expect(html.contains(#"resetPresentationFaces();"#))
        #expect(!html.contains(#"aria-label="Show note for "#))
        #expect(!html.contains(#"aria-label="Show node""#))
        #expect(
            html.contains(
                "let presentationStepCount = 0;"
            )
        )
        #expect(html.contains("const presentationStepOffsets = [];"))
        #expect(
            html.contains(
                #"source.dataset.face === "node""#
            )
        )
        #expect(html.contains(#"source.dataset.face === "note""#))
        #expect(html.contains(#"parameters.get("face") === "note""#))
        #expect(html.contains("of ${presentationStepCount}"))
        #expect(
            !html.contains(
                #"notesButton.textContent = showsNote ? "Show node" : "Show note""#
            )
        )
        #expect(html.contains("data-video-id=\"\(firstVideoID)\""))
        #expect(html.contains("https://www.youtube-nocookie.com/embed/"))
        #expect(html.contains("frame-src https://www.youtube-nocookie.com"))
        #expect(html.contains("Playback requires network access."))
        #expect(html.contains(".youtube-host[hidden] { display: none; }"))
        #expect(html.contains("min-height: 200px;"))
        #expect(html.contains(#"location.protocol === "http:""#))
        #expect(html.contains(#"location.protocol === "https:""#))
        #expect(html.contains("!supportsEmbeddedYouTube"))
        #expect(html.contains(">Open on YouTube</a>"))
        #expect(!html.contains("<iframe"))
        #expect(html.contains("document.createElement(\"iframe\")"))
        #expect(html.contains("const syncPresentationYouTubePlayers"))
        #expect(html.contains("const resetYouTube"))
        #expect(html.contains(#"iframe.src = "about:blank";"#))
        #expect(html.contains("loadYouTube(host, false);"))
        #expect(!html.contains("script-src 'unsafe-inline'"))
        #expect(!html.contains("__BRAINSTORM_SCRIPT_SHA256__"))

        let scriptStart = try #require(html.range(of: "<script>"))
        let scriptEnd = try #require(
            html.range(
                of: "</script>",
                range: scriptStart.upperBound..<html.endIndex
            )
        )
        let script = html[scriptStart.upperBound..<scriptEnd.lowerBound]
        let scriptHash = Data(SHA256.hash(data: Data(script.utf8)))
            .base64EncodedString()
        #expect(html.contains("script-src 'sha256-\(scriptHash)'"))
        #expect(html.contains("const parameters = new URLSearchParams("))
        #expect(html.contains(#"const nodeID = parameters.get("node");"#))
        #expect(
            html.contains(
                "A malformed shared hash must not prevent the viewer from"
            )
        )
    }

    @Test func htmlPresentationIsDepthFirstEvenThroughCollapsedBranches() throws {
        let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let branchID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let deepID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
        let siblingID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!
        let root = BrainstormNode(
            id: rootID,
            title: "Root",
            children: [
                BrainstormNode(
                    id: branchID,
                    title: "Collapsed branch",
                    isExpanded: false,
                    children: [
                        BrainstormNode(id: deepID, title: "Deep descendant"),
                    ]
                ),
                BrainstormNode(id: siblingID, title: "Next branch"),
            ]
        )

        let html = try htmlString(
            root: root,
            options: BrainstormExportOptions(
                noteInclusion: .none,
                htmlInitialMode: .presentation
            )
        )
        let presentation = try #require(html.range(of: #"id="presentation-stage""#))
        let slides = String(html[presentation.lowerBound...])
        let positions = try [rootID, branchID, deepID, siblingID].map { id in
            try #require(
                slides.range(of: #"data-node-id="\#(id.uuidString)""#)?.lowerBound
            )
        }
        #expect(
            positions[0] < positions[1]
                && positions[1] < positions[2]
                && positions[2] < positions[3]
        )
        #expect(slides.contains(#"data-node-id="\#(deepID.uuidString)""#))
        #expect(html.contains(#"let currentMode = "presentation";"#))
        let viewportTag = try openingTag(named: "main", id: "viewport", in: html)
        let presentationTag = try openingTag(
            named: "main",
            id: "presentation",
            in: html
        )
        #expect(viewportTag.contains("hidden"))
        #expect(!presentationTag.contains("hidden"))
        #expect(
            try openingTag(named: "button", id: "map-mode-button", in: html)
                .contains(#"aria-pressed="false""#)
        )
        #expect(
            try openingTag(
                named: "button",
                id: "presentation-mode-button",
                in: html
            ).contains(#"aria-pressed="true""#)
        )
        #expect(html.contains(#"data-position="previous""#))
        #expect(html.contains(#"data-position="next""#))
        #expect(html.contains(#"data-position="context""#))
        #expect(html.contains(#"data-slide-title="Next branch""#))
        #expect(html.contains(#"data-map-x=""#))
        #expect(html.contains(#"data-map-y=""#))
        #expect(html.contains(#"data-map-width=""#))
        #expect(html.contains(#"data-map-height=""#))
        #expect(html.contains(#"data-base-font-size=""#))
        #expect(html.contains(#"data-base-line-height=""#))
        #expect(html.contains(#"data-parent-id="\#(rootID.uuidString)""#))
        #expect(html.contains(#"data-sibling-index="0""#))
        #expect(html.contains(#"data-next-route=""#))
        #expect(html.contains(#"data-next-route-pivot=""#))
        #expect(html.contains(#"data-previous-route-pivot=""#))
        #expect(html.contains("const updatePresentationSpatialPositions"))
        #expect(html.contains("const travelCamera"))
        #expect(html.contains("const presentationWorldTransform"))
        #expect(html.contains("const presentationSafeRect"))
        #expect(html.contains("const presentationPeekCap"))
        #expect(html.contains("const presentationNeighborCandidates"))
        #expect(html.contains("const syncPresentationRenderScale"))
        #expect(
            html.contains(
                "const renderScale = presentationScaleFor(slide);"
            )
        )
        #expect(
            html.contains(
                "--presentation-travel-duration"
            )
        )
        #expect(html.contains("--rendered-slide-font-size"))
        #expect(
            html.contains(
                "var(--rendered-slide-line-height, var(--slide-line-height));"
            )
        )
        #expect(
            html.contains(
                #"slide.style.transform ="#
            )
        )
        #expect(
            html.contains(
                #"`scale(${1 / renderScale}) translate(-50%, -50%)`"#
            )
        )
        #expect(
            html.contains(
                "(max-width: 640px), (max-aspect-ratio: 4 / 5),"
            )
        )
        #expect(
            html.contains(
                "(max-height: 520px) and (orientation: landscape)"
            )
        )
        #expect(html.contains("const availableWidth = Math.max(1, safe.maxX - safe.minX);"))
        #expect(html.contains("const availableHeight = Math.max(1, safe.maxY - safe.minY);"))
        #expect(html.contains("availableWidth * 0.72 / width"))
        #expect(html.contains("availableHeight * 0.62 / height"))
        #expect(html.contains("const minimumFocusedScaleRatio ="))
        #expect(html.contains("0.68;"))
        #expect(html.contains("const floor = Math.min("))
        #expect(
            html.contains(
                "sequentialCaps.length === sequential.length"
            )
        )
        #expect(
            html.contains(
                "sequentialCaps.every(cap => cap >= floor)"
            )
        )
        #expect(
            html.contains(
                "return Math.min(base, Math.min(...sequentialCaps));"
            )
        )
        #expect(
            html.contains(
                #"item => item.candidate && item.kind !== "branch""#
            )
        )
        #expect(html.contains("kind: slide.dataset.nextRelationKind"))
        #expect(html.contains("kind: slide.dataset.previousRelationKind"))
        #expect(html.contains("cap >= floor"))
        #expect(html.contains("return Math.min(base, bestCap ?? floor);"))
        #expect(html.contains("const navigatePresentationTo"))
        #expect(html.contains("const smoothBranchRoute"))
        #expect(
            html.contains(
                "const cameraRoute = smoothBranchRoute(route, routePivot);"
            )
        )
        #expect(
            html.contains(
                ".presentation-slide[data-position=\"context\"]"
            )
        )
        #expect(html.contains("pointer-events: auto;"))
        #expect(html.contains("--presentation-note-marker-size"))
        #expect(html.contains("--presentation-note-marker-inset"))
        #expect(html.contains("focusedNodeHeight * 0.16"))
        #expect(!html.contains("marker-end"))
        #expect(!html.contains("stroke-dasharray"))
        #expect(html.contains(#"`Previous slide: ${title}. ${relation || ""}`"#))
        #expect(html.contains(#"`Next slide: ${title}. ${relation || ""}`"#))
        #expect(html.contains(#"id="presentation-world""#))
        #expect(html.contains(#"id="presentation-world-branches""#))
        #expect(html.contains(#"id="presentation-previous-button""#))
        #expect(html.contains(#"id="presentation-next-button""#))
        #expect(html.contains(#"aria-label="Previous presentation step""#))
        #expect(html.contains(#"aria-label="Next presentation step""#))
        #expect(html.contains(".presentation-edge-navigation[hidden]"))
        #expect(html.contains("width: 52px"))
        #expect(html.contains("height: 52px"))
        #expect(
            html.contains(
                "left: max(8px, env(safe-area-inset-left));"
            )
        )
        #expect(
            html.contains(
                "right: max(8px, env(safe-area-inset-right));"
            )
        )
        #expect(html.contains("const syncPresentationEdgeNavigation"))
        #expect(
            html.contains(
                "stepIndex >= presentationStepCount - 1"
            )
        )
        #expect(html.contains("syncPresentationEdgeNavigation();"))
        #expect(
            html.contains(
                #"() => navigatePresentation(-1)"#
            )
        )
        #expect(
            html.contains(
                #"() => navigatePresentation(1)"#
            )
        )
        #expect(!html.contains("translate3d("))
        #expect(
            html.contains(
                #"return `translate(${x}px, ${y}px) scale(${worldScale})`;"#
            )
        )
        #expect(html.contains("Math.round(value * pixelRatio) / pixelRatio"))
        #expect(
            html.contains(
                "transform: perspective(720px) rotateY(180deg);"
            )
        )
        #expect(!html.contains("perspective: 720px;"))
        #expect(
            html.contains(
                #"presentationWorld.style.willChange = "auto";"#
            )
        )
        #expect(html.contains("const setCameraFrame"))
        #expect(html.contains("const presentationOverviewScale"))
        #expect(html.contains("const presentationCameraFrames"))
        #expect(html.contains("const stepCameraAnimation"))
        #expect(
            html.contains(
                "requestAnimationFrame(stepCameraAnimation)"
            )
        )
        #expect(
            html.contains("if (reducedMotion.matches) return 180;"),
            "Reduced Motion should use a short direct camera transition."
        )
        #expect(
            !html.contains(
                """
                if (reducedMotion.matches) {
                  settleCameraFrame(destination, destinationScale);
                """
            ),
            "Node navigation must not regress to an immediate camera jump."
        )
        #expect(!html.contains("presentationWorld.animate("))
        #expect(!html.contains("presentationResizeObserver"))
        #expect(
            html.contains(
                #"data-edge-to="\#(deepID.uuidString)""#
            ),
            "The presentation world must include connections for collapsed descendants."
        )
        #expect(html.contains(#"data-next-relation-kind="branch""#))
        #expect(html.contains("Next branch · via Root"))
        #expect(html.contains("const updatePresentationConnections"))
        #expect(html.contains("overflow: clip;"))
        #expect(html.contains("class=\"presentation-node-front"))
        #expect(html.contains("class=\"presentation-node-shape\""))
        #expect(html.contains("class=\"presentation-node-selection\""))
        #expect(html.contains(#"data-has-note="false""#))
        #expect(!html.contains("class=\"presentation-note-back\""))
        #expect(!html.contains("class=\"presentation-flip\""))
        #expect(!html.contains("width: min(760px, 72vw)"))
        #expect(html.contains(":focus-visible"))
        #expect(html.contains(#"(event.key === "Enter" || event.key === " ")"#))
        #expect(
            html.contains(
                #"previewTarget.dataset.position === "previous" ? -1 : 1"#
            )
        )
        #expect(html.contains("const updateSlideDescendantFocus"))
        #expect(
            html.contains(
                #"button, a[href], iframe, input, textarea, select, [tabindex]"#
            )
        )
        #expect(html.contains("updateSlideDescendantFocus(slide, isCurrent);"))
        #expect(html.contains(#"presentationStage.addEventListener("pointerdown""#))
        #expect(html.contains(#"navigatePresentation(dx < 0 ? 1 : -1)"#))
        #expect(html.contains(#"if (index === currentSlideIndex)"#))
        #expect(html.contains(#"navigatePresentation(1);"#))
        #expect(html.contains("if (interactiveTarget && !previewTarget) return;"))
        #expect(
            html.components(
                separatedBy: "currentSlide()?.focus({ preventScroll: true });"
            ).count >= 4
        )

        let scaleStart = try #require(
            html.range(of: "const presentationScaleFor = slide =>")
        )
        let scaleEnd = try #require(
            html.range(
                of: "const syncPresentationNoteScale",
                range: scaleStart.upperBound..<html.endIndex
            )
        )
        let scaleSource = html[
            scaleStart.lowerBound..<scaleEnd.lowerBound
        ]
        #expect(!scaleSource.contains("dataset.face"))
    }

    @Test func htmlViewerChromeUsesTheDocumentThemeAccent() throws {
        let data = try BrainstormExporter.data(
            root: BrainstormNode(title: "Theme-aware viewer"),
            theme: .dracula,
            colorScheme: .dark,
            format: .html,
            options: BrainstormExportOptions(
                noteInclusion: .none,
                htmlInitialMode: .presentation
            )
        )
        let html = String(decoding: data, as: UTF8.self)

        #expect(html.contains("--accent: #BD93F9;"))
        #expect(html.contains("stroke=\"#BD93F9\""))
        #expect(html.contains(".brainstorm-attribution-logo-tile {"))
        #expect(html.contains("fill: var(--accent);"))
        #expect(html.contains(".presentation-edge-navigation {"))
        #expect(html.contains("color: var(--accent);"))
    }

    @Test func htmlVisibleAllAndNoneDoNotLeakExcludedPayloads() throws {
        let root = exportFixture()

        let visible = try htmlString(
            root: root,
            options: BrainstormExportOptions(noteInclusion: .visible)
        )
        #expect(visible.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(visible.contains(firstVideoID))
        #expect(!visible.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(!visible.contains(secondVideoID))
        #expect(visible.contains(#"class="map-note-marker""#))
        #expect(visible.contains(#"data-map-note-node-id=""#))
        #expect(visible.contains(#"class="node shape-roundedRect map-node-flippable""#))
        #expect(visible.contains(#"data-has-note="true""#))
        #expect(visible.contains(#"data-face="node""#))
        #expect(
            visible.contains(
                #"data-node-id="00000000-0000-0000-0000-000000000501""#
            )
        )
        #expect(visible.contains(#"tabindex="0""#))
        #expect(visible.contains("Has note. Press Enter to show it."))
        #expect(!visible.contains(#"id="notes-button""#))
        #expect(visible.contains(#"role="img""#))
        #expect(visible.contains(#"aria-label="Has note: "#))
        #expect(
            !visible.contains("<button\n          class=\"map-note-marker\"")
        )
        #expect(visible.contains(#"class="map-node-flip""#))
        #expect(visible.contains(#"class="map-node-note-back""#))
        #expect(visible.contains("data-map-note-close"))
        #expect(
            visible.components(separatedBy: "VISIBLE-NOTE-TOKEN-7A").count == 3,
            "The included note should appear once on the map back and once in presentation."
        )

        let all = try htmlString(
            root: root,
            options: BrainstormExportOptions(noteInclusion: .all)
        )
        #expect(all.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(all.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(all.contains(firstVideoID))
        #expect(all.contains(secondVideoID))
        #expect(all.contains(#"data-saved-visible="false""#))

        let none = try htmlString(
            root: root,
            options: BrainstormExportOptions(noteInclusion: .none)
        )
        #expect(!none.contains("VISIBLE-NOTE-TOKEN-7A"))
        #expect(!none.contains("PRIVATE-NOTE-TOKEN-9B"))
        #expect(!none.contains(firstVideoID))
        #expect(!none.contains(secondVideoID))
        #expect(
            !none.contains(
                #"class="node shape-roundedRect map-node-flippable""#
            )
        )
        #expect(!none.contains(#"class="map-node-note-close""#))
        #expect(
            !none.contains(
                #"data-map-note-node-id="00000000-0000-0000-0000-000000000501""#
            )
        )
        #expect(!none.contains(#"class="map-note-marker""#))
        #expect(
            !none.contains(
                """
                data-has-note="true"
                          data-node-id="00000000-0000-0000-0000-000000000501"
                """
            )
        )
        #expect(!none.contains(#"data-video-id="\#(firstVideoID)""#))
        #expect(!none.contains(#"data-video-id="\#(secondVideoID)""#))
    }

    private func exportFixture() -> BrainstormNode {
        BrainstormNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            title: "Export root",
            children: [
                BrainstormNode(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
                    title: "Hidden child",
                    note: NodeNote(
                        visibility: .hidden,
                        bodyMarkdown: "PRIVATE-NOTE-TOKEN-9B",
                        attachments: [
                            .youtube(
                                NoteYouTubeAttachment(
                                    videoID: secondVideoID,
                                    caption: "Private video"
                                )
                            ),
                        ]
                    )
                ),
            ],
            note: NodeNote(
                bodyMarkdown: "VISIBLE-NOTE-TOKEN-7A",
                attachments: [
                    .youtube(
                        NoteYouTubeAttachment(
                            videoID: firstVideoID,
                            caption: "Visible video"
                        )
                    ),
                ]
            )
        )
    }

    private func htmlString(
        root: BrainstormNode,
        options: BrainstormExportOptions
    ) throws -> String {
        let data = try BrainstormExporter.data(
            root: root,
            theme: .system,
            colorScheme: .light,
            format: .html,
            options: options
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func storedZIPEntries(_ archive: Data) throws -> [String: Data] {
        var offset = 0
        var result: [String: Data] = [:]
        while offset + 4 <= archive.count,
              littleEndianUInt32(archive, at: offset) == 0x0403_4B50
        {
            let compressedSize = Int(
                littleEndianUInt32(archive, at: offset + 18)
            )
            let nameLength = Int(
                littleEndianUInt16(archive, at: offset + 26)
            )
            let extraLength = Int(
                littleEndianUInt16(archive, at: offset + 28)
            )
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= archive.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = try #require(
                String(data: archive[nameStart..<nameEnd], encoding: .utf8)
            )
            result[name] = Data(archive[dataStart..<dataEnd])
            offset = dataEnd
        }
        guard offset + 4 <= archive.count,
              littleEndianUInt32(archive, at: offset) == 0x0201_4B50
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }

    private func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func openingTag(
        named name: String,
        id: String,
        in html: String
    ) throws -> String {
        let idRange = try #require(html.range(of: #"id="\#(id)""#))
        let start = try #require(
            html[..<idRange.lowerBound].range(of: "<\(name)", options: .backwards)
        )
        let end = try #require(
            html.range(of: ">", range: idRange.upperBound..<html.endIndex)
        )
        return String(html[start.lowerBound..<end.upperBound])
    }
}

@MainActor
private final class YouTubeNavigationCapture: NSObject, WKNavigationDelegate {
    private(set) var didObserveYouTubeNavigation = false
    private(set) var referrer: String?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.request.url?.host == "www.youtube-nocookie.com" {
            didObserveYouTubeNavigation = true
            referrer = navigationAction.request.value(
                forHTTPHeaderField: "Referer"
            )
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
