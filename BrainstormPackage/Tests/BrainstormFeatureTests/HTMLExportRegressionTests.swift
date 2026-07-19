import Foundation
import SwiftUI
import Testing
@testable import BrainstormFeature

@Suite("HTML and note export regressions")
@MainActor
struct HTMLExportRegressionTests {
    @Test func overflowingOrderedListFallsBackWithoutTrappingRenderers() {
        let source = """
        \(Int.max). First
        1. Second
        """

        #expect(
            NodeNoteRendering.sanitizedMarkdownBody(source)
                == """
                - First
                - Second
                """
        )

        let height = NodeNoteRendering.measuredHeight(
            note: NodeNote(bodyMarkdown: source),
            width: 320,
            mode: .presentation
        )
        #expect(height.isFinite)
        #expect(height > 0)
    }

    @Test func unsupportedRemoteImageSyntaxStaysLiteralInMarkdownOutput() {
        let source = "![Tracker](https://example.com/pixel.png)"
        let sanitized = NodeNoteRendering.sanitizedMarkdownBody(source)

        #expect(
            sanitized == #"\![Tracker](https://example.com/pixel.png)"#
        )
        #expect(sanitized.hasPrefix(#"\!"#))
    }

    @Test func mobilePresentationSuppressesSwipeClickAndKeepsControlsOffNote() throws {
        let root = BrainstormNode(
            title: "Root",
            children: [BrainstormNode(title: "Child")],
            note: NodeNote(bodyMarkdown: "A compact note")
        )
        let data = try BrainstormExporter.data(
            root: root,
            theme: .dracula,
            colorScheme: .dark,
            format: .html,
            options: BrainstormExportOptions(
                noteInclusion: .visible,
                htmlInitialMode: .presentation
            )
        )
        let html = String(decoding: data, as: UTF8.self)

        #expect(html.contains("let suppressPresentationSlideClickUntil = 0;"))
        #expect(html.contains("suppressPresentationSlideClickUntil ="))
        #expect(html.contains("performance.now() + 450;"))
        #expect(
            html.contains(
                "performance.now() < suppressPresentationSlideClickUntil"
            )
        )
        #expect(
            html.contains(
                "top: max(12px, env(safe-area-inset-top));"
            )
        )
        #expect(
            html.contains(
                "width: min(320px, calc(100vw - 32px));"
            )
        )
        #expect(html.contains("- env(safe-area-inset-top)"))
        #expect(html.contains("#viewport.note-open { touch-action: pan-y; }"))
        #expect(html.contains("viewport.classList.remove(\"note-open\");"))
        let presentationStageRule = html
            .components(separatedBy: "#presentation-stage {")
            .dropFirst()
            .first?
            .components(separatedBy: "}")
            .first
        #expect(
            presentationStageRule?.contains("touch-action: pan-y;") == true
        )
        #expect(html.contains("const slideIndexByElement = new WeakMap();"))
        #expect(html.contains("const slideByNodeID = new Map();"))
        #expect(html.contains("const childrenByParentID = new Map();"))
        #expect(!html.contains("slides.indexOf("))
        #expect(!html.contains("slides.find("))
        #expect(
            html.contains(
                "@media (max-height: 520px) and (orientation: landscape)"
            )
        )
        #expect(html.contains("100dvh"))

        // The regression fixes must not replace the document theme accent
        // used by the presentation edge controls and attribution mark.
        #expect(html.contains("--accent: #BD93F9;"))
        #expect(html.contains("color: var(--accent);"))
        #expect(html.contains("fill: var(--accent);"))
    }
}
