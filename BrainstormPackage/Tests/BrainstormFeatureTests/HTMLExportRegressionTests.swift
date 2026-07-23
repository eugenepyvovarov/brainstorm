import Foundation
import SwiftUI
import Testing
@testable import BrainstormFeature

@Suite("HTML and note export regressions")
@MainActor
struct HTMLExportRegressionTests {
    @Test func htmlExportBaseNameUsesUnderscoresAndStripsSpecialCharacters() {
        #expect(
            BrainstormExporter.sanitizedExportBaseName("My Cool Map!")
                == "My_Cool_Map"
        )
        #expect(
            BrainstormExporter.sanitizedExportBaseName("  Launch / Plan?  ")
                == "Launch_Plan"
        )
        #expect(
            BrainstormExporter.sanitizedExportBaseName("hello-world_v2")
                == "hello-world_v2"
        )
        #expect(BrainstormExporter.sanitizedExportBaseName("   ") == "Untitled")
        #expect(BrainstormExporter.sanitizedExportBaseName("@@@") == "Untitled")
        #expect(
            BrainstormExportOptions.htmlDefault.noteInclusion == .all
        )
        #expect(
            BrainstormExportOptions.htmlDefault.htmlInitialMode == .map
        )
    }

    @Test func htmlViewerTogglesNotesLiveWithoutExportPanelOption() throws {
        let root = BrainstormNode(
            title: "Root",
            children: [
                BrainstormNode(
                    title: "Noted",
                    note: NodeNote(bodyMarkdown: "Live toggle target")
                ),
            ]
        )
        // Even when callers request no notes, HTML embeds them for the viewer.
        let data = try BrainstormExporter.data(
            root: root,
            theme: .dracula,
            colorScheme: .dark,
            format: .html,
            options: BrainstormExportOptions(
                noteInclusion: .none,
                htmlInitialMode: .map
            )
        )
        let html = String(decoding: data, as: UTF8.self)

        #expect(html.contains(#"id="include-notes-checkbox""#))
        #expect(html.contains("class=\"include-notes-toggle\""))
        #expect(html.contains("let notesEnabled = false;"))
        #expect(html.contains("const applyNotesEnabled"))
        #expect(html.contains("const slideHasActiveNote"))
        #expect(html.contains("const rebuildPresentationStepCounts"))
        #expect(html.contains("body.notes-disabled"))
        #expect(html.contains(#"class="notes-disabled""#))
        #expect(html.contains("Live toggle target"))
        #expect(html.contains(#"data-has-note="true""#))
        #expect(!html.contains("Include notes in HTML export"))
    }

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
            presentationStageRule?.contains("touch-action: none;") == true
        )
        #expect(html.contains("const enterPresentationFreeLook"))
        #expect(html.contains("const panPresentationByScreenDelta"))
        #expect(html.contains("const zoomPresentationAtClient"))
        #expect(html.contains("const refocusPresentationOnCurrent"))
        #expect(
            html.contains(
                "Any visible node is a jump target so free-look pan/zoom can"
            )
        )
        #expect(!html.contains("presentationSwipe"))
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
        #expect(html.contains("#presentation-progress {"))
        #expect(html.contains("white-space: nowrap;"))
        #expect(!html.contains("min-width: 3.6em;"))

        // The regression fixes must not replace the document theme accent
        // used by the presentation edge controls and attribution mark.
        #expect(html.contains("--accent: #BD93F9;"))
        #expect(html.contains("color: var(--accent);"))
        #expect(html.contains("fill: var(--accent);"))
    }

    @Test func deepSiblingRoutesTravelDirectlyWithoutParentDetour() throws {
        let leftID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let rightID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let root = BrainstormNode(
            title: "Root",
            children: [
                BrainstormNode(
                    title: "Branch",
                    children: [
                        BrainstormNode(
                            title: "Parent",
                            children: [
                                BrainstormNode(id: leftID, title: "Deep left"),
                                BrainstormNode(id: rightID, title: "Deep right"),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let data = try BrainstormExporter.data(
            root: root,
            theme: .dracula,
            colorScheme: .dark,
            format: .html,
            options: BrainstormExportOptions(htmlInitialMode: .presentation)
        )
        let html = String(decoding: data, as: UTF8.self)

        // Sequential presentation pans straight between node centers and
        // never retraces hierarchy/connection routes through parents.
        #expect(html.contains(#"data-node-id="\#(leftID.uuidString)""#))
        #expect(html.contains(#"data-next-relation-kind="sibling""#))
        #expect(html.contains("const presentationCameraRoute = (source, target)"))
        #expect(html.contains("return [from, to];"))
        #expect(!html.contains("const smoothBranchRoute"))
        #expect(!html.contains("const parseSpatialRoute"))
        #expect(
            html.contains(
                "Always interpolate a straight chord between the current and"
            )
        )
        #expect(html.contains("const enterPresentationFreeLook"))
        #expect(html.contains("activeCameraAnimation"))
        #expect(html.contains("suppressSlideClicksDuringTravel"))
    }

    @Test func noteFlipHidesMirroredTitleOnBackFace() throws {
        let root = BrainstormNode(
            title: "Root",
            children: [
                BrainstormNode(
                    title: "Noted",
                    note: NodeNote(bodyMarkdown: "Hidden until flipped")
                ),
            ]
        )
        let data = try BrainstormExporter.data(
            root: root,
            theme: .dracula,
            colorScheme: .dark,
            format: .html
        )
        let html = String(decoding: data, as: UTF8.self)

        #expect(html.contains("transform: rotateY(0deg) translateZ(1px);"))
        #expect(html.contains("translateZ(1px)"))
        #expect(
            html.contains(
                #".presentation-slide[data-face="note"] .presentation-node-front"#
            )
        )
        #expect(html.contains(#".node[data-face="note"] .map-node-front"#))
        #expect(
            html.contains(
                "-webkit-transform-style: preserve-3d;"
            )
        )
        #expect(html.contains("-webkit-backface-visibility: hidden;"))
    }
}
